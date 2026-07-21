package com.nameless.audio.player.notification

import com.nameless.audio.R

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
        sessionId: String,
        title: String,
        subtitle: String?,
        mediaSession: MediaSession?,
        playing: Boolean,
        hasPrevious: Boolean,
        hasNext: Boolean
    ): Notification {
        UnifiedPlaybackNotificationController
            .buildLiveMultiSessionForegroundNotification(
                context = context,
                liveItem = UnifiedPlaybackNotificationItem(
                    id = sessionId,
                    title = title,
                    subtitle = subtitle,
                    artPath = null,
                    playing = playing,
                    hasPrevious = hasPrevious,
                    hasNext = hasNext
                )
            )
            ?.let { return it }

        val builder = baseBuilder()
            .setContentTitle(title.ifBlank { context.getString(R.string.app_name) })
            .setContentText(
                subtitle
                    ?.takeIf { it.isNotBlank() }
                    ?: context.getString(R.string.keep_alive_playback_active)
            )
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)

        val mediaStyle = if (mediaSession != null) {
            MediaStyleNotificationHelper.MediaStyle(mediaSession)
        } else null
        
        addNotificationTransportActions(
            builder = builder,
            context = context,
            playing = playing,
            hasPrevious = hasPrevious,
            hasNext = hasNext,
            buildIntent = ::buildControlIntent
        )
        mediaStyle?.setShowActionsInCompactView(
            *notificationCompactActionIndices(hasPrevious, hasNext).toIntArray()
        )

        if (mediaStyle != null) {
            builder.setStyle(mediaStyle)
        }

        return builder.build()
    }

    fun buildBootstrapNotification(mediaSession: MediaSession?): Notification {
        val builder = baseBuilder()
            .setContentTitle(context.getString(R.string.app_name))
            .setContentText(context.getString(R.string.keep_alive_timer_active))
            .setCategory(NotificationCompat.CATEGORY_SERVICE)

        val mediaStyle = if (mediaSession != null) {
            MediaStyleNotificationHelper.MediaStyle(mediaSession)
        } else null
        
        addNotificationTransportActions(
            builder = builder,
            context = context,
            playing = false,
            hasPrevious = true,
            hasNext = true,
            buildIntent = ::buildControlIntent
        )
        mediaStyle?.setShowActionsInCompactView(0, 1, 2)

        if (mediaStyle != null) {
            builder.setStyle(mediaStyle)
        }

        return builder.build()
    }

    private fun baseBuilder(): NotificationCompat.Builder {
        return NotificationCompat.Builder(context, channelId)
            .setSmallIcon(notificationSmallIconResource(context))
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

    private fun buildControlIntent(command: NotificationCommand): PendingIntent {
        val intent = Intent(context, UnifiedPlaybackActionReceiver::class.java).apply {
            action = command.actionName
            putExtra("sessionId", "") // Fallback for focused session
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or immutablePendingIntentFlag()
        return PendingIntent.getBroadcast(
            context,
            command.actionName.hashCode(),
            intent,
            flags
        )
    }

    private fun immutablePendingIntentFlag(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE
        } else {
            0
        }
    }
}
