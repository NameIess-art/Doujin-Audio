package com.doujin.audio.player.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.content.ContextCompat

internal interface NativePlaybackProgressHeartbeatHost {
    fun shouldRunProgressHeartbeat(): Boolean
    fun publishProgress(nowElapsedRealtimeMs: Long)
}

internal interface NativePlaybackKeepAliveHeartbeatHost {
    val hasPlaybackToKeepAlive: Boolean
    val foregroundStarted: Boolean
    val focusInterrupted: Boolean
    fun refreshWakeLock()
    fun triggerRecovery(reason: String)
    fun expireGraceIfOverdue(): Boolean
    fun syncForeground()
    fun cancelAlarm()
    fun ensureAlarm()
    fun logHeartbeat()
}

internal interface NativePlaybackProgressHeartbeatEnvironment {
    fun post(runnable: Runnable)
    fun postDelayed(runnable: Runnable, delayMs: Long)
    fun remove(runnable: Runnable)
    fun elapsedRealtimeMs(): Long
    fun isScreenInteractive(): Boolean
    fun registerScreenOn(listener: () -> Unit)
    fun unregisterScreenOn()
}

internal class AndroidNativePlaybackProgressHeartbeatEnvironment(
    private val context: Context,
    private val handler: Handler
) : NativePlaybackProgressHeartbeatEnvironment {
    private val powerManager by lazy {
        context.getSystemService(Context.POWER_SERVICE) as? PowerManager
    }
    private var screenOnListener: (() -> Unit)? = null
    private var receiverRegistered = false
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_ON) screenOnListener?.invoke()
        }
    }

    override fun post(runnable: Runnable) {
        handler.post(runnable)
    }

    override fun postDelayed(runnable: Runnable, delayMs: Long) {
        handler.postDelayed(runnable, delayMs)
    }

    override fun remove(runnable: Runnable) {
        handler.removeCallbacks(runnable)
    }

    override fun elapsedRealtimeMs(): Long = SystemClock.elapsedRealtime()

    override fun isScreenInteractive(): Boolean = powerManager?.isInteractive ?: true

    override fun registerScreenOn(listener: () -> Unit) {
        screenOnListener = listener
        if (receiverRegistered) return
        ContextCompat.registerReceiver(
            context,
            screenReceiver,
            IntentFilter(Intent.ACTION_SCREEN_ON),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        receiverRegistered = true
    }

    override fun unregisterScreenOn() {
        screenOnListener = null
        if (!receiverRegistered) return
        context.unregisterReceiver(screenReceiver)
        receiverRegistered = false
    }
}

internal class NativePlaybackProgressHeartbeatCoordinator(
    private val host: NativePlaybackProgressHeartbeatHost,
    private val environment: NativePlaybackProgressHeartbeatEnvironment,
    private val screenOnIntervalMs: Long,
    private val screenOffIntervalMs: Long,
    private val keepAliveHost: NativePlaybackKeepAliveHeartbeatHost? = null
) {
    var isScheduled: Boolean = false
        private set
    private var started = false
    private var lastPublishedElapsedRealtimeMs = 0L
    private val ticker = Runnable(::tick)

    fun start() {
        if (started) return
        started = true
        environment.registerScreenOn(::restart)
    }

    fun ensure() {
        if (isScheduled || !host.shouldRunProgressHeartbeat()) return
        isScheduled = true
        environment.post(ticker)
    }

    fun stopIfUnobserved() {
        if (host.shouldRunProgressHeartbeat()) return
        stop()
    }

    fun restart() {
        if (!isScheduled) return
        environment.remove(ticker)
        environment.post(ticker)
    }

    fun isScreenInteractive(): Boolean = environment.isScreenInteractive()

    fun onKeepAliveHeartbeat() {
        val keepAlive = keepAliveHost ?: return
        if (!keepAlive.hasPlaybackToKeepAlive && !keepAlive.foregroundStarted) {
            keepAlive.cancelAlarm()
            return
        }
        keepAlive.logHeartbeat()
        if (keepAlive.hasPlaybackToKeepAlive) {
            keepAlive.refreshWakeLock()
            restart()
            if (!keepAlive.focusInterrupted) {
                keepAlive.triggerRecovery("keep_alive_heartbeat")
            }
        }
        if (keepAlive.expireGraceIfOverdue() && !keepAlive.hasPlaybackToKeepAlive) {
            keepAlive.cancelAlarm()
            return
        }
        keepAlive.syncForeground()
        keepAlive.ensureAlarm()
    }

    fun shutdown() {
        stop()
        if (!started) return
        started = false
        environment.unregisterScreenOn()
    }

    private fun tick() {
        if (!host.shouldRunProgressHeartbeat()) {
            isScheduled = false
            return
        }
        val now = environment.elapsedRealtimeMs()
        val screenOn = environment.isScreenInteractive()
        if (shouldPublishProgressHeartbeat(
                isScreenOn = screenOn,
                nowElapsedRealtimeMs = now,
                lastPublishedElapsedRealtimeMs = lastPublishedElapsedRealtimeMs,
                screenOffIntervalMs = screenOffIntervalMs
            )
        ) {
            host.publishProgress(now)
            lastPublishedElapsedRealtimeMs = now
        }
        environment.postDelayed(
            ticker,
            progressHeartbeatDelayMs(screenOn, screenOnIntervalMs, screenOffIntervalMs)
        )
    }

    fun stop() {
        environment.remove(ticker)
        isScheduled = false
    }
}
