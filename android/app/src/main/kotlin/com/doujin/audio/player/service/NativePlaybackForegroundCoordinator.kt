package com.doujin.audio.player.service

internal interface NativePlaybackForegroundEnvironment {
    fun postDelayed(runnable: Runnable, delayMs: Long)
    fun remove(runnable: Runnable)
}

internal interface NativePlaybackForegroundHost {
    val hasPlaybackToKeepAlive: Boolean
    val playbackSuspended: Boolean

    fun playbackSignature(): String?
    fun onActiveSync()

    fun onIdleStop()

    /**
     * Whether the foreground notification is still posted. Used to avoid
     * rebuilding it on every watchdog tick.
     *
     * Only an explicit `false` triggers a rebuild. `null` means "not
     * answerable" when the platform query failed and must not force a re-post.
     */
    fun isForegroundNotificationPosted(): Boolean?
    fun startPlaybackForeground()
    fun startBootstrapForeground()
    fun stopForeground(wasStarted: Boolean)
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
    private val watchdogIntervalMs: Long
) {
    var isStarted: Boolean = false
        private set

    private var signature: String? = null
    private var idleStopScheduled = false
    private var watchdogScheduled = false
    private val pendingPlaybackStarts = linkedMapOf<String, Runnable>()
    val hasPendingPlaybackStarts: Boolean get() = pendingPlaybackStarts.isNotEmpty()
    fun isHoldingPlaybackStart(sessionId: String): Boolean = pendingPlaybackStarts.containsKey(sessionId)

    fun holdPlaybackStart(sessionId: String) {
        settlePlaybackStart(sessionId)
        lateinit var expiry: Runnable
        expiry = Runnable {
            if (pendingPlaybackStarts[sessionId] !== expiry) return@Runnable
            pendingPlaybackStarts.remove(sessionId)
            sync()
        }
        pendingPlaybackStarts[sessionId] = expiry
        cancelIdleStop()
        environment.postDelayed(expiry, 5_000L)
    }

    fun settlePlaybackStart(sessionId: String) {
        pendingPlaybackStarts.remove(sessionId)?.let(environment::remove)
    }

    private val idleStop = Runnable {
        idleStopScheduled = false
        if (!host.hasPlaybackToKeepAlive) host.onIdleStop()
    }

    private val watchdogRunnable = object : Runnable {
        override fun run() {
            if (!watchdogScheduled) return
            if (!host.hasPlaybackToKeepAlive || !isStarted) {
                stopWatchdog()
                return
            }
            repairNotificationIfMissing()
            environment.postDelayed(this, watchdogIntervalMs)
        }
    }

    fun repairNotificationIfMissing() {
        if (!isStarted || !host.hasPlaybackToKeepAlive) return
        if (host.isForegroundNotificationPosted() == false) {
            startOrUpdate(forceRefresh = true)
        }
    }

    fun sync() {
        if (host.hasPlaybackToKeepAlive) {
            cancelIdleStop()
            if (startOrUpdate().playbackAllowed) {
                host.onActiveSync()
                ensureWatchdog()
            } else {
                stopWatchdog()
            }
        } else if (!idleStopScheduled) {
            // Let the current player callback finish before releasing its session.
            idleStopScheduled = true
            environment.postDelayed(idleStop, 0L)
        }
    }

    fun startOrUpdate(
        forceRefresh: Boolean = false
    ): NativePlaybackForegroundStartResult {
        if (host.playbackSuspended) return NativePlaybackForegroundStartResult.SKIPPED
        val nextSignature = host.playbackSignature() ?: return NativePlaybackForegroundStartResult.SKIPPED
        if (!forceRefresh && isStarted && signature == nextSignature) {
            return NativePlaybackForegroundStartResult.ALREADY_STARTED
        }
        return try {
            host.startPlaybackForeground()
            isStarted = true
            signature = nextSignature
            host.logInfo(
                "start_foreground_success forceRefresh=$forceRefresh"
            )
            NativePlaybackForegroundStartResult.STARTED
        } catch (error: Exception) {
            host.logWarn(
                "start_foreground_failed forceRefresh=$forceRefresh",
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

    private fun cancelIdleStop() {
        if (!idleStopScheduled) return
        environment.remove(idleStop)
        idleStopScheduled = false
    }

    private fun ensureWatchdog() {
        if (watchdogScheduled) return
        watchdogScheduled = true
        environment.postDelayed(watchdogRunnable, watchdogIntervalMs)
    }

    private fun stopWatchdog() {
        if (!watchdogScheduled) return
        environment.remove(watchdogRunnable)
        watchdogScheduled = false
    }

    fun stop(reason: String) {
        cancelIdleStop()
        stopWatchdog()
        host.logInfo("stop_foreground reason=$reason wasStarted=$isStarted")
        host.stopForeground(wasStarted = isStarted)
        isStarted = false
        signature = null
    }

    fun shutdown() {
        pendingPlaybackStarts.values.forEach(environment::remove)
        pendingPlaybackStarts.clear()
        stop(reason = "on_destroy")
    }

    private companion object {
        const val BOOTSTRAP_SIGNATURE = "bootstrap"
    }
}
