package com.nameless.audio

import android.annotation.SuppressLint
import android.content.Context
import android.net.wifi.WifiManager
import android.os.PowerManager

internal class NativePlaybackWakeLock(
    private val context: Context,
    private val logInfo: (String) -> Unit,
    private val logWarn: (String, Exception) -> Unit
) {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    fun isHeld(): Boolean = wakeLock?.isHeld == true || wifiLock?.isHeld == true

    @SuppressLint("WakelockTimeout")
    fun acquire() {
        var acquiredAny = false

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

        wakeLock?.let { lock ->
            try {
                if (!lock.isHeld) {
                    lock.acquire()
                    acquiredAny = lock.isHeld
                }
            } catch (e: Exception) {
                logWarn("wakelock_acquire_failed", e)
            }
        }

        if (wifiLock == null) {
            try {
                val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
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

        wifiLock?.let { lock ->
            try {
                if (!lock.isHeld) {
                    lock.acquire()
                    acquiredAny = acquiredAny || lock.isHeld
                }
            } catch (e: Exception) {
                logWarn("wifilock_acquire_failed", e)
            }
        }

        if (acquiredAny) {
            logInfo("wakelock_acquired held=${wakeLock?.isHeld == true} wifiHeld=${wifiLock?.isHeld == true}")
        } else if (wakeLock?.isHeld == true || wifiLock?.isHeld == true) {
            logInfo("wakelock_acquire_skip already_held")
        }
    }

    fun refresh() {
        if (wakeLock?.isHeld == true && wifiLock?.isHeld == true) {
            logInfo("wakelock_refresh_skip already_held")
            return
        }
        acquire()
    }

    fun release() {
        val currentWakeLock = wakeLock
        val currentWifiLock = wifiLock
        
        if (currentWakeLock == null && currentWifiLock == null) {
            logInfo("wakelock_release_skip none")
            return
        }
        
        try {
            var releasedAny = false
            if (currentWakeLock?.isHeld == true) {
                currentWakeLock.release()
                releasedAny = true
            }
            if (currentWifiLock?.isHeld == true) {
                currentWifiLock.release()
                releasedAny = true
            }
            if (releasedAny) {
                logInfo("wakelock_released")
            } else {
                logInfo("wakelock_release_skip not_held")
            }
        } catch (e: RuntimeException) {
            logWarn("wakelock_release_failed", e)
        } finally {
            wakeLock = null
            wifiLock = null
        }
    }
}
