package com.doujin.audio.player.notification

import com.doujin.audio.R
import com.doujin.audio.MainActivity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.annotation.OptIn
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaStyleNotificationHelper
import com.doujin.audio.player.service.NATIVE_PLAYBACK_TRANSPORT_NEXT
import com.doujin.audio.player.service.NATIVE_PLAYBACK_TRANSPORT_PLAY_PAUSE
import com.doujin.audio.player.service.NATIVE_PLAYBACK_TRANSPORT_PREVIOUS
import com.doujin.audio.player.session.NativePlaybackSession

@OptIn(UnstableApi::class)
internal class NativeForegroundPlaybackNotification(
    private val service: Service,
    private val transportIntent: (String) -> Intent
) {
    private companion object {
        const val CHANNEL_ID = "com.doujin.audio.channel.playback"
        const val NOTIFICATION_ID = 1107
        const val REQUEST_CODE_PREVIOUS = 11071
        const val REQUEST_CODE_PLAY_PAUSE = 11072
        const val REQUEST_CODE_NEXT = 11073
    }

    fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = service.getSystemService(NotificationManager::class.java)
            ?: return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                service.getString(R.string.playback_notification_channel_name),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = service.getString(R.string.playback_notification_channel_description)
                setShowBadge(false)
            }
        )
    }

    fun signature(session: NativePlaybackSession, attachedToPlayer: Boolean): String {
        val isPlaying = session.playerOrNull()?.let { it.isPlaying || it.playWhenReady } == true
        val hasPrevious = session.hasPreviousMediaItem()
        val hasNext = session.hasNextMediaItem()
        return "playback:${session.sessionId}:$attachedToPlayer:$isPlaying:" +
            "$hasPrevious:$hasNext:${session.title}:${session.subtitle.orEmpty()}"
    }

    fun startPlayback(session: NativePlaybackSession?, mediaSession: MediaSession?) {
        val isPlaying = session?.playerOrNull()?.let { it.isPlaying || it.playWhenReady } == true
        startForeground(buildNotification(
            mediaSession = mediaSession,
            title = session?.title,
            subtitle = session?.subtitle,
            isPlaying = isPlaying,
            hasPrevious = session?.hasPreviousMediaItem() == true,
            hasNext = session?.hasNextMediaItem() == true,
            previousIntent = transportPendingIntent(NATIVE_PLAYBACK_TRANSPORT_PREVIOUS, REQUEST_CODE_PREVIOUS),
            playPauseIntent = transportPendingIntent(NATIVE_PLAYBACK_TRANSPORT_PLAY_PAUSE, REQUEST_CODE_PLAY_PAUSE),
            nextIntent = transportPendingIntent(NATIVE_PLAYBACK_TRANSPORT_NEXT, REQUEST_CODE_NEXT)
        ))
    }

    fun startBootstrap(mediaSession: MediaSession?) =
        startForeground(buildNotification(mediaSession = mediaSession))

    private fun startForeground(notification: Notification) = ServiceCompat.startForeground(
        service,
        NOTIFICATION_ID,
        notification,
        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
    )

    fun stop(wasStarted: Boolean) {
        if (wasStarted) service.stopForeground(Service.STOP_FOREGROUND_REMOVE)
        service.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
    }

    fun isPosted(): Boolean? {
        return try {
            val manager = service.getSystemService(NotificationManager::class.java) ?: return null
            if (!manager.areNotificationsEnabled()) return null
            manager.activeNotifications.any { it.id == NOTIFICATION_ID }
        } catch (_: Exception) {
            null
        }
    }

    private fun transportPendingIntent(command: String, requestCode: Int): PendingIntent {
        return PendingIntent.getService(
            service.applicationContext,
            requestCode,
            transportIntent(command),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    // Android requires a MediaStyle foreground notification bound to the active MediaSession
    // with transport actions so SystemUI, lockscreen controls, and OEM power managers
    // consistently recognize the service as active media playback during screen-off.
    private fun buildNotification(
        mediaSession: MediaSession? = null,
        title: String? = null,
        subtitle: String? = null,
        isPlaying: Boolean = false,
        hasPrevious: Boolean = false,
        hasNext: Boolean = false,
        previousIntent: PendingIntent? = null,
        playPauseIntent: PendingIntent? = null,
        nextIntent: PendingIntent? = null
    ): Notification {
        val resolvedTitle = title?.trim()?.takeIf { it.isNotEmpty() }
            ?: service.getString(R.string.app_name)
        val resolvedSubtitle = subtitle?.trim()?.takeIf { it.isNotEmpty() }
            ?: service.getString(R.string.keep_alive_playback_active)
        val builder = NotificationCompat.Builder(service, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle(resolvedTitle)
            .setContentText(resolvedSubtitle)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setContentIntent(launchPendingIntent())
            .setShowWhen(false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)

        val compactActionIndices = mutableListOf<Int>()
        var actionIndex = 0
        if (hasPrevious && previousIntent != null) {
            builder.addAction(
                android.R.drawable.ic_media_previous,
                service.getString(R.string.playback_action_previous),
                previousIntent
            )
            compactActionIndices += actionIndex++
        }
        if (playPauseIntent != null) {
            builder.addAction(
                if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                service.getString(
                    if (isPlaying) R.string.playback_action_pause else R.string.playback_action_play
                ),
                playPauseIntent
            )
            compactActionIndices += actionIndex++
        }
        if (hasNext && nextIntent != null) {
            builder.addAction(
                android.R.drawable.ic_media_next,
                service.getString(R.string.playback_action_next),
                nextIntent
            )
            compactActionIndices += actionIndex++
        }
        if (mediaSession != null) {
            val style = MediaStyleNotificationHelper.MediaStyle(mediaSession)
            if (compactActionIndices.isNotEmpty()) {
                style.setShowActionsInCompactView(*compactActionIndices.take(3).toIntArray())
            }
            builder.setStyle(style)
        }
        return builder.build()
    }

    private fun launchPendingIntent(): PendingIntent {
        val launchIntent = Intent(service, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            service, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
