package com.nameless.audio.channel

import com.nameless.audio.player.notification.*

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class NotificationsMethodHandler(
    private val activity: Activity,
    private val consumePendingSessionId: () -> String?
) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val envelope = ChannelEnvelopeResult(result)
        try {
            when (call.method) {
                NotificationsMethods.ARE_NOTIFICATIONS_ENABLED -> {
                    envelope.success(
                    NotificationManagerCompat.from(activity).areNotificationsEnabled()
                    )
                }
                NotificationsMethods.OPEN_NOTIFICATION_SETTINGS -> {
                    envelope.success(openNotificationSettings())
                }
                NotificationsMethods.SYNC_UNIFIED_PLAYBACK_NOTIFICATIONS -> {
                    syncUnifiedPlaybackNotifications(call)
                    envelope.success(null)
                }
                NotificationsMethods.CLEAR_UNIFIED_PLAYBACK_NOTIFICATIONS -> {
                    UnifiedPlaybackNotificationController.clear(activity)
                    envelope.success(null)
                }
                NotificationsMethods.CONSUME_PENDING_NOTIFICATION_SESSION_ID -> {
                    envelope.success(consumePendingSessionId())
                }
                else -> result.notImplemented()
            }
        } catch (error: IllegalArgumentException) {
            envelope.error(
                ChannelErrorCodes.INVALID_ARGUMENT,
                error.message ?: "Invalid arguments.",
                mapOf("method" to call.method)
            )
        }
    }

    private fun syncUnifiedPlaybackNotifications(call: MethodCall) {
        val arguments = call.argumentReader()
        val rawItems = arguments.requiredList("items")
        val mode = arguments.requiredString("mode")
        val mainSessionId = arguments.requiredNullableString("mainSessionId")
        val showSummary = arguments.requiredBoolean("showSummary")
        val summaryText = arguments.requiredNullableString("summaryText")
        val summaryLines = arguments.requiredStringList("summaryLines", allowBlank = true)
        val styleVariant = arguments.requiredString("styleVariant")
        val items = rawItems.mapIndexed { index, item ->
            require(item is Map<*, *>) { "Invalid notification item at items[$index]" }
            val id = item["id"] as? String
            val title = item["title"] as? String
            require(!id.isNullOrBlank()) { "Missing item id at items[$index]" }
            require(!title.isNullOrBlank()) { "Missing item title at items[$index]" }
            val optionalStrings = listOf("subtitle", "artPath")
            optionalStrings.forEach { key ->
                require(item[key] == null || item[key] is String) {
                    "Invalid item string at items[$index].$key"
                }
            }
            val booleans = listOf("playing", "hasPrevious", "hasNext")
            booleans.forEach { key ->
                require(item[key] is Boolean) {
                    "Missing or invalid item boolean at items[$index].$key"
                }
            }
            UnifiedPlaybackNotificationItem(
                id = id,
                title = title,
                subtitle = item["subtitle"] as? String,
                artPath = item["artPath"] as? String,
                playing = item["playing"] as Boolean,
                hasPrevious = item["hasPrevious"] as Boolean,
                hasNext = item["hasNext"] as Boolean
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
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                    putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                    putExtra("android.provider.extra.APP_PACKAGE", activity.packageName)
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
            } else {
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", activity.packageName, null)
                ).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
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
