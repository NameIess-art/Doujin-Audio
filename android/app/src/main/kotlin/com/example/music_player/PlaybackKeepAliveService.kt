package com.example.music_player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

class PlaybackKeepAliveService : Service() {
    companion object {
        const val ACTION_START = "com.example.music_player.action.START_KEEP_ALIVE"
        const val ACTION_STOP = "com.example.music_player.action.STOP_KEEP_ALIVE"
        const val EXTRA_HAS_ACTIVE_PLAYBACK = "has_active_playback"
        const val EXTRA_HAS_ACTIVE_TIMER = "has_active_timer"
        const val EXTRA_USES_UNIFIED_PLAYBACK_NOTIFICATION =
            "uses_unified_playback_notification"
        const val EXTRA_KEEP_FOREGROUND_SERVICE_ALIVE =
            "keep_foreground_service_alive"

        private const val CHANNEL_ID = "playback_keep_alive"
        private const val UNIFIED_CHANNEL_ID = "com.example.music_player.channel.playback"
        private const val CHANNEL_NAME = "Playback"
        private const val GROUP_KEY = "com.example.music_player.PLAYBACK_GROUP"
        private const val NOTIFICATION_ID = 1107
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var currentNotificationId: Int? = null
    private var currentForegroundSignature: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return when (intent?.action) {
            ACTION_STOP -> {
                val hasUnifiedNotifications =
                    UnifiedPlaybackNotificationController.activeNotificationCount > 0
                stopForegroundCompat(detachOnly = hasUnifiedNotifications)
                releaseWakeLock()
                currentForegroundSignature = null
                currentNotificationId = null
                stopSelf()
                START_NOT_STICKY
            }
            else -> {
                val hasActivePlayback =
                    intent?.getBooleanExtra(EXTRA_HAS_ACTIVE_PLAYBACK, false) == true
                val hasActiveTimer =
                    intent?.getBooleanExtra(EXTRA_HAS_ACTIVE_TIMER, false) == true
                val usesUnifiedPlaybackNotification =
                    intent?.getBooleanExtra(
                        EXTRA_USES_UNIFIED_PLAYBACK_NOTIFICATION,
                        false
                    ) == true
                val keepForegroundServiceAlive =
                    intent?.getBooleanExtra(
                        EXTRA_KEEP_FOREGROUND_SERVICE_ALIVE,
                        false
                    ) == true

                if (!keepForegroundServiceAlive) {
                    val hasUnifiedNotifications =
                        UnifiedPlaybackNotificationController.activeNotificationCount > 0
                    stopForegroundCompat(detachOnly = hasUnifiedNotifications)
                    releaseWakeLock()
                    currentForegroundSignature = null
                    currentNotificationId = null
                    stopSelf()
                    START_NOT_STICKY
                } else {
                    createNotificationChannels()
                    // Use a structural signature that does NOT include
                    // hasActivePlayback so that toggling play/pause does not
                    // cause startForeground to re-post the notification and
                    // overwrite the unified controller's rich notification.
                    val foregroundSignature = listOf(
                        NOTIFICATION_ID,
                        hasActiveTimer,
                        usesUnifiedPlaybackNotification,
                        keepForegroundServiceAlive
                    ).joinToString("|")
                    val alreadyForeground = currentNotificationId == NOTIFICATION_ID
                    val needsForegroundRefresh =
                        !alreadyForeground ||
                            currentForegroundSignature != foregroundSignature

                    if (needsForegroundRefresh) {
                        // When unified notifications manage the same
                        // notification ID and we are already in foreground,
                        // skip the re-post to avoid a visual flash.
                        val skipNotificationRepost = usesUnifiedPlaybackNotification &&
                            alreadyForeground
                        if (!skipNotificationRepost) {
                            ServiceCompat.startForeground(
                                this,
                                NOTIFICATION_ID,
                                buildNotification(
                                    hasActivePlayback = hasActivePlayback,
                                    hasActiveTimer = hasActiveTimer,
                                    usesUnifiedPlaybackNotification =
                                        usesUnifiedPlaybackNotification
                                ),
                                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                            )
                        }
                        currentNotificationId = NOTIFICATION_ID
                        currentForegroundSignature = foregroundSignature
                    } else {
                        currentNotificationId = NOTIFICATION_ID
                    }
                    if (hasActivePlayback || hasActiveTimer) {
                        acquireWakeLock()
                    } else {
                        releaseWakeLock()
                    }
                    START_REDELIVER_INTENT
                }
            }
        }
    }

    override fun onDestroy() {
        val hasUnifiedNotifications =
            UnifiedPlaybackNotificationController.activeNotificationCount > 0
        stopForegroundCompat(detachOnly = hasUnifiedNotifications)
        releaseWakeLock()
        currentForegroundSignature = null
        currentNotificationId = null
        super.onDestroy()
    }

    private fun buildNotification(
        hasActivePlayback: Boolean,
        hasActiveTimer: Boolean,
        usesUnifiedPlaybackNotification: Boolean
    ): Notification {
        if (usesUnifiedPlaybackNotification) {
            UnifiedPlaybackNotificationController.lastRichSummaryNotification?.let {
                return it
            }
        }
        val contentText = if (hasActiveTimer) {
            "睡眠定时器运行中"
        } else if (usesUnifiedPlaybackNotification) {
            "正在播放"
        } else if (hasActivePlayback) {
            "正在播放"
        } else {
            null
        }

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        val builder = NotificationCompat.Builder(
            this,
            if (usesUnifiedPlaybackNotification) UNIFIED_CHANNEL_ID else CHANNEL_ID
        )
            .setContentTitle("AudioPlayer")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(
                if (usesUnifiedPlaybackNotification) {
                    NotificationCompat.CATEGORY_TRANSPORT
                } else {
                    NotificationCompat.CATEGORY_SERVICE
                }
            )
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .apply {
                if (!contentText.isNullOrBlank()) {
                    setContentText(contentText)
                }
                if (pendingIntent != null) {
                    setContentIntent(pendingIntent)
                }
                if (usesUnifiedPlaybackNotification) {
                    setGroup(GROUP_KEY)
                    setGroupSummary(true)
                    setSortKey("0_summary")
                }
            }
        return builder.build()
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Keeps playback alive while audio or timer is active."
                    setShowBadge(false)
                }
            )
        }
        if (manager.getNotificationChannel(UNIFIED_CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    UNIFIED_CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Playback notification controls"
                    setShowBadge(false)
                }
            )
        }
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return

        try {
            val powerManager = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "$packageName:playback_keep_alive"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
            wakeLock = null
        }
    }

    private fun releaseWakeLock() {
        val currentWakeLock = wakeLock ?: return
        try {
            if (currentWakeLock.isHeld) {
                currentWakeLock.release()
            }
        } catch (_: RuntimeException) {
            // Ignore stale wakelock state.
        } finally {
            wakeLock = null
        }
    }

    private fun stopForegroundCompat(detachOnly: Boolean = false) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(
                if (detachOnly) STOP_FOREGROUND_DETACH else STOP_FOREGROUND_REMOVE
            )
        } else {
            @Suppress("DEPRECATION")
            stopForeground(!detachOnly)
        }
    }
}
