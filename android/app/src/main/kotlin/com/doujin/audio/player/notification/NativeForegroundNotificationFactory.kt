package com.doujin.audio.player.notification

import com.doujin.audio.R
import com.doujin.audio.MainActivity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.annotation.OptIn
import androidx.core.app.NotificationCompat
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaStyleNotificationHelper

internal class NativeForegroundNotificationFactory(
    private val context: Context,
    private val channelId: String
) {
    fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        manager.createNotificationChannel(
            NotificationChannel(
                channelId,
                context.getString(R.string.playback_notification_channel_name),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = context.getString(R.string.playback_notification_channel_description)
                setShowBadge(false)
            }
        )
    }

    // Android requires a MediaStyle foreground notification bound to the active MediaSession
    // with transport actions so SystemUI, lockscreen controls, and OEM power managers
    // consistently recognize the service as active media playback during screen-off.
    @OptIn(UnstableApi::class)
    fun buildNotification(
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
            ?: context.getString(R.string.app_name)
        val resolvedSubtitle = subtitle?.trim()?.takeIf { it.isNotEmpty() }
            ?: context.getString(R.string.keep_alive_playback_active)
        val builder = NotificationCompat.Builder(context, channelId)
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
                context.getString(R.string.playback_action_previous),
                previousIntent
            )
            compactActionIndices += actionIndex++
        }
        if (playPauseIntent != null) {
            builder.addAction(
                if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                context.getString(
                    if (isPlaying) R.string.playback_action_pause else R.string.playback_action_play
                ),
                playPauseIntent
            )
            compactActionIndices += actionIndex++
        }
        if (hasNext && nextIntent != null) {
            builder.addAction(
                android.R.drawable.ic_media_next,
                context.getString(R.string.playback_action_next),
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
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            context, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
