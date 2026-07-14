package com.nameless.audio.player.service

internal interface NativePlaybackForegroundEnvironment {
    fun postDelayed(runnable: Runnable, delayMs: Long)
    fun remove(runnable: Runnable)
}

internal interface NativePlaybackForegroundHost {
    val hasPlaybackToKeepAlive: Boolean
    val hasSessions: Boolean
    val playbackSuspended: Boolean
    val foregroundSuppressed: Boolean

    fun playbackSignature(): String?
    fun onActiveSync()
    fun onSuppressedIdle()
    fun onGraceExpired()
    fun onWatchdog()
    fun startPlaybackForeground()
    fun startBootstrapForeground()
    fun shouldRemoveForegroundNotification(removeNotification: Boolean): Boolean
    fun stopForeground(wasStarted: Boolean, removeNotification: Boolean)
    fun logInfo(message: String)
    fun logWarn(message: String, error: Throwable)
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
                host.onWatchdog()
                startOrUpdate(forceRefresh = true)
            }
            environment.postDelayed(this, watchdogIntervalMs)
        }
    }

    fun sync(forceRefresh: Boolean = false) {
        if (host.hasPlaybackToKeepAlive) {
            cancelGrace()
            host.onActiveSync()
            startOrUpdate(forceRefresh = forceRefresh)
            ensureWatchdog()
        } else if (host.foregroundSuppressed) {
            cancelGrace()
            host.onSuppressedIdle()
        } else {
            scheduleGrace()
        }
    }

    fun startOrUpdate(forceRefresh: Boolean = false) {
        if (host.playbackSuspended) {
            host.logInfo("start_foreground_skip playback_suspended forceRefresh=$forceRefresh")
            return
        }
        if (host.foregroundSuppressed) {
            host.logInfo("start_foreground_minimal foreground_suppressed forceRefresh=$forceRefresh")
        }
        val nextSignature = host.playbackSignature() ?: run {
            host.logInfo("start_foreground_skip no_session")
            return
        }
        if (!forceRefresh && isStarted && signature == nextSignature) {
            host.logInfo("start_foreground_skip unchanged signature=$nextSignature")
            return
        }
        try {
            host.startPlaybackForeground()
            isStarted = true
            signature = nextSignature
            host.logInfo(
                "start_foreground_success forceRefresh=$forceRefresh signature=$nextSignature"
            )
        } catch (error: Exception) {
            host.logWarn(
                "start_foreground_failed forceRefresh=$forceRefresh signature=$nextSignature",
                error
            )
        }
    }

    fun startBootstrap() {
        if (isStarted) {
            host.logInfo("start_bootstrap_foreground_skip already_started")
            return
        }
        try {
            host.startBootstrapForeground()
            isStarted = true
            signature = BOOTSTRAP_SIGNATURE
            host.logInfo("start_bootstrap_foreground_success")
        } catch (error: Exception) {
            host.logWarn("start_bootstrap_foreground_failed", error)
        }
    }

    fun scheduleGrace() {
        if (graceScheduled) return
        graceScheduled = true
        host.logInfo("foreground_stop_grace_scheduled delay=${stopGraceMs}ms")
        environment.postDelayed(graceRunnable, stopGraceMs)
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
