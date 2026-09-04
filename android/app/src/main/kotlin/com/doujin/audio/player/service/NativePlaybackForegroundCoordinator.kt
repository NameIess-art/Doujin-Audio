package com.doujin.audio.player.service

internal interface NativePlaybackForegroundEnvironment {
    fun postDelayed(runnable: Runnable, delayMs: Long)
    fun remove(runnable: Runnable)

    /**
     * Sleep-inclusive clock. [postDelayed] runs on `uptimeMillis`, which stalls
     * in deep sleep, so the grace window needs an independent way to tell that
     * its own timer is overdue.
     */
    fun elapsedRealtimeMs(): Long
}

internal interface NativePlaybackForegroundHost {
    val hasPlaybackToKeepAlive: Boolean
    val hasSessions: Boolean
    val playbackSuspended: Boolean
    val foregroundSuppressed: Boolean

    fun playbackSignature(): String?
    fun onActiveSync()

    /**
     * Playback stopped and the stop-grace window has just begun. The foreground
     * service must stay up (transient buffering/focus gaps), but nothing is
     * driving the audio pipeline, so CPU-holding resources should be dropped
     * now rather than at the end of the grace window.
     */
    fun onIdleGraceBegan()
    fun onGraceExpired()

    /**
     * Whether the foreground notification is still posted. Used to avoid
     * rebuilding it on every watchdog tick.
     *
     * Only an explicit `false` triggers a rebuild. `null` means "not
     * answerable" - notifications were dismissed by the user, or the platform
     * query failed - and must NOT force a re-post, otherwise the watchdog
     * fights the user's dismiss every interval.
     */
    fun isForegroundNotificationPosted(): Boolean?
    fun onWatchdog()
    fun startPlaybackForeground()
    fun startBootstrapForeground()
    fun shouldRemoveForegroundNotification(removeNotification: Boolean): Boolean
    fun stopForeground(wasStarted: Boolean, removeNotification: Boolean)
    fun logInfo(message: String)
    fun logWarn(message: String, error: Throwable)
}

internal enum class NativePlaybackForegroundStartResult {
    STARTED,
    ALREADY_STARTED,
    SKIPPED,
    FAILED;

    val playbackAllowed: Boolean get() = this == STARTED || this == ALREADY_STARTED
}

