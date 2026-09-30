@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.doujin.audio.player.notification

import com.doujin.audio.*

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.media3.session.MediaStyleNotificationHelper

internal fun notificationSessionIdFromIntent(action: String?, sessionId: String?): String? {
    if (action != MainActivity.openSessionFromNotificationAction) return null
    return sessionId?.takeIf { it.isNotBlank() }
}

internal enum class NotificationCommand(
    val actionName: String,
    val requestCodeOffset: Int
) {
    toggle("toggle_session_playback", 1),
    previous("session_skip_previous", 2),
    next("session_skip_next", 3),
    dismissAll("dismiss_all_playback_notifications", 9),
    restore("restore_playback_notifications", 10);

    companion object {
        fun isPlaybackControl(actionName: String): Boolean {
            return actionName == toggle.actionName ||
                actionName == previous.actionName ||
                actionName == next.actionName
        }
    }
}

internal data class UnifiedPlaybackNotificationItem(
    val id: String,
    val title: String,
    val subtitle: String?,
    val artPath: String?,
    val playing: Boolean,
    val hasPrevious: Boolean,
    val hasNext: Boolean
)

internal fun mergeLiveMultiSessionNotificationItems(
    items: List<UnifiedPlaybackNotificationItem>,
    liveItem: UnifiedPlaybackNotificationItem
): List<UnifiedPlaybackNotificationItem> {
    val existing = items.firstOrNull { it.id == liveItem.id } ?: return items
    val mergedLiveItem = liveItem.copy(
        subtitle = liveItem.subtitle ?: existing.subtitle,
        artPath = liveItem.artPath ?: existing.artPath
    )
    return items.map { item ->
        if (item.id == mergedLiveItem.id) mergedLiveItem else item
    }
}

internal data class NotificationTransportActionSpec(
    val command: NotificationCommand,
    val iconResource: Int,
    val labelResource: Int
)

internal fun notificationTransportActionSpecs(
    playing: Boolean,
    hasPrevious: Boolean,
    hasNext: Boolean
): List<NotificationTransportActionSpec> = buildList {
    if (hasPrevious) {
        add(
            NotificationTransportActionSpec(
                NotificationCommand.previous,
                R.drawable.ic_notification_previous_session,
                R.string.playback_action_previous
            )
        )
    }
    add(
        NotificationTransportActionSpec(
            NotificationCommand.toggle,
            if (playing) R.drawable.ic_notification_pause else R.drawable.ic_notification_play,
            if (playing) R.string.playback_action_pause else R.string.playback_action_play
        )
    )
    if (hasNext) {
        add(
            NotificationTransportActionSpec(
                NotificationCommand.next,
                R.drawable.ic_notification_next_session,
                R.string.playback_action_next
            )
        )
    }
}

internal fun notificationCompactActionIndices(
    hasPrevious: Boolean,
    hasNext: Boolean
): List<Int> {
    val actionCount =
        1 + (if (hasPrevious) 1 else 0) + (if (hasNext) 1 else 0)
    return List(actionCount) { it }
}

internal fun addNotificationTransportActions(
    builder: NotificationCompat.Builder,
    context: Context,
    playing: Boolean,
    hasPrevious: Boolean,
    hasNext: Boolean,
    buildIntent: (NotificationCommand) -> PendingIntent
) {
    notificationTransportActionSpecs(playing, hasPrevious, hasNext).forEach { spec ->
        builder.addAction(
            spec.iconResource,
            context.getString(spec.labelResource),
            buildIntent(spec.command)
        )
    }
}

internal data class NotificationIconSpec(
    val resourceId: Int,
    val color: Int
)

internal fun notificationIconSpec(): NotificationIconSpec {
    return NotificationIconSpec(
        resourceId = R.drawable.ic_launcher_foreground,
        color = 0xFFFF5F5C.toInt()
    )
}

internal fun UnifiedPlaybackNotificationItem.hasSameStableNotification(
    other: UnifiedPlaybackNotificationItem
): Boolean {
    return id == other.id &&
        title == other.title &&
        subtitle == other.subtitle &&
        artPath == other.artPath &&
        playing == other.playing &&
        hasPrevious == other.hasPrevious &&
        hasNext == other.hasNext
}

