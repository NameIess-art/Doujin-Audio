package com.doujin.audio.player.common

import android.annotation.SuppressLint
import android.content.Context
import android.net.wifi.WifiManager
import android.os.PowerManager

/**
 * Holds the CPU wake lock that keeps handler-driven playback timers,
 * audio decoding, and recovery work running while the screen is off.
 *
 * Holds a high-performance Wi-Fi lock during network playback and recovery.
 * Before Android 14 this remains effective with the screen off. Android 14+
 * maps it to a foreground, screen-on-only lock, so buffering and recovery are
 * still required; a Wi-Fi lock cannot bypass Doze or OEM power restrictions.
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
     * Renews the timeout while the service owns playback. System power policy
     * may still suppress the lock; reacquiring does not grant a Doze exemption.
     */
    @SuppressLint("WakelockTimeout")
    fun refresh() {
        if (wakeLock == null) {
            acquire()
            return
        }
        val lock = wakeLock ?: return
        try {
            // Non-reference-counted acquire replaces the pending timeout even
            // when the lock is already held, without briefly releasing the CPU.
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
                    // LOW_LATENCY is inactive in the background or with the
                    // screen off. HIGH_PERF covers those states before API 34.
                    @Suppress("DEPRECATION")
                    wifiLock = wifiManager?.createWifiLock(
                        WifiManager.WIFI_MODE_FULL_HIGH_PERF,
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
