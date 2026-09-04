package com.doujin.audio.player.common

import android.annotation.SuppressLint
import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager

/**
 * Holds the CPU wake lock that keeps handler-driven playback timers,
 * audio decoding, and recovery work running while the screen is off.
 *
 * Additionally holds a low-latency / high-perf Wi-Fi lock when network
 * streaming is active, preventing OEM power managers and Doze mode from
 * putting the Wi-Fi chip to sleep during overnight playback.
 */
internal class NativePlaybackWakeLock(
    private val context: Context,
    private val logInfo: (String) -> Unit,
    private val logWarn: (String, Exception) -> Unit,
    private val wakeLockTimeoutMs: Long = DEFAULT_WAKELOCK_TIMEOUT_MS
) {
    companion object {
        const val DEFAULT_WAKELOCK_TIMEOUT_MS = 20 * 60 * 1000L
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var isNetworkActive = false

    fun isHeld(): Boolean = wakeLock?.isHeld == true

    fun isWifiLockHeld(): Boolean = wifiLock?.isHeld == true

    @SuppressLint("WakelockTimeout")
    fun acquire() {
        if (wakeLock == null) {
            try {
                val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
                wakeLock = powerManager?.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "${context.packageName}:native_playback"
                )?.apply {
                    setReferenceCounted(false)
                }
            } catch (e: Exception) {
                logWarn("wakelock_create_failed", e)
            }
        }

        val lock = wakeLock ?: return
        if (lock.isHeld) return
        try {
            lock.acquire(wakeLockTimeoutMs)
        } catch (e: Exception) {
            logWarn("wakelock_acquire_failed", e)
            return
        }

        if (lock.isHeld) logInfo("wakelock_acquired")
        syncWifiLock()
    }

    /**
     * Actively re-acquires the lock with a fresh rolling timeout to prevent
     * OEM power managers or Doze mode from revoking or silencing the wake lock
     * during long overnight playback sessions.
     */
    @SuppressLint("WakelockTimeout")
    fun refresh() {
        if (wakeLock == null) {
            acquire()
            return
        }
        val lock = wakeLock ?: return
        try {
            // Re-acquiring with timeout updates the expiration in PowerManagerService
            // even if the lock object already considers itself held.
            lock.acquire(wakeLockTimeoutMs)
            logInfo("wakelock_refreshed")
        } catch (e: Exception) {
            logWarn("wakelock_refresh_failed", e)
        }
        syncWifiLock()
    }

    fun setNetworkPlaybackActive(active: Boolean) {
        if (isNetworkActive == active) return
        isNetworkActive = active
        syncWifiLock()
    }

    private fun syncWifiLock() {
        val shouldHoldWifi = isHeld() && isNetworkActive
        if (shouldHoldWifi) {
            if (wifiLock?.isHeld == true) return
            try {
                if (wifiLock == null) {
                    val wifiManager = context.applicationContext
                        .getSystemService(Context.WIFI_SERVICE) as? WifiManager
                    val lockType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                    } else {
                        @Suppress("DEPRECATION")
                        WifiManager.WIFI_MODE_FULL_HIGH_PERF
                    }
                    wifiLock = wifiManager?.createWifiLock(
                        lockType,
                        "${context.packageName}:native_playback_wifi"
                    )?.apply {
                        setReferenceCounted(false)
                    }
                }
                wifiLock?.acquire()
                if (wifiLock?.isHeld == true) logInfo("wifilock_acquired")
            } catch (e: Exception) {
                logWarn("wifilock_acquire_failed", e)
            }
        } else {
            val currentWifiLock = wifiLock ?: return
            wifiLock = null
            try {
                if (currentWifiLock.isHeld) {
                    currentWifiLock.release()
                    logInfo("wifilock_released")
                }
            } catch (e: Exception) {
                logWarn("wifilock_release_failed", e)
            }
        }
    }

    fun release() {
        val currentWakeLock = wakeLock
        wakeLock = null
        isNetworkActive = false
        syncWifiLock()

        try {
            if (currentWakeLock?.isHeld == true) {
                currentWakeLock.release()
                logInfo("wakelock_released")
            }
        } catch (e: RuntimeException) {
            logWarn("wakelock_release_failed", e)
        }
    }
}
