package com.doujin.audio.player.recovery

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager

/**
 * Keeps CPU (and Wi-Fi for network queues) awake across media-item transitions,
 * async queue preparation, and [NativePlaybackRecoveryController] retry backoff
 * windows where ExoPlayer temporarily enters STATE_IDLE and drops its own lock.
 */
internal class NativePlaybackWakeLockController(
    context: Context,
    private val logInfo: (String) -> Unit,
    private val logWarn: (String, Throwable) -> Unit
) {
    private val appContext = context.applicationContext ?: context
    private val cpuWakeLock: PowerManager.WakeLock? by lazy {
        (appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager)
            ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, CPU_WAKE_LOCK_TAG)
            ?.apply { setReferenceCounted(false) }
    }
    private val wifiLock: WifiManager.WifiLock? by lazy {
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
            @Suppress("DEPRECATION")
            WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        (appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager)
            ?.createWifiLock(mode, WIFI_WAKE_LOCK_TAG)
            ?.apply { setReferenceCounted(false) }
    }

    var isCpuWakeHeld: Boolean = false
        private set
    var isWifiWakeHeld: Boolean = false
        private set

    fun sync(keepCpuAwake: Boolean, keepWifiAwake: Boolean) {
        val targetWifi = keepCpuAwake && keepWifiAwake
        if (keepCpuAwake && !isCpuWakeHeld) {
            if (acquireCpu()) {
                isCpuWakeHeld = true
                logInfo("playback_wakelock_acquired")
            }
        } else if (!keepCpuAwake && isCpuWakeHeld) {
            isCpuWakeHeld = false
            releaseCpu()
            logInfo("playback_wakelock_released")
        }

        if (targetWifi && !isWifiWakeHeld) {
            if (acquireWifi()) {
                isWifiWakeHeld = true
                logInfo("playback_wifi_lock_acquired")
            }
        } else if (!targetWifi && isWifiWakeHeld) {
            isWifiWakeHeld = false
            releaseWifi()
            logInfo("playback_wifi_lock_released")
        }
    }

    fun releaseAll(reason: String) {
        val hadLocks = isCpuWakeHeld || isWifiWakeHeld
        isWifiWakeHeld = false
        isCpuWakeHeld = false
        releaseWifi()
        releaseCpu()
        if (hadLocks) {
            logInfo("playback_wakelocks_cleared reason=$reason")
        }
    }

    private fun acquireCpu(): Boolean {
        val lock = cpuWakeLock ?: return false
        return try {
            if (!lock.isHeld) {
                @Suppress("WakelockTimeout")
                lock.acquire()
            }
            lock.isHeld
        } catch (error: RuntimeException) {
            logWarn("playback_cpu_wakelock_acquire_failed", error)
            false
        }
    }

    private fun releaseCpu() {
        val lock = cpuWakeLock ?: return
        try {
            if (lock.isHeld) lock.release()
        } catch (error: RuntimeException) {
            logWarn("playback_cpu_wakelock_release_failed", error)
        }
    }

    private fun acquireWifi(): Boolean {
        val lock = wifiLock ?: return false
        return try {
            if (!lock.isHeld) lock.acquire()
            lock.isHeld
        } catch (error: RuntimeException) {
            logWarn("playback_wifi_lock_acquire_failed", error)
            false
        }
    }

    private fun releaseWifi() {
        val lock = wifiLock ?: return
        try {
            if (lock.isHeld) lock.release()
        } catch (error: RuntimeException) {
            logWarn("playback_wifi_lock_release_failed", error)
        }
    }

    private companion object {
        const val CPU_WAKE_LOCK_TAG = "DoujinAudio:PlaybackKeepAlive"
        const val WIFI_WAKE_LOCK_TAG = "DoujinAudio:PlaybackNetworkKeepAlive"
    }
}
