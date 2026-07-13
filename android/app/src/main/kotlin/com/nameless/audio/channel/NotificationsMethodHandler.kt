package com.nameless.audio.channel

import com.nameless.audio.player.notification.*

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class NotificationsMethodHandler(
    private val activity: Activity,
    private val consumePendingSessionId: () -> String?
) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            NotificationsMethods.ARE_NOTIFICATIONS_ENABLED -> {
                result.success(
                    NotificationManagerCompat.from(activity).areNotificationsEnabled()
                )
            }
            NotificationsMethods.OPEN_NOTIFICATION_SETTINGS -> {
                result.success(openNotificationSettings())
            }
            NotificationsMethods.SYNC_UNIFIED_PLAYBACK_NOTIFICATIONS -> {
                syncUnifiedPlaybackNotifications(call)
                result.success(null)
            }
            NotificationsMethods.CLEAR_UNIFIED_PLAYBACK_NOTIFICATIONS -> {
                UnifiedPlaybackNotificationController.clear(activity)
                result.success(null)
            }
            NotificationsMethods.CONSUME_PENDING_NOTIFICATION_SESSION_ID -> {
                result.success(consumePendingSessionId())
            }
            else -> result.notImplemented()
        }
    }

    private fun syncUnifiedPlaybackNotifications(call: MethodCall) {
        val rawItems = call.argument<List<Map<String, Any?>>>("items") ?: emptyList()
        val mode = call.argument<String>("mode") ?: "single"
        val mainSessionId = call.argument<String>("mainSessionId")
        val showSummary = call.argument<Boolean>("showSummary") ?: false
        val summaryText = call.argument<String>("summaryText")
        val summaryLines = call.argument<List<String>>("summaryLines") ?: emptyList()
        val styleVariant = call.argument<String>("styleVariant")
        val items = rawItems.mapNotNull { raw ->
            val id = raw["id"] as? String ?: return@mapNotNull null
            val title = raw["title"] as? String ?: return@mapNotNull null
            UnifiedPlaybackNotificationItem(
                id = id,
                title = title,
                subtitle = raw["subtitle"] as? String,
                artPath = raw["artPath"] as? String,
                playing = raw["playing"] as? Boolean ?: false,
                hasPrevious = raw["hasPrevious"] as? Boolean ?: false,
                hasNext = raw["hasNext"] as? Boolean ?: false
            )
        }
        UnifiedPlaybackNotificationController.sync(
            activity,
            mode,
            mainSessionId,
            items,
            showSummary,
            summaryText,
            summaryLines,
            styleVariant
        )
    }

    private fun openNotificationSettings(): Boolean {
        return try {
            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                putExtra("android.provider.extra.APP_PACKAGE", activity.packageName)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            try {
                val fallbackIntent = Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", activity.packageName, null)
                ).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
                activity.startActivity(fallbackIntent)
                true
            } catch (_: Exception) {
                false
            }
        }
    }
}
