@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.doujin.audio.player.notification

import com.doujin.audio.R
import com.doujin.audio.player.service.*

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationManagerCompat

internal object UnifiedPlaybackNotificationController {
    const val groupKey = UnifiedPlaybackNotificationRenderer.groupKey
    const val dismissNotificationIdExtra = UnifiedPlaybackNotificationRenderer.dismissNotificationIdExtra
    const val summaryNotificationId = UnifiedPlaybackNotificationRenderer.summaryNotificationId
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

    private fun renderer() = UnifiedPlaybackNotificationRenderer(
        artworkFor = { path -> artworkLoader?.cached(path) },
        mediaSession = NativePlaybackService.controller()?.currentMediaSession()
    )

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

        return renderer().buildMultiSessionNotification(
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

    fun trimArtworkMemory() {
        artworkLoader?.clear()
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
        val styleKey = styleVariant ?: "multi_thread"
        if (
            item.artPath == forceArtworkPath ||
                activeItemsById[item.id] != item ||
                !postedNotificationIds.contains(notificationId) ||
                !postedUnifiedNotifications.contains(notificationId) ||
                lastStyleVariant != styleKey
        ) {
            if (item.artPath == forceArtworkPath || !isNotifyThrottled(notificationId, item)) {
                val notification = renderer().buildSingleSessionNotification(context, item)
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
                val notification = renderer().buildMultiSessionNotification(
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
                            renderer().buildMultiSessionChildNotification(context, item)
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
        val existing = manager.getNotificationChannel(UnifiedPlaybackNotificationRenderer.channelId)
        if (existing != null) return

        val channel = NotificationChannel(
            UnifiedPlaybackNotificationRenderer.channelId,
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
                    ?.getBoolean(UnifiedPlaybackNotificationRenderer.unifiedNotificationExtra, false) == true
            }
            ?.map { it.id }
            ?.toSet()
            ?: emptySet()
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
