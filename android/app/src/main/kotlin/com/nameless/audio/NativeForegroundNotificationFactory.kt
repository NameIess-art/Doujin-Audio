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

        if (mediaSession != null) {
            builder.setStyle(MediaStyleNotificationHelper.MediaStyle(mediaSession))
        }

        return builder.build()
    }

    fun buildBootstrapNotification(mediaSession: MediaSession?): Notification {
        val builder = baseBuilder()
            .setContentTitle("Nameless Audio")
            .setContentText(context.getString(R.string.keep_alive_timer_active))
            .setCategory(NotificationCompat.CATEGORY_SERVICE)

        if (mediaSession != null) {
            builder.setStyle(MediaStyleNotificationHelper.MediaStyle(mediaSession))
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

    private fun immutablePendingIntentFlag(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE
        } else {
            0
        }
    }
}
