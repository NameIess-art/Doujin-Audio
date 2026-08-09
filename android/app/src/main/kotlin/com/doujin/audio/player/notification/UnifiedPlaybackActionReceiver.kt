package com.doujin.audio.player.notification

import com.doujin.audio.player.service.*

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper

class UnifiedPlaybackActionReceiver : BroadcastReceiver() {
    companion object {
        private const val dismissAction = "dismiss_all_playback_notifications"
        private const val dismissSettleDelayMs = 160L
        private const val serviceDeliveryRetryDelayMs = 250L
        private const val maxServiceDeliveryAttempts = 40
        private val mainHandler = Handler(Looper.getMainLooper())
        private val flushDismissRunnable = Runnable { flushPendingDismisses() }

        @Synchronized
        private fun queueDismiss() {
            // Block notification re-posts immediately so the Dart side
            // cannot repost notifications while the 160ms debounce runs.
            UnifiedPlaybackNotificationController.dismissPending = true
            // Keep dismissPending latched until explicit restore or clear.
            // This prevents the Dart sync loop from re-posting after swipe dismiss.
            mainHandler.removeCallbacks(flushDismissRunnable)
            mainHandler.postDelayed(flushDismissRunnable, dismissSettleDelayMs)
        }

        @Synchronized
        private fun flushPendingDismisses() {
            NativePlaybackService.controller()?.dismissNotifications()
        }

        private fun deliverControlAction(
            context: Context,
            action: String,
            requestedSessionId: String,
            attempt: Int,
            pendingResult: BroadcastReceiver.PendingResult
        ) {
            val service = NativePlaybackService.ensureStarted(
                context,
                requireForegroundBootstrap = true
            )
            if (service == null) {
                if (attempt >= maxServiceDeliveryAttempts) {
                    pendingResult.finish()
                    return
                }
                mainHandler.postDelayed(
                    {
                        deliverControlAction(
                            context = context,
                            action = action,
                            requestedSessionId = requestedSessionId,
                            attempt = attempt + 1,
                            pendingResult = pendingResult
                        )
                    },
                    serviceDeliveryRetryDelayMs
                )
                return
            }

            try {
                service.executeNotificationAction(action, requestedSessionId)
            } finally {
                pendingResult.finish()
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action == dismissAction) {
            queueDismiss()
            return
        }
        
        if (!NotificationCommand.isPlaybackControl(action)) return
        val intentSessionId = intent.getStringExtra("sessionId") ?: return
        deliverControlAction(
            context = context.applicationContext,
            action = action,
            requestedSessionId = intentSessionId,
            attempt = 0,
            pendingResult = goAsync()
        )
    }
}
