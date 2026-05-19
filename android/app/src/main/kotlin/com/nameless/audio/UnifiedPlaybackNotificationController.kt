package com.nameless.audio

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import android.util.LruCache
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.media.app.NotificationCompat.MediaStyle

internal enum class NotificationCommand(
    val actionName: String,
    val requestCodeOffset: Int
) {
    toggle("toggle_session_playback", 1),
    previous("session_skip_previous", 2),
    next("session_skip_next", 3),
    dismissAll("dismiss_all_playback_notifications", 9),
    restore("restore_playback_notifications", 10);
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

private fun UnifiedPlaybackNotificationItem.hasSameStableNotification(
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

internal object UnifiedPlaybackNotificationController {
    private const val channelId = "com.nameless.audio.channel.playback"
    private const val channelName = "Playback"
    private const val channelDescription = "Playback notification controls"
    const val groupKey = "com.nameless.audio.PLAYBACK_GROUP"
    const val dismissNotificationIdExtra = "notificationId"
    private const val unifiedNotificationExtra = "com.nameless.audio.UNIFIED_PLAYBACK_NOTIFICATION"
    const val summaryNotificationId = 1107
    const val foregroundServiceNotificationId = summaryNotificationId
    private const val prefsName = "music_player_notifications"
    private const val activeIdsKey = "active_notification_ids"
    private val activeNotificationIds = linkedSetOf<Int>()
    val activeNotificationCount: Int get() = activeNotificationIds.size
    private val activeItemsById = linkedMapOf<String, UnifiedPlaybackNotificationItem>()
    private val artCache = object : LruCache<String, Bitmap>(12) {}
    private var lastSummarySignature: String? = null
    private var lastStyleVariant: String? = null
    private val lastNotifyTimestampsMs = mutableMapOf<Int, Long>()
    var lastRichSummaryNotification: android.app.Notification? = null
    @Volatile
    var dismissPending = false

    private fun isNotifyThrottled(notificationId: Int, item: UnifiedPlaybackNotificationItem? = null): Boolean {
        if (item != null) {
            val previous = activeItemsById[item.id]
            if (previous != null && previous.artPath != item.artPath) {
                // Never throttle if the cover art path has changed.
                return false
            }
        }
        val now = android.os.SystemClock.elapsedRealtime()
        val last = lastNotifyTimestampsMs[notificationId] ?: 0L
        return now - last < 75L
    }

    fun hasUnifiedNotifications(): Boolean {
        return activeNotificationCount > 0
    }

    fun shouldRemoveForegroundNotification(removeNotification: Boolean): Boolean {
        return removeNotification && !hasUnifiedNotifications()
    }

    internal fun markActiveForTest(notificationId: Int) {
        activeNotificationIds.add(notificationId)
    }

    internal fun clearForTest() {
        activeNotificationIds.clear()
        activeItemsById.clear()
        lastSummarySignature = null
        lastStyleVariant = null
        lastRichSummaryNotification = null
        lastNotifyTimestampsMs.clear()
        dismissPending = false
    }

    private fun markNotified(notificationId: Int) {
        lastNotifyTimestampsMs[notificationId] = android.os.SystemClock.elapsedRealtime()
    }

    @Synchronized
    fun sync(
        context: Context,
        mode: String,
        mainSessionId: String?,
        items: List<UnifiedPlaybackNotificationItem>,
        showSummary: Boolean,
        summaryText: String?,
        summaryLines: List<String>,
        styleVariant: String?
    ) {
        // A user-initiated dismiss is being debounced in
        // UnifiedPlaybackActionReceiver. Suppress re-posts so the
        // notification does not reappear after the user swiped it away.
        if (dismissPending) return
        val manager = NotificationManagerCompat.from(context)
        ensureChannel(context)
        val postedNotificationIds = postedNotificationIds(context)

        if (items.isEmpty()) {
            clear(context)
            return
        }

        if (mode == "multi") {
            syncMultiSession(
                context,
                manager,
                postedNotificationIds,
                mainSessionId,
                items,
                summaryText,
                summaryLines,
                styleVariant
            )
            return
        }

        syncSingleSession(context, manager, postedNotificationIds, items, styleVariant)
    }

    private fun syncSingleSession(
        context: Context,
        manager: NotificationManagerCompat,
        postedNotificationIds: Set<Int>,
        items: List<UnifiedPlaybackNotificationItem>,
        styleVariant: String?
    ) {
        val previousIds = buildSet {
            addAll(activeNotificationIds)
            addAll(loadPersistedNotificationIds(context))
        }
        val item = items.firstOrNull() ?: run {
            clear(context)
            return
        }
        val notificationId = summaryNotificationId
        val nextIds = setOf(notificationId)
        val postedUnifiedNotifications = postedUnifiedNotificationIds(context)
        val styleKey = styleVariant ?: "single_thread"
        if (
            activeItemsById[item.id] != item ||
                !postedNotificationIds.contains(notificationId) ||
                !postedUnifiedNotifications.contains(notificationId) ||
                lastStyleVariant != styleKey
        ) {
            if (!isNotifyThrottled(notificationId, item)) {
                val notification = buildSingleSessionNotification(context, item)
                manager.notify(notificationId, notification)
                lastRichSummaryNotification = notification
                markNotified(notificationId)
            }
        }

        previousIds
            .filterNot(nextIds::contains)
            .forEach(manager::cancel)
        activeItemsById.clear()
        activeItemsById[item.id] = item
        activeNotificationIds.apply {
            clear()
            addAll(nextIds)
        }
        lastStyleVariant = styleKey
        lastSummarySignature = "single|${item.id}|${item.playing}|$styleKey"
        savePersistedNotificationIds(context, nextIds)
    }

    private fun syncMultiSession(
        context: Context,
        manager: NotificationManagerCompat,
        postedNotificationIds: Set<Int>,
        mainSessionId: String?,
        items: List<UnifiedPlaybackNotificationItem>,
        summaryText: String?,
        summaryLines: List<String>,
        styleVariant: String?
    ) {
        val previousIds = buildSet {
            addAll(activeNotificationIds)
            addAll(loadPersistedNotificationIds(context))
        }
        val mainItem = items.firstOrNull { it.id == mainSessionId }
            ?: items.firstOrNull { it.playing }
            ?: items.first()
        val nextIds = mutableSetOf(summaryNotificationId)
        val styleKey = styleVariant ?: "multi_thread"
        val summarySignature = buildString {
            append("multi")
            append(styleKey)
            append('\u0000')
            append(mainItem.id)
            append('\u0000')
            append(summaryText.orEmpty())
            append('\u0000')
            append(summaryLines.joinToString("\n"))
            append('\u0000')
            append(items.joinToString("|") {
                it.stableNotificationSignature()
            })
        }
        val summaryChanged = summarySignature != lastSummarySignature
        val postedUnifiedNotifications = postedUnifiedNotificationIds(context)
        val summaryWasReplacedByForegroundService =
            postedNotificationIds.contains(summaryNotificationId) &&
                !postedUnifiedNotifications.contains(summaryNotificationId)
        if (
            summaryChanged ||
                summaryWasReplacedByForegroundService ||
                !postedNotificationIds.contains(summaryNotificationId)
        ) {
            if (!isNotifyThrottled(summaryNotificationId, mainItem)) {
                val notification = buildMultiSessionNotification(
                    context,
                    mainItem,
                    items,
                    summaryText,
                    summaryLines
                )
                manager.notify(
                    summaryNotificationId,
                    notification
                )
                markNotified(summaryNotificationId)
                lastRichSummaryNotification = notification
            }
        }

        for (item in items) {
            val notificationId = notificationIdFor(item.id)
            if (
                activeItemsById[item.id]?.hasSameStableNotification(item) != true ||
                    !postedUnifiedNotifications.contains(notificationId) ||
                    !postedNotificationIds.contains(notificationId)
            ) {
                if (!isNotifyThrottled(notificationId, item)) {
                    manager.notify(
                        notificationId,
                        buildMultiSessionChildNotification(context, item)
                    )
                    markNotified(notificationId)
                }
            }
            nextIds.add(notificationId)
        }

        previousIds
            .filterNot(nextIds::contains)
            .forEach(manager::cancel)
        activeItemsById.clear()
        items.forEach { item -> activeItemsById[item.id] = item }
        activeNotificationIds.apply {
            clear()
            addAll(nextIds)
        }
        lastSummarySignature = summarySignature
        savePersistedNotificationIds(context, nextIds)
    }

    private fun buildSingleSessionNotification(
        context: Context,
        item: UnifiedPlaybackNotificationItem
    ): android.app.Notification {
        val subtitle = item.subtitle?.takeIf { it.isNotBlank() }
        val builder = basePlaybackNotificationBuilder(
            context,
            item,
            summaryNotificationId,
            ongoing = item.playing
        )
            .setContentText(subtitle)
            .setSubText(null)
            .setContentIntent(buildLaunchIntent(context, sessionId = item.id))
            .setGroup(null)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_ALL)
            .setSortKey(null)

        addTransportActions(builder, context, item)
        val mediaStyle = MediaStyle().setShowActionsInCompactView(
            *compactActionIndicesFor(item).toIntArray()
        )
        builder.setStyle(mediaStyle)
        return builder.build()
    }

    private fun buildMultiSessionNotification(
        context: Context,
        mainItem: UnifiedPlaybackNotificationItem,
        items: List<UnifiedPlaybackNotificationItem>,
        summaryText: String?,
        summaryLines: List<String>
    ): android.app.Notification {
        val childLines = summaryLines.ifEmpty {
            items.map { item -> "${if (item.playing) "*" else "-"} ${item.title}" }
        }
        val inboxStyle = NotificationCompat.InboxStyle()
            .setBigContentTitle(mainItem.title)
        childLines.forEach(inboxStyle::addLine)
        val builder = basePlaybackNotificationBuilder(
            context,
            mainItem,
            summaryNotificationId,
            ongoing = items.any { it.playing }
        )
            .setContentText(summaryText ?: "${items.size} sessions")
            .setSubText("${items.size} sessions")
            .setContentIntent(buildLaunchIntent(context, sessionId = mainItem.id))
            .setGroup(groupKey)
            .setGroupSummary(true)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_SUMMARY)
            .setSortKey("0_summary")
            .setStyle(inboxStyle)

        addTransportActions(builder, context, mainItem)
        return builder.build()
    }

    private fun buildMultiSessionChildNotification(
        context: Context,
        item: UnifiedPlaybackNotificationItem
    ): android.app.Notification {
        val subtitle = item.subtitle?.takeIf { it.isNotBlank() }
        val notificationId = notificationIdFor(item.id)
        val builder = basePlaybackNotificationBuilder(
            context,
            item,
            notificationId,
            ongoing = item.playing
        )
            .setContentText(subtitle)
            .setSubText(null)
            .setContentIntent(buildLaunchIntent(context, sessionId = item.id))
            .setGroup(groupKey)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_SUMMARY)
            .setOngoing(true)
            .setSortKey("1_${item.title}_${item.id}")

        addTransportActions(builder, context, item)
        val mediaStyle = MediaStyle().setShowActionsInCompactView(
            *compactActionIndicesFor(item).toIntArray()
        )
        builder.setStyle(mediaStyle)
        return builder.build()
    }

    private fun basePlaybackNotificationBuilder(
        context: Context,
        item: UnifiedPlaybackNotificationItem,
        notificationId: Int,
        ongoing: Boolean
    ): NotificationCompat.Builder {
        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(item.title)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setOngoing(ongoing)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .addExtras(Bundle().apply {
                putBoolean(unifiedNotificationExtra, true)
            })
        if (!ongoing) {
            builder.setDeleteIntent(buildDismissIntent(context, notificationId))
        }
        resolveLargeIcon(item.artPath)?.let(builder::setLargeIcon)
        return builder
    }

    private fun addTransportActions(
        builder: NotificationCompat.Builder,
        context: Context,
        item: UnifiedPlaybackNotificationItem
    ) {
        if (item.hasPrevious) {
            builder.addAction(
                android.R.drawable.ic_media_previous,
                "Previous",
                buildControlIntent(context, item.id, NotificationCommand.previous)
            )
        }
        builder.addAction(
            if (item.playing) {
                android.R.drawable.ic_media_pause
            } else {
                android.R.drawable.ic_media_play
            },
            if (item.playing) "Pause" else "Play",
            buildControlIntent(context, item.id, NotificationCommand.toggle)
        )
        if (item.hasNext) {
            builder.addAction(
                android.R.drawable.ic_media_next,
                "Next",
                buildControlIntent(context, item.id, NotificationCommand.next)
            )
        }
    }

    private fun compactActionIndicesFor(item: UnifiedPlaybackNotificationItem): List<Int> {
        val indices = mutableListOf<Int>()
        var actionIndex = 0
        if (item.hasPrevious) {
            indices.add(actionIndex)
            actionIndex += 1
        }
        indices.add(actionIndex)
        actionIndex += 1
        if (item.hasNext) {
            indices.add(actionIndex)
        }
        return indices
    }

    @Synchronized
    fun clear(context: Context) {
        dismissPending = false
        lastRichSummaryNotification = null
        val manager = NotificationManagerCompat.from(context)
        val previousIds = buildSet {
            addAll(activeNotificationIds)
            addAll(loadPersistedNotificationIds(context))
            addAll(postedNotificationIds(context))
        }
        previousIds.forEach(manager::cancel)
        manager.cancel(summaryNotificationId)
        activeNotificationIds.clear()
        activeItemsById.clear()
        lastSummarySignature = null
        lastStyleVariant = null
        savePersistedNotificationIds(context, emptySet())
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        val existing = manager.getNotificationChannel(channelId)
        if (existing != null) return

        val channel = NotificationChannel(
            channelId,
            channelName,
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = channelDescription
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildLaunchIntent(
        context: Context,
        sessionId: String? = null
    ): PendingIntent? {
        val launchIntent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.apply {
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
            ?: return null
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or (
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        )
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
        val intent = Intent().apply {
            setClassName(context, "${context.packageName}.UnifiedPlaybackActionReceiver")
            action = command.actionName
            putExtra("sessionId", sessionId)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or (
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        )
        val requestCode = notificationIdFor(sessionId) + command.requestCodeOffset
        return PendingIntent.getBroadcast(context, requestCode, intent, flags)
    }

    private fun buildDismissIntent(context: Context, notificationId: Int): PendingIntent {
        val intent = Intent().apply {
            setClassName(context, "${context.packageName}.UnifiedPlaybackActionReceiver")
            action = NotificationCommand.dismissAll.actionName
            putExtra(dismissNotificationIdExtra, notificationId)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or (
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        )
        return PendingIntent.getBroadcast(
            context,
            notificationId + NotificationCommand.dismissAll.requestCodeOffset,
            intent,
            flags
        )
    }

    private fun loadPersistedNotificationIds(context: Context): Set<Int> {
        return context
            .getSharedPreferences(prefsName, Context.MODE_PRIVATE)
            .getStringSet(activeIdsKey, emptySet())
            ?.mapNotNull(String::toIntOrNull)
            ?.toSet()
            ?: emptySet()
    }

    private fun savePersistedNotificationIds(context: Context, ids: Set<Int>) {
        context
            .getSharedPreferences(prefsName, Context.MODE_PRIVATE)
            .edit()
            .putStringSet(activeIdsKey, ids.map(Int::toString).toSet())
            .apply()
    }

    private fun postedNotificationIds(context: Context): Set<Int> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return emptySet()
        }
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return emptySet()
        val knownIds = buildSet {
            add(summaryNotificationId)
            addAll(activeNotificationIds)
            addAll(loadPersistedNotificationIds(context))
        }
        return manager.activeNotifications
            ?.filter { statusBarNotification ->
                val notification = statusBarNotification.notification
                statusBarNotification.id in knownIds || notification.group == groupKey
            }
            ?.map { it.id }
            ?.toSet()
            ?: emptySet()
    }

    private fun postedUnifiedNotificationIds(context: Context): Set<Int> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return emptySet()
        }
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return emptySet()
        return manager.activeNotifications
            ?.filter { statusBarNotification ->
                statusBarNotification.notification.extras
                    ?.getBoolean(unifiedNotificationExtra, false) == true
            }
            ?.map { it.id }
            ?.toSet()
            ?: emptySet()
    }

    private fun resolveLargeIcon(artPath: String?): Bitmap? {
        val path = artPath?.takeIf { it.isNotBlank() } ?: return null
        artCache.get(path)?.let { return it }
        val decoded = BitmapFactory.decodeFile(path) ?: return null
        artCache.put(path, decoded)
        return decoded
    }

    private fun notificationIdFor(sessionId: String): Int {
        val hash = sessionId.hashCode()
        val positiveHash = if (hash == Int.MIN_VALUE) 0 else kotlin.math.abs(hash)
        return 20_000 + (positiveHash % 50_000)
    }
}
