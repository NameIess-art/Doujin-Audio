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
    // so the system treats playback as an active media session during screen-off.
    @OptIn(UnstableApi::class)
    fun buildNotification(
        mediaSession: MediaSession? = null,
        title: String? = null,
        subtitle: String? = null
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
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        if (mediaSession != null) {
            builder.setStyle(MediaStyleNotificationHelper.MediaStyle(mediaSession))
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
