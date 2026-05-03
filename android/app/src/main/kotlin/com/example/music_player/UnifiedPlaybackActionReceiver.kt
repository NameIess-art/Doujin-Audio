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
        private val mainHandler = Handler(Looper.getMainLooper())
        private val pendingDismissIds = linkedSetOf<Int>()
        private var pendingDismissCount = 0
        private var pendingDismissExtras: Bundle? = null
        private val flushDismissRunnable = Runnable { flushPendingDismisses() }

        @Synchronized
        private fun queueDismiss(intent: Intent) {
            // Block notification re-posts immediately so the Dart side
            // cannot repost notifications while the 160ms debounce runs.
            UnifiedPlaybackNotificationController.dismissPending = true
            // Keep dismissPending latched until explicit restore or clear.
            // This prevents the Dart sync loop from re-posting after swipe dismiss.
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
            val extras = pendingDismissExtras
            pendingDismissIds.clear()
            pendingDismissCount = 0
            pendingDismissExtras = null
            // Treat all swipe/system-removal callbacks as dismiss. We only
            // restore after the app is resumed on Flutter side.
            AudioService.dispatchCustomAction(dismissAction, extras)
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
