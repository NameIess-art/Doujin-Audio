@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.doujin.audio.player.notification

import com.doujin.audio.*
import com.doujin.audio.player.service.*

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Notification
import android.app.PendingIntent
import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationManagerCompat
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
    private const val channelId = "com.doujin.audio.channel.playback"
    const val groupKey = "com.doujin.audio.PLAYBACK_GROUP"
    const val dismissNotificationIdExtra = "notificationId"
    private const val unifiedNotificationExtra = "com.doujin.audio.UNIFIED_PLAYBACK_NOTIFICATION"
    const val summaryNotificationId = 1107
    const val foregroundServiceNotificationId = summaryNotificationId
    private const val prefsName = "music_player_notifications"
    private const val activeIdsKey = "active_notification_ids"
    private val activeNotificationIds = linkedSetOf<Int>()
    val activeNotificationCount: Int get() = activeNotificationIds.size
    private val activeItemsById = linkedMapOf<String, UnifiedPlaybackNotificationItem>()
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private var artworkLoader: NotificationArtworkLoader? = null
    private var latestSyncRequest: NotificationSyncRequest? = null
    private var syncGeneration = 0L
    private var lastSummarySignature: String? = null
    private var lastStyleVariant: String? = null
    private val lastNotifyTimestampsMs = mutableMapOf<Int, Long>()
    @Volatile
    var dismissPending = false

    @Synchronized
    fun buildLiveMultiSessionForegroundNotification(
        context: Context,
        liveItem: UnifiedPlaybackNotificationItem
    ): android.app.Notification? {
        if (dismissPending) return null
        val request = latestSyncRequest ?: return null
        if (request.mode != "multi" || request.items.size < 2) return null
        if (request.items.none { it.id == liveItem.id }) return null

        val mergedItems = mergeLiveMultiSessionNotificationItems(
            items = request.items,
            liveItem = liveItem
        )
        val mergedLiveItem = mergedItems.first { it.id == liveItem.id }
        val summaryLines = mergedItems.map(UnifiedPlaybackNotificationItem::title)
        latestSyncRequest = request.copy(
            mainSessionId = mergedLiveItem.id,
            items = mergedItems,
            summaryLines = summaryLines
        )
        activeItemsById.clear()
        mergedItems.forEach { item -> activeItemsById[item.id] = item }

        return buildMultiSessionNotification(
            context = context,
            mainItem = mergedLiveItem,
            items = mergedItems,
            summaryText = request.summaryText,
            summaryLines = summaryLines
        )
    }

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
        syncGeneration += 1
        latestSyncRequest = null
        artworkLoader?.clear()
        activeNotificationIds.clear()
        activeItemsById.clear()
        lastSummarySignature = null
        lastStyleVariant = null
        lastNotifyTimestampsMs.clear()
        dismissPending = false
    }

    private fun markNotified(notificationId: Int) {
        lastNotifyTimestampsMs[notificationId] = android.os.SystemClock.elapsedRealtime()
    }

    private fun postNotification(
        context: Context,
        manager: NotificationManagerCompat,
        notificationId: Int,
        notification: Notification
    ): Boolean {
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        return try {
            manager.notify(notificationId, notification)
            true
        } catch (_: SecurityException) {
            false
        }
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
        if (items.isEmpty()) {
            clear(context)
            return
        }

        val appContext = context.applicationContext
        val request = NotificationSyncRequest(
            mode = mode,
            mainSessionId = mainSessionId,
            items = items.toList(),
            summaryText = summaryText,
            summaryLines = summaryLines.toList(),
            styleVariant = styleVariant
        )
        syncGeneration += 1
        val generation = syncGeneration
        latestSyncRequest = request
        val loader = artworkLoader ?: NotificationArtworkLoader.create(appContext).also {
            artworkLoader = it
        }
        render(appContext, request, forceArtworkPath = null)
        request.items
            .mapNotNull { item -> item.artPath?.trim()?.takeIf(String::isNotEmpty) }
            .distinct()
            .filter { path -> loader.cached(path) == null }
            .forEach { path ->
                loader.request(path) { loadedPath ->
                    mainHandler.post {
                        refreshArtwork(appContext, generation, loadedPath)
                    }
                }
            }
    }

    private fun render(
        context: Context,
        request: NotificationSyncRequest,
        forceArtworkPath: String?
    ) {
        if (dismissPending) return
        val manager = NotificationManagerCompat.from(context)
        ensureChannel(context)
        val postedNotificationIds = postedNotificationIds(context)

        if (request.mode == "multi") {
            syncMultiSession(
                context,
                manager,
                postedNotificationIds,
                request.mainSessionId,
                request.items,
                request.summaryText,
                request.summaryLines,
                request.styleVariant,
                forceArtworkPath
            )
            return
        }

        syncSingleSession(
            context,
            manager,
            postedNotificationIds,
            request.items,
            request.styleVariant,
            forceArtworkPath
        )
    }

    @Synchronized
    private fun refreshArtwork(context: Context, generation: Long, path: String) {
        val request = latestSyncRequest ?: return
        if (
            !shouldRefreshNotificationArtwork(
                generation,
                syncGeneration,
                path,
                request.items.map { it.artPath }
            )
        ) return
        render(context, request, forceArtworkPath = path)
    }

    private fun syncSingleSession(
        context: Context,
        manager: NotificationManagerCompat,
        postedNotificationIds: Set<Int>,
        items: List<UnifiedPlaybackNotificationItem>,
        styleVariant: String?,
        forceArtworkPath: String?
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
            item.artPath == forceArtworkPath ||
                activeItemsById[item.id] != item ||
                !postedNotificationIds.contains(notificationId) ||
                !postedUnifiedNotifications.contains(notificationId) ||
                lastStyleVariant != styleKey
        ) {
            if (item.artPath == forceArtworkPath || !isNotifyThrottled(notificationId, item)) {
                val notification = buildSingleSessionNotification(context, item)
                if (postNotification(context, manager, notificationId, notification)) {
                    markNotified(notificationId)
                }
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
        styleVariant: String?,
        forceArtworkPath: String?
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
            mainItem.artPath == forceArtworkPath ||
                summaryChanged ||
                summaryWasReplacedByForegroundService ||
                !postedNotificationIds.contains(summaryNotificationId)
        ) {
            if (
                mainItem.artPath == forceArtworkPath ||
                    !isNotifyThrottled(summaryNotificationId, mainItem)
            ) {
                val notification = buildMultiSessionNotification(
                    context,
                    mainItem,
                    items,
                    summaryText,
                    summaryLines
                )
                if (
                    postNotification(
                        context,
                        manager,
                        summaryNotificationId,
                        notification
                    )
                ) {
                    markNotified(summaryNotificationId)
                }
            }
        }

        for (item in items) {
            val notificationId = notificationIdFor(item.id)
            if (
                item.artPath == forceArtworkPath ||
                    activeItemsById[item.id]?.hasSameStableNotification(item) != true ||
                    !postedUnifiedNotifications.contains(notificationId) ||
                    !postedNotificationIds.contains(notificationId)
            ) {
                if (item.artPath == forceArtworkPath || !isNotifyThrottled(notificationId, item)) {
                    if (
                        postNotification(
                            context,
                            manager,
                            notificationId,
                            buildMultiSessionChildNotification(context, item)
                        )
                    ) {
                        markNotified(notificationId)
                    }
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
            ongoing = true
        )
            .setContentText(subtitle)
            .setSubText(null)
            .setContentIntent(buildLaunchIntent(context, sessionId = item.id))
            .setGroup(null)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_ALL)
            .setSortKey(null)

        addTransportActions(builder, context, item)
        val mediaSession = NativePlaybackService.controller()?.currentMediaSession()
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
        val mediaSession = NativePlaybackService.controller()?.currentMediaSession()
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
        val mediaSession = NativePlaybackService.controller()?.currentMediaSession()
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
        artworkLoader?.cached(item.artPath)?.let(builder::setLargeIcon)
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
    fun clear(context: Context) {
        syncGeneration += 1
        latestSyncRequest = null
        artworkLoader?.clear()
        dismissPending = false
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
                context.getString(R.string.playback_notification_channel_name),
            NotificationManager.IMPORTANCE_LOW
        ).apply {
                description = context.getString(
                    R.string.playback_notification_channel_description
                )
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

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

    private fun notificationIdFor(sessionId: String): Int {
        val hash = sessionId.hashCode()
        val positiveHash = if (hash == Int.MIN_VALUE) 0 else kotlin.math.abs(hash)
        return 20_000 + (positiveHash % 50_000)
    }
}

private data class NotificationSyncRequest(
    val mode: String,
    val mainSessionId: String?,
    val items: List<UnifiedPlaybackNotificationItem>,
    val summaryText: String?,
    val summaryLines: List<String>,
    val styleVariant: String?
)
