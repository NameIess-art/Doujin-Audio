package com.doujin.audio.player.notification

import com.doujin.audio.player.service.*

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

internal const val PLAYBACK_CONTROL_DELIVERY_TIMEOUT_MS = 8_000L

internal class PlaybackControlDeliveryCompletion(
    private val onFinish: () -> Unit
) {
    private val finished = AtomicBoolean(false)

    fun finish(beforeFinish: () -> Unit = {}): Boolean {
        if (!finished.compareAndSet(false, true)) return false
        try {
            beforeFinish()
        } finally {
            onFinish()
        }
        return true
    }
}

class UnifiedPlaybackActionReceiver : BroadcastReceiver() {
    companion object {
        private const val dismissAction = "dismiss_all_playback_notifications"
        private const val dismissSettleDelayMs = 160L
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
            pendingResult: BroadcastReceiver.PendingResult
        ) {
            val ownerId = "notification-action-${UUID.randomUUID()}"
            var timeout: Runnable? = null
            val completion = PlaybackControlDeliveryCompletion {
                NativePlaybackService.removeControllerListener(ownerId)
                timeout?.let(mainHandler::removeCallbacks)
                try {
                    pendingResult.finish()
                } finally {
                    NativePlaybackService.endCommandDelivery()
                }
            }
            fun execute(service: NativePlaybackService) {
                completion.finish {
                    service.executeNotificationAction(action, requestedSessionId)
                }
            }
            timeout = Runnable { completion.finish() }
            try {
                NativePlaybackService.addControllerListener(ownerId) { service ->
                    if (service != null) mainHandler.post { execute(service) }
                }
                mainHandler.postDelayed(timeout, PLAYBACK_CONTROL_DELIVERY_TIMEOUT_MS)
                NativePlaybackService.ensureStarted(
                    context,
                    requireForegroundBootstrap = true
                )?.let(::execute)
            } catch (_: RuntimeException) {
                completion.finish()
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
        val pendingResult = goAsync()
        NativePlaybackService.beginCommandDelivery()
        deliverControlAction(
            context = context.applicationContext,
            action = action,
            requestedSessionId = intentSessionId,
            pendingResult = pendingResult
        )
    }
}