internal class NativePlaybackForegroundCoordinator(
    private val host: NativePlaybackForegroundHost,
    private val environment: NativePlaybackForegroundEnvironment,
    private val stopGraceMs: Long,
    private val watchdogIntervalMs: Long
) {
    var isStarted: Boolean = false
        private set

    private var signature: String? = null
    private var graceScheduled = false
    private var graceStartedElapsedRealtimeMs = 0L
    private var watchdogScheduled = false

    private val graceRunnable = Runnable {
        graceScheduled = false
        if (!host.hasPlaybackToKeepAlive) {
            host.logInfo("foreground_stop_grace_expired executing_deferred_stop")
            host.onGraceExpired()
            stopWatchdog()
            stop(
                reason = "grace_expired_no_active_playback",
                removeNotification = !host.hasSessions
            )
        } else {
            host.logInfo("foreground_stop_grace_expired playback_resumed_skip")
        }
    }

    private val watchdogRunnable = object : Runnable {
        override fun run() {
            if (!watchdogScheduled) return
            if (host.hasPlaybackToKeepAlive) {
                // Only rebuild when the notification actually went missing.
                // A blind forceRefresh re-posts ~180 times over a 12h session.
                val foregroundStart = startOrUpdate(
                    forceRefresh = host.isForegroundNotificationPosted() == false
                )
                if (foregroundStart.playbackAllowed) {
                    host.onWatchdog()
                    environment.postDelayed(this, watchdogIntervalMs)
                } else {
                    stopWatchdog()
                }
            } else {
                stopWatchdog()
            }
        }
    }

    fun triggerWatchdog() {
        if (!host.hasPlaybackToKeepAlive) return
        val foregroundStart = startOrUpdate(
            forceRefresh = host.isForegroundNotificationPosted() == false
        )
        if (foregroundStart.playbackAllowed) {
            host.onWatchdog()
            if (watchdogScheduled) {
                environment.remove(watchdogRunnable)
                environment.postDelayed(watchdogRunnable, watchdogIntervalMs)
            }
        }
    }

    fun sync(forceRefresh: Boolean = false) {
        if (host.hasPlaybackToKeepAlive) {
            cancelGrace()
            if (startOrUpdate(forceRefresh = forceRefresh).playbackAllowed) {
                host.onActiveSync()
                ensureWatchdog()
            } else {
                stopWatchdog()
            }
        } else {
            scheduleGrace()
        }
    }

    fun startOrUpdate(
        forceRefresh: Boolean = false
    ): NativePlaybackForegroundStartResult {
        if (host.playbackSuspended) {
            host.logInfo("start_foreground_skip playback_suspended forceRefresh=$forceRefresh")
            return NativePlaybackForegroundStartResult.SKIPPED
        }
        if (host.foregroundSuppressed) {
            host.logInfo("start_foreground_minimal foreground_suppressed forceRefresh=$forceRefresh")
        }
        val nextSignature = host.playbackSignature() ?: run {
            host.logInfo("start_foreground_skip no_session")
            return NativePlaybackForegroundStartResult.SKIPPED
        }
        if (!forceRefresh && isStarted && signature == nextSignature) {
            host.logInfo("start_foreground_skip unchanged signature=$nextSignature")
            return NativePlaybackForegroundStartResult.ALREADY_STARTED
        }
        return try {
            host.startPlaybackForeground()
            isStarted = true
            signature = nextSignature
            host.logInfo(
                "start_foreground_success forceRefresh=$forceRefresh signature=$nextSignature"
            )
            NativePlaybackForegroundStartResult.STARTED
        } catch (error: Exception) {
            host.logWarn(
                "start_foreground_failed forceRefresh=$forceRefresh signature=$nextSignature",
                error
            )
            if (isStarted) {
                NativePlaybackForegroundStartResult.ALREADY_STARTED
            } else {
                NativePlaybackForegroundStartResult.FAILED
            }
        }
    }

    fun startBootstrap(): NativePlaybackForegroundStartResult {
        if (isStarted) {
            host.logInfo("start_bootstrap_foreground_skip already_started")
            return NativePlaybackForegroundStartResult.ALREADY_STARTED
        }
        return try {
            host.startBootstrapForeground()
            isStarted = true
            signature = BOOTSTRAP_SIGNATURE
            host.logInfo("start_bootstrap_foreground_success")
            NativePlaybackForegroundStartResult.STARTED
        } catch (error: Exception) {
            host.logWarn("start_bootstrap_foreground_failed", error)
            NativePlaybackForegroundStartResult.FAILED
        }
    }

    fun scheduleGrace() {
        if (graceScheduled) return
        graceScheduled = true
        graceStartedElapsedRealtimeMs = environment.elapsedRealtimeMs()
        host.logInfo("foreground_stop_grace_scheduled delay=${stopGraceMs}ms")
        host.onIdleGraceBegan()
        environment.postDelayed(graceRunnable, stopGraceMs)
    }

    /**
     * Closes a grace window whose [postDelayed] timer never fired because the
     * device slept through it. Called from the alarm-backed heartbeat.
     *
     * Returns true when the window was force-closed.
     */
    fun expireGraceIfOverdue(): Boolean {
        if (!graceScheduled) return false
        val elapsedMs = environment.elapsedRealtimeMs() - graceStartedElapsedRealtimeMs
        if (elapsedMs < stopGraceMs) return false
        host.logInfo("foreground_stop_grace_overdue elapsed=${elapsedMs}ms forcing_stop")
        environment.remove(graceRunnable)
        graceRunnable.run()
        return true
    }

    fun cancelGrace() {
        if (!graceScheduled) return
        environment.remove(graceRunnable)
        graceScheduled = false
        host.logInfo("foreground_stop_grace_cancelled")
    }

    fun ensureWatchdog() {
        if (watchdogScheduled) return
        watchdogScheduled = true
        environment.postDelayed(watchdogRunnable, watchdogIntervalMs)
    }

    fun stopWatchdog() {
        if (!watchdogScheduled) return
        environment.remove(watchdogRunnable)
        watchdogScheduled = false
    }

    fun stop(reason: String, removeNotification: Boolean = true) {
        val shouldRemoveNotification =
            host.shouldRemoveForegroundNotification(removeNotification)
        host.logInfo(
            "stop_foreground reason=$reason removeNotification=$removeNotification " +
                "shouldRemoveNotification=$shouldRemoveNotification wasStarted=$isStarted"
        )
        if (isStarted || shouldRemoveNotification) {
            host.stopForeground(
                wasStarted = isStarted,
                removeNotification = shouldRemoveNotification
            )
        }
        isStarted = false
        signature = null
    }

    fun onTaskRemoved(): Boolean {
        return when {
            host.hasPlaybackToKeepAlive -> {
                sync()
                false
            }
            host.hasSessions -> {
                scheduleGrace()
                false
            }
            else -> {
                stopWatchdog()
                cancelGrace()
                stop(reason = "task_removed_no_sessions", removeNotification = true)
                true
            }
        }
    }

    fun shutdown() {
        cancelGrace()
        stopWatchdog()
        stop(reason = "on_destroy", removeNotification = true)
    }

    private companion object {
        const val BOOTSTRAP_SIGNATURE = "bootstrap"
    }
}
