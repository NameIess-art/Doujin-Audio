package com.nameless.audio

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.PowerManager
import androidx.core.content.ContextCompat

private object PlaybackWakeLockController {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    @Synchronized
    fun sync(context: Context, enabled: Boolean) {
        if (enabled) {
            acquire(context.applicationContext)
        } else {
            release()
        }
    }

    private fun acquire(context: Context) {
        if (wakeLock == null) {
            try {
                val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
                wakeLock = powerManager?.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "${context.packageName}:playback_keep_alive"
                )?.apply {
                    setReferenceCounted(false)
                }
            } catch (_: Exception) {}
        }
        try {
            wakeLock?.acquire()
        } catch (_: Exception) {}

        if (wifiLock == null) {
            try {
                val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                wifiLock = wifiManager?.createWifiLock(
                    WifiManager.WIFI_MODE_FULL,
                    "${context.packageName}:playback_keep_alive_wifi"
                )?.apply {
                    setReferenceCounted(false)
                }
            } catch (_: Exception) {}
        }
        if (wifiLock?.isHeld == false) {
            try {
                wifiLock?.acquire()
            } catch (_: Exception) {}
        }
    }

    private fun release() {
        val currentWakeLock = wakeLock
        val currentWifiLock = wifiLock
        if (currentWakeLock == null && currentWifiLock == null) return

        try {
            if (currentWakeLock?.isHeld == true) {
                currentWakeLock.release()
            }
            if (currentWifiLock?.isHeld == true) {
                currentWifiLock.release()
            }
        } catch (_: RuntimeException) {
            // Ignore stale wakelock state.
        } finally {
            wakeLock = null
            wifiLock = null
        }
    }
}

internal object PlaybackKeepAlivePolicy {
    fun shouldRunKeepAliveService(
        keepForegroundServiceAlive: Boolean,
        hasActiveTimer: Boolean,
        hasActivePlayback: Boolean
    ): Boolean {
        return keepForegroundServiceAlive && (hasActiveTimer || hasActivePlayback)
    }

    fun shouldHoldKeepAliveWakeLock(
        enabled: Boolean,
        hasActiveTimer: Boolean,
        hasActivePlayback: Boolean
    ): Boolean {
        return enabled && (hasActiveTimer || hasActivePlayback)
    }
}

internal class PlaybackKeepAliveCoordinator(context: Context) {
    private val appContext = context.applicationContext

    fun sync(
        enabled: Boolean,
        hasActivePlayback: Boolean,
        hasActiveTimer: Boolean,
        usesUnifiedPlaybackNotifications: Boolean,
        keepForegroundServiceAlive: Boolean
    ) {
        try {
            val shouldRunKeepAliveService =
                !NativePlaybackService.foregroundSuppressed &&
                    PlaybackKeepAlivePolicy.shouldRunKeepAliveService(
                        keepForegroundServiceAlive = keepForegroundServiceAlive,
                        hasActiveTimer = hasActiveTimer,
                        hasActivePlayback = hasActivePlayback
                    )
            if (shouldRunKeepAliveService) {
                startService(
                    hasActivePlayback = hasActivePlayback,
                    hasActiveTimer = hasActiveTimer,
                    usesUnifiedPlaybackNotifications = usesUnifiedPlaybackNotifications
                )
            } else {
                stopService()
            }
        } catch (_: Exception) {
            // Ignore foreground service sync failures and fall back to a wakelock.
        }
        try {
            PlaybackWakeLockController.sync(
                appContext,
                PlaybackKeepAlivePolicy.shouldHoldKeepAliveWakeLock(
                    enabled = enabled,
                    hasActiveTimer = hasActiveTimer,
                    hasActivePlayback = hasActivePlayback
                )
            )
        } catch (_: Exception) {
            // Ignore keep-alive sync failures and let playback continue best-effort.
        }
    }

    fun stopService() {
        val stopIntent = Intent(appContext, PlaybackKeepAliveService::class.java).apply {
            action = PlaybackKeepAliveService.ACTION_STOP
        }
        try {
            appContext.startService(stopIntent)
        } catch (_: Exception) {
            // If the service is not startable from the current state, remove it best-effort.
        }
        appContext.stopService(Intent(appContext, PlaybackKeepAliveService::class.java))
        val manager = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        manager?.cancel(UnifiedPlaybackNotificationController.foregroundServiceNotificationId + 1)
    }

    private fun startService(
        hasActivePlayback: Boolean,
        hasActiveTimer: Boolean,
        usesUnifiedPlaybackNotifications: Boolean
    ) {
        val serviceIntent =
            Intent(appContext, PlaybackKeepAliveService::class.java).apply {
                action = PlaybackKeepAliveService.ACTION_START
                putExtra(PlaybackKeepAliveService.EXTRA_HAS_ACTIVE_PLAYBACK, hasActivePlayback)
                putExtra(PlaybackKeepAliveService.EXTRA_HAS_ACTIVE_TIMER, hasActiveTimer)
                putExtra(
                    PlaybackKeepAliveService.EXTRA_USES_UNIFIED_PLAYBACK_NOTIFICATION,
                    usesUnifiedPlaybackNotifications
                )
                putExtra(PlaybackKeepAliveService.EXTRA_KEEP_FOREGROUND_SERVICE_ALIVE, true)
            }
        ContextCompat.startForegroundService(appContext, serviceIntent)
    }
}
