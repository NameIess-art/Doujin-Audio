package com.doujin.audio.player.notification

import com.doujin.audio.player.service.NativePlaybackService

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Doze-proof heartbeat for long screen-off playback.
 *
 * Everything else in the service schedules on [android.os.Handler], i.e. the
 * `uptimeMillis` clock, which does not advance in deep sleep. That is normally
 * masked by the playback wake lock, but two cases escape it:
 *
 *  - the stop-grace window, where the wake lock is deliberately released, so
 *    the grace timer can stall and leave a paused service running indefinitely;
 *  - an OEM power manager revoking our wake lock mid-playback, which stalls the
 *    health check and progress timers with no way to notice.
 *
 * This alarm uses the elapsed-realtime clock and `AllowWhileIdle`, so it fires
 * regardless, and only asks the service to re-evaluate itself.
 */
class PlaybackKeepAliveAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != PlaybackKeepAliveAlarmScheduler.actionHeartbeat) return
        val appContext = context.applicationContext
        val pendingResult = goAsync()
        val deliveryWakeLock =
            PlaybackTimerAlarmScheduler.acquireDeliveryWakeLock(appContext)
        try {
            val service = NativePlaybackService.controller()
            if (service == null) {
                // Deliberately does not start the service. An alarm can outlive
                // the process (cancel() only runs while we are alive), and
                // resurrecting a dead playback service from a backstop timer is
                // never what the user asked for. Drop the stale alarm instead.
                PlaybackKeepAliveAlarmScheduler.cancel(appContext)
            } else {
                service.onKeepAliveHeartbeat()
            }
        } catch (_: Throwable) {
            // Never let a heartbeat failure kill playback.
        } finally {
            try {
                pendingResult.finish()
            } finally {
                try {
                    if (deliveryWakeLock?.isHeld == true) deliveryWakeLock.release()
                } catch (_: RuntimeException) {
                }
            }
        }
    }
}