internal fun UnifiedPlaybackNotificationItem.stableNotificationSignature(): String {
    return "$id:$title:$subtitle:$artPath:$playing:$hasPrevious:$hasNext"
}

internal class UnifiedPlaybackNotificationRenderer(
    private val artworkFor: (String?) -> android.graphics.Bitmap?,
    private val mediaSession: androidx.media3.session.MediaSession?
) {
    companion object {
        const val channelId = "com.doujin.audio.channel.playback"
        const val groupKey = "com.doujin.audio.PLAYBACK_GROUP"
        const val dismissNotificationIdExtra = "notificationId"
        const val unifiedNotificationExtra = "com.doujin.audio.UNIFIED_PLAYBACK_NOTIFICATION"
        const val summaryNotificationId = 1107
    }
    fun buildSingleSessionNotification(
        context: Context,
        item: UnifiedPlaybackNotificationItem
    ): android.app.Notification {
        val subtitle = item.subtitle?.takeIf { it.isNotBlank() }
        val builder = basePlaybackNotificationBuilder(
            context,
            item,
            summaryNotificationId,
            ongoing = true
        )
            .setContentText(subtitle)
            .setSubText(null)
            .setContentIntent(buildLaunchIntent(context, sessionId = item.id))
            .setGroup(null)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_ALL)
            .setSortKey(null)

        addTransportActions(builder, context, item)
        if (mediaSession != null) {
            val mediaStyle = MediaStyleNotificationHelper.MediaStyle(mediaSession)
                .setShowActionsInCompactView(*compactActionIndicesFor(item).toIntArray())
            builder.setStyle(mediaStyle)
        } else {
            val mediaStyle = androidx.media.app.NotificationCompat.MediaStyle()
                .setShowActionsInCompactView(*compactActionIndicesFor(item).toIntArray())
            builder.setStyle(mediaStyle)
        }
        return builder.build()
    }

    fun buildMultiSessionNotification(
        context: Context,
        mainItem: UnifiedPlaybackNotificationItem,
        items: List<UnifiedPlaybackNotificationItem>,
        summaryText: String?,
        summaryLines: List<String>
    ): android.app.Notification {
        val childLines = summaryLines.ifEmpty {
            items.map { item -> "${if (item.playing) "*" else "-"} ${item.title}" }
        }
        val builder = basePlaybackNotificationBuilder(
            context,
            mainItem,
            summaryNotificationId,
            ongoing = true
        )
            .setContentText(
                summaryText ?: context.resources.getQuantityString(
                    R.plurals.playback_sessions_count,
                    items.size,
                    items.size
                )
            )
            .setSubText(
                context.resources.getQuantityString(
                    R.plurals.playback_sessions_count,
                    items.size,
                    items.size
                )
            )
            .setContentIntent(buildLaunchIntent(context, sessionId = mainItem.id))
            .setGroup(groupKey)
            .setGroupSummary(true)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_SUMMARY)
            .setSortKey("0_summary")

        addTransportActions(builder, context, mainItem)
        if (mediaSession != null) {
            val mediaStyle = MediaStyleNotificationHelper.MediaStyle(mediaSession)
                .setShowActionsInCompactView(*compactActionIndicesFor(mainItem).toIntArray())
            builder.setStyle(mediaStyle)
        } else {
            val mediaStyle = androidx.media.app.NotificationCompat.MediaStyle()
                .setShowActionsInCompactView(*compactActionIndicesFor(mainItem).toIntArray())
            builder.setStyle(mediaStyle)
        }
        return builder.build()
    }

    fun buildMultiSessionChildNotification(
        context: Context,
        item: UnifiedPlaybackNotificationItem
    ): android.app.Notification {
        val subtitle = item.subtitle?.takeIf { it.isNotBlank() }
        val notificationId = notificationIdFor(item.id)
        val builder = basePlaybackNotificationBuilder(
            context,
            item,
            notificationId,
            ongoing = true
        )
            .setContentText(subtitle)
            .setSubText(null)
            .setContentIntent(buildLaunchIntent(context, sessionId = item.id))
            .setGroup(groupKey)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_SUMMARY)
            .setOngoing(true)
            .setSortKey("1_${item.title}_${item.id}")

        addTransportActions(builder, context, item)
        if (mediaSession != null) {
            val mediaStyle = MediaStyleNotificationHelper.MediaStyle(mediaSession)
                .setShowActionsInCompactView(*compactActionIndicesFor(item).toIntArray())
            builder.setStyle(mediaStyle)
        } else {
            val mediaStyle = androidx.media.app.NotificationCompat.MediaStyle()
                .setShowActionsInCompactView(*compactActionIndicesFor(item).toIntArray())
            builder.setStyle(mediaStyle)
        }
        return builder.build()
    }

    private fun basePlaybackNotificationBuilder(
        context: Context,
        item: UnifiedPlaybackNotificationItem,
        notificationId: Int,
        ongoing: Boolean
    ): NotificationCompat.Builder {
        val appIcon = notificationIconSpec()
        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(appIcon.resourceId)
            .setColor(appIcon.color)
            .setContentTitle(item.title)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setOngoing(ongoing)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .addExtras(Bundle().apply {
                putBoolean(unifiedNotificationExtra, true)
            })
        if (!ongoing) {
            builder.setDeleteIntent(buildDismissIntent(context, notificationId))
        }
        artworkFor(item.artPath)?.let(builder::setLargeIcon)
        return builder
    }

    private fun addTransportActions(
        builder: NotificationCompat.Builder,
        context: Context,
        item: UnifiedPlaybackNotificationItem
    ) {
        addNotificationTransportActions(
            builder = builder,
            context = context,
            playing = item.playing,
            hasPrevious = item.hasPrevious,
            hasNext = item.hasNext,
            buildIntent = { command -> buildControlIntent(context, item.id, command) }
        )
    }

    private fun compactActionIndicesFor(
        item: UnifiedPlaybackNotificationItem
    ): List<Int> = notificationCompactActionIndices(
        hasPrevious = item.hasPrevious,
        hasNext = item.hasNext
    )

    @Synchronized

    private fun buildLaunchIntent(
        context: Context,
        sessionId: String? = null
    ): PendingIntent? {
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            )
            if (sessionId.isNullOrBlank()) {
                removeExtra(MainActivity.notificationSessionIdExtra)
            } else {
                action = MainActivity.openSessionFromNotificationAction
                putExtra(MainActivity.notificationSessionIdExtra, sessionId)
            }
        }
        if (context.packageManager.resolveActivity(launchIntent, 0) == null) return null
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val requestCode = if (sessionId.isNullOrBlank()) {
            0
        } else {
            notificationIdFor(sessionId)
        }
        return PendingIntent.getActivity(context, requestCode, launchIntent, flags)
    }

    private fun buildControlIntent(
        context: Context,
        sessionId: String,
        command: NotificationCommand
    ): PendingIntent {
        val intent = Intent(context, UnifiedPlaybackActionReceiver::class.java).apply {
            action = command.actionName
            putExtra("sessionId", sessionId)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val requestCode = notificationIdFor(sessionId) + command.requestCodeOffset
        return PendingIntent.getBroadcast(context, requestCode, intent, flags)
    }

    private fun buildDismissIntent(context: Context, notificationId: Int): PendingIntent {
        val intent = Intent(context, UnifiedPlaybackActionReceiver::class.java).apply {
            action = NotificationCommand.dismissAll.actionName
            putExtra(dismissNotificationIdExtra, notificationId)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getBroadcast(
            context,
            notificationId + NotificationCommand.dismissAll.requestCodeOffset,
            intent,
            flags
        )
    }

}

internal fun notificationIdFor(sessionId: String): Int {
        val hash = sessionId.hashCode()
        val positiveHash = if (hash == Int.MIN_VALUE) 0 else kotlin.math.abs(hash)
        return 20_000 + (positiveHash % 50_000)
    }
