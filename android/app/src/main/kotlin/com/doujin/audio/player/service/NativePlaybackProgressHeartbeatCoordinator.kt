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
    @Volatile
    private var cachedInteractive: Boolean? = null
    private var screenOnListener: (() -> Unit)? = null
    private var screenOffListener: (() -> Unit)? = null
    private var deviceIdleListener: ((Boolean) -> Unit)? = null
    private var receiverRegistered = false
    private val powerReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_ON -> {
                    cachedInteractive = true
                    screenOnListener?.invoke()
                }
                Intent.ACTION_SCREEN_OFF -> {
                    cachedInteractive = false
                    screenOffListener?.invoke()
                }
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

    override fun isScreenInteractive(): Boolean {
        if (receiverRegistered) {
            cachedInteractive?.let { return it }
        }
        val interactive = powerManager?.isInteractive ?: true
        if (receiverRegistered) {
            cachedInteractive = interactive
        }
        return interactive
    }

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
        cachedInteractive = powerManager?.isInteractive ?: true
    }

    override fun unregisterPowerEvents() {
        screenOnListener = null
        screenOffListener = null
        deviceIdleListener = null
        cachedInteractive = null
        if (!receiverRegistered) return
        context.unregisterReceiver(powerReceiver)
        receiverRegistered = false
    }
}

internal class NativePlaybackProgressHeartbeatCoordinator(
    private val host: NativePlaybackProgressHeartbeatHost,
    private val environment: NativePlaybackProgressHeartbeatEnvironment,
    private val screenOnIntervalMs: Long
) {
    var isScheduled: Boolean = false
        private set
    private var started = false
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
        if (isScheduled || !host.shouldRunProgressHeartbeat() || !environment.isScreenInteractive()) return
        isScheduled = true
        environment.post(ticker)
    }

    fun stopIfUnobserved() {
        if (host.shouldRunProgressHeartbeat()) return
        stop()
    }

    fun isScreenInteractive(): Boolean = environment.isScreenInteractive()

    fun shutdown() {
        stop()
        if (!started) return
        started = false
        environment.unregisterPowerEvents()
    }

    private fun onScreenOn() {
        ensure()
        host.onScreenInteractiveChanged(true)
    }

    private fun onScreenOff() {
        stop()
        host.onScreenInteractiveChanged(false)
    }

    private fun onDeviceIdleChanged(deviceIdle: Boolean) {
        host.onDeviceIdleModeChanged(deviceIdle)
    }

    private fun tick() {
        if (!host.shouldRunProgressHeartbeat() || !environment.isScreenInteractive()) {
            stop()
            return
        }
        val now = environment.elapsedRealtimeMs()
        host.publishProgress(now)
        environment.postDelayed(ticker, screenOnIntervalMs)
    }

    fun stop() {
        if (!isScheduled) return
        environment.remove(ticker)
        isScheduled = false
    }
}
