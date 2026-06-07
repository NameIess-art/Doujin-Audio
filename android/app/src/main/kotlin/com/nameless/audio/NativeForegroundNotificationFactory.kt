package com.nameless.audio

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaStyleNotificationHelper

internal class NativeForegroundNotificationFactory(
    private val context: Context,
    private val channelId: String
) {
    fun buildPlaybackNotification(
        title: String,
        subtitle: String?,
        mediaSession: MediaSession?,
        allowRichSummary: Boolean
    ): Notification {
        if (allowRichSummary) {
            UnifiedPlaybackNotificationController.lastRichSummaryNotification?.let {
                return it
            }
        }
        val builder = baseBuilder()
            .setContentTitle(title.ifBlank { "Nameless Audio" })
            .setContentText(
                subtitle
                    ?.takeIf { it.isNotBlank() }
                    ?: context.getString(R.string.keep_alive_playback_active)
            )
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)

        val mediaStyle = if (mediaSession != null) {
            MediaStyleNotificationHelper.MediaStyle(mediaSession)
        } else null
        
        // Add default actions for fallback notification
        builder.addAction(
            NotificationCompat.Action(
                android.R.drawable.ic_media_previous,
                "Previous",
                buildControlIntent("session_skip_previous")
            )
        )
        builder.addAction(
            NotificationCompat.Action(
                android.R.drawable.ic_media_play,
                "Play/Pause",
                buildControlIntent("toggle_session_playback")
            )
        )
        builder.addAction(
            NotificationCompat.Action(
                android.R.drawable.ic_media_next,
                "Next",
                buildControlIntent("session_skip_next")
            )
        )
        mediaStyle?.setShowActionsInCompactView(0, 1, 2)

        if (mediaStyle != null) {
            builder.setStyle(mediaStyle)
        }

        return builder.build()
    }

    fun buildBootstrapNotification(mediaSession: MediaSession?): Notification {
        val builder = baseBuilder()
            .setContentTitle("Nameless Audio")
            .setContentText(context.getString(R.string.keep_alive_timer_active))
            .setCategory(NotificationCompat.CATEGORY_SERVICE)

        val mediaStyle = if (mediaSession != null) {
            MediaStyleNotificationHelper.MediaStyle(mediaSession)
        } else null
        
        builder.addAction(
            NotificationCompat.Action(
                android.R.drawable.ic_media_previous,
                "Previous",
                buildControlIntent("session_skip_previous")
            )
        )
        builder.addAction(
            NotificationCompat.Action(
                android.R.drawable.ic_media_play,
                "Play/Pause",
                buildControlIntent("toggle_session_playback")
            )
        )
        builder.addAction(
            NotificationCompat.Action(
                android.R.drawable.ic_media_next,
                "Next",
                buildControlIntent("session_skip_next")
            )
        )
        mediaStyle?.setShowActionsInCompactView(0, 1, 2)

        if (mediaStyle != null) {
            builder.setStyle(mediaStyle)
        }

        return builder.build()
    }

    private fun baseBuilder(): NotificationCompat.Builder {
        return NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(launchPendingIntent())
            .setShowWhen(false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
    }

    private fun launchPendingIntent(): PendingIntent? {
        val launchIntent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
        return launchIntent?.let {
            PendingIntent.getActivity(
                context,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or immutablePendingIntentFlag()
            )
        }
    }

    private fun buildControlIntent(action: String): PendingIntent {
        val intent = Intent().apply {
            setClassName(context, "${context.packageName}.UnifiedPlaybackActionReceiver")
            this.action = action
            putExtra("sessionId", "") // Fallback for focused session
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or immutablePendingIntentFlag()
        return PendingIntent.getBroadcast(context, action.hashCode(), intent, flags)
    }

    private fun immutablePendingIntentFlag(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE
        } else {
            0
        }
    }
}
