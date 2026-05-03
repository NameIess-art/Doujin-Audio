package com.example.music_player

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import com.ryanheise.audioservice.AudioService

class UnifiedPlaybackActionReceiver : BroadcastReceiver() {
    companion object {
        private const val dismissAction = "dismiss_all_playback_notifications"
        private const val restoreAction = "restore_playback_notifications"
        private const val dismissNotificationIdExtra = "notificationId"
        private const val dismissSettleDelayMs = 160L
        private const val dismissPendingSafetyTimeoutMs = 30_000L
        private val mainHandler = Handler(Looper.getMainLooper())
        private val pendingDismissIds = linkedSetOf<Int>()
        private var pendingDismissCount = 0
        private var pendingDismissExtras: Bundle? = null
        private val flushDismissRunnable = Runnable { flushPendingDismisses() }
        private val dismissPendingSafetyRunnable = Runnable {
            UnifiedPlaybackNotificationController.dismissPending = false
        }

        @Synchronized
        private fun queueDismiss(intent: Intent) {
            // Block notification re-posts immediately so the Dart side
            // cannot repost notifications while the 160ms debounce runs.
            UnifiedPlaybackNotificationController.dismissPending = true
            // Safety timeout: if the Dart engine is killed before clear() is called,
            // reset dismissPending so notifications are not permanently blocked.
            mainHandler.removeCallbacks(dismissPendingSafetyRunnable)
            mainHandler.postDelayed(dismissPendingSafetyRunnable, dismissPendingSafetyTimeoutMs)
            val notificationId = intent.getIntExtra(dismissNotificationIdExtra, Int.MIN_VALUE)
            if (notificationId != Int.MIN_VALUE) {
                pendingDismissIds.add(notificationId)
            }
            pendingDismissCount += 1
            pendingDismissExtras = intent.extras
            mainHandler.removeCallbacks(flushDismissRunnable)
            mainHandler.postDelayed(flushDismissRunnable, dismissSettleDelayMs)
        }

        @Synchronized
        private fun flushPendingDismisses() {
            // Only restore when multiple *different* notification IDs are
            // dismissed simultaneously. The same ID dismissed multiple times
            // (high count, single ID) is Android duplicating a single swipe —
            // that should be treated as a real dismiss, not a restore.
            val shouldRestore = pendingDismissIds.size > 1
            val extras = pendingDismissExtras
            pendingDismissIds.clear()
            pendingDismissCount = 0
            pendingDismissExtras = null
            // For restore, clear dismissPending immediately so that the
            // subsequent sync from restoreNotificationsAfterSystemClear()
            // is not blocked. For dismiss, keep it set until the Dart side
            // calls clear() to prevent a re-post race.
            if (shouldRestore) {
                UnifiedPlaybackNotificationController.dismissPending = false
                mainHandler.removeCallbacks(dismissPendingSafetyRunnable)
            }
            AudioService.dispatchCustomAction(
                if (shouldRestore) restoreAction else dismissAction,
                extras
            )
        }
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action == dismissAction) {
            queueDismiss(intent)
            return
        }
        AudioService.dispatchCustomAction(action, intent.extras)
    }
}
