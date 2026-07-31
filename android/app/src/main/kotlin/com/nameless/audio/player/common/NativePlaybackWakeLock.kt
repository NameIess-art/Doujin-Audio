package com.nameless.audio.player.common

import android.annotation.SuppressLint
import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager

/**
 * Holds the CPU wake lock and Wi-Fi lock that keep handler-driven playback
 * timers and network audio buffering running while the screen is off.
 */
internal class NativePlaybackWakeLock(
    private val context: Context,
    private val logInfo: (String) -> Unit,
    private val logWarn: (String, Exception) -> Unit
) {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    fun isHeld(): Boolean = wakeLock?.isHeld == true

    @SuppressLint("WakelockTimeout")
    fun acquire() {
        // syncForegroundState() runs on nearly every player event, so a
        // short-circuit keeps this off the binder/log hot path.
        if (isHeld()) return

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
        try {
            lock.acquire()
        } catch (e: Exception) {
            logWarn("wakelock_acquire_failed", e)
            return
        }

        if (wifiLock == null) {
            try {
                val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                @Suppress("DEPRECATION")
                wifiLock = wifiManager?.createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    "${context.packageName}:native_playback_wifi"
                )?.apply {
                    setReferenceCounted(false)
                }
            } catch (e: Exception) {
                logWarn("wifilock_create_failed", e)
            }
        }

        try {
            wifiLock?.let { wLock ->
                if (!wLock.isHeld) wLock.acquire()
            }
        } catch (e: Exception) {
            logWarn("wifilock_acquire_failed", e)
        }

        if (lock.isHeld) logInfo("wakelock_acquired")
    }

    /**
     * Re-acquires the lock if an OEM power manager revoked it underneath us.
     * A no-op while the lock is still held.
     */
    fun refresh() {
        if (isHeld()) return
        logInfo("wakelock_refresh_reacquire")
        acquire()
    }

    fun release() {
        val currentWakeLock = wakeLock
        val currentWifiLock = wifiLock
        wakeLock = null
        wifiLock = null

        try {
            if (currentWifiLock?.isHeld == true) {
                currentWifiLock.release()
            }
        } catch (e: Exception) {
            logWarn("wifilock_release_failed", e)
        }

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
