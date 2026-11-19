package com.doujin.audio.player.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
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
    fun refreshWakeLock(force: Boolean = false)
    fun triggerRecovery(reason: String)
    fun expireGraceIfOverdue(): Boolean
    fun syncForeground()
    fun cancelAlarm()
    fun ensureAlarm()
    fun logHeartbeat()
    fun onScreenInteractiveChanged(interactive: Boolean) {}
    fun onDeviceIdleModeChanged(deviceIdle: Boolean) {}
}

internal interface NativePlaybackProgressHeartbeatEnvironment {
    fun post(runnable: Runnable)
    fun postDelayed(runnable: Runnable, delayMs: Long)
    fun remove(runnable: Runnable)
    fun elapsedRealtimeMs(): Long
    fun isScreenInteractive(): Boolean
    fun isDeviceIdleMode(): Boolean = false
    fun registerPowerEvents(
        onScreenOn: () -> Unit,
        onScreenOff: () -> Unit = {},
        onDeviceIdleChanged: (Boolean) -> Unit = {}
    )
    fun unregisterPowerEvents()
}

internal class AndroidNativePlaybackProgressHeartbeatEnvironment(
    private val context: Context,
    private val handler: Handler
) : NativePlaybackProgressHeartbeatEnvironment {
    private val powerManager by lazy {
        context.getSystemService(Context.POWER_SERVICE) as? PowerManager
    }
    private var screenOnListener: (() -> Unit)? = null
    private var screenOffListener: (() -> Unit)? = null
    private var deviceIdleListener: ((Boolean) -> Unit)? = null
    private var receiverRegistered = false
    private val powerReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_ON -> screenOnListener?.invoke()
                Intent.ACTION_SCREEN_OFF -> screenOffListener?.invoke()
                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED ->
                    deviceIdleListener?.invoke(isDeviceIdleMode())
            }
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

    override fun isDeviceIdleMode(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            powerManager?.isDeviceIdleMode == true
        } else {
            false
        }

    override fun registerPowerEvents(
        onScreenOn: () -> Unit,
        onScreenOff: () -> Unit,
        onDeviceIdleChanged: (Boolean) -> Unit
    ) {
        screenOnListener = onScreenOn
        screenOffListener = onScreenOff
        deviceIdleListener = onDeviceIdleChanged
        if (receiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
            }
        }
        ContextCompat.registerReceiver(
            context,
            powerReceiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        receiverRegistered = true
    }

    override fun unregisterPowerEvents() {
        screenOnListener = null
        screenOffListener = null
        deviceIdleListener = null
        if (!receiverRegistered) return
        context.unregisterReceiver(powerReceiver)
        receiverRegistered = false
    }
}

internal class NativePlaybackProgressHeartbeatCoordinator(
    private val host: NativePlaybackProgressHeartbeatHost,
    private val environment: NativePlaybackProgressHeartbeatEnvironment,
    private val screenOnIntervalMs: Long,
    private val keepAliveHost: NativePlaybackKeepAliveHeartbeatHost? = null
) {
    var isScheduled: Boolean = false
        private set
    private var started = false
    private var parkedForScreenOff = false
    private val ticker = Runnable(::tick)

    fun start() {
        if (started) return
        started = true
        environment.registerPowerEvents(
            onScreenOn = ::onScreenOn,
            onScreenOff = ::onScreenOff,
            onDeviceIdleChanged = ::onDeviceIdleChanged
        )
    }

    fun ensure() {
        if (!host.shouldRunProgressHeartbeat()) return
        if (!environment.isScreenInteractive()) {
            // Park the Flutter EventChannel ticker completely while the screen
            // is off so the background Dart isolate is not woken periodically.
            parkedForScreenOff = true
            if (isScheduled) stopTickerOnly()
            return
        }
        parkedForScreenOff = false
        if (isScheduled) return
        isScheduled = true
        environment.post(ticker)
    }

    fun stopIfUnobserved() {
        if (host.shouldRunProgressHeartbeat()) return
        stop()
    }

    fun restart() {
        if (!host.shouldRunProgressHeartbeat()) {
            stop()
            return
        }
        if (!environment.isScreenInteractive()) {
            parkedForScreenOff = true
            if (isScheduled) stopTickerOnly()
            return
        }
        parkedForScreenOff = false
        environment.remove(ticker)
        isScheduled = true
        environment.post(ticker)
    }

    fun isScreenInteractive(): Boolean = environment.isScreenInteractive()

    fun isDeviceIdleMode(): Boolean = environment.isDeviceIdleMode()

    fun onKeepAliveHeartbeat() {
        val keepAlive = keepAliveHost ?: return
        if (!keepAlive.hasPlaybackToKeepAlive && !keepAlive.foregroundStarted) {
            keepAlive.cancelAlarm()
            return
        }
        var shouldRearm = true
        try {
            keepAlive.logHeartbeat()
            if (keepAlive.hasPlaybackToKeepAlive) {
                keepAlive.refreshWakeLock(force = true)
                if (environment.isScreenInteractive()) restart()
                if (!keepAlive.focusInterrupted) {
                    keepAlive.triggerRecovery("keep_alive_heartbeat")
                }
            }
            if (keepAlive.expireGraceIfOverdue() && !keepAlive.hasPlaybackToKeepAlive) {
                shouldRearm = false
                keepAlive.cancelAlarm()
                return
            }
            keepAlive.syncForeground()
        } finally {
            if (shouldRearm &&
                (keepAlive.hasPlaybackToKeepAlive || keepAlive.foregroundStarted)
            ) {
                keepAlive.ensureAlarm()
            }
        }
    }

    fun shutdown() {
        stop()
        if (!started) return
        started = false
        environment.unregisterPowerEvents()
    }

    private fun onScreenOn() {
        if (parkedForScreenOff || isScheduled) {
            restart()
        }
        keepAliveHost?.onScreenInteractiveChanged(true)
    }

    private fun onScreenOff() {
        if (isScheduled) {
            parkedForScreenOff = true
            stopTickerOnly()
        }
        keepAliveHost?.onScreenInteractiveChanged(false)
    }

    private fun onDeviceIdleChanged(deviceIdle: Boolean) {
        keepAliveHost?.onDeviceIdleModeChanged(deviceIdle)
    }

    private fun tick() {
        if (!host.shouldRunProgressHeartbeat()) {
            stop()
            return
        }
        if (!environment.isScreenInteractive()) {
            parkedForScreenOff = true
            stopTickerOnly()
            return
        }
        val now = environment.elapsedRealtimeMs()
        host.publishProgress(now)
        environment.postDelayed(ticker, screenOnIntervalMs)
    }

    private fun stopTickerOnly() {
        environment.remove(ticker)
        isScheduled = false
    }

    fun stop() {
        parkedForScreenOff = false
        stopTickerOnly()
    }
}
