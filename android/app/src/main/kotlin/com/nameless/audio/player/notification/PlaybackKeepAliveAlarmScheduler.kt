package com.nameless.audio.player.notification

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock

object PlaybackKeepAliveAlarmScheduler {
    const val actionHeartbeat = "com.nameless.audio.action.KEEP_ALIVE_HEARTBEAT"

    private const val requestCode = 32003

    /**
     * Doze relaxes `AllowWhileIdle` alarms to roughly one every 9 minutes, so a
     * shorter interval buys nothing while idle. This is a backstop, not the
     * primary timer.
     */
    const val intervalMs = 9L * 60L * 1000L

    /**
     * Callers include the per-event active-sync path, so re-arming is throttled:
     * `setAndAllowWhileIdle` is not free and the exact deadline does not matter
     * for a backstop. Each successful call pushes the deadline out by
     * [intervalMs], which is the intent - while events keep flowing the handler
     * timers are demonstrably alive and the alarm is not needed.
     */
    private const val rearmThrottleMs = 60L * 1000L

    @Volatile
    private var lastArmedElapsedRealtimeMs = Long.MIN_VALUE

    fun ensureScheduled(context: Context) {
        val nowMs = SystemClock.elapsedRealtime()
        if (shouldSkipRearm(nowMs, lastArmedElapsedRealtimeMs)) return
        val alarmManager = alarmManager(context) ?: return
        val triggerAtMs = nowMs + intervalMs
        val operation = pendingIntent(context) ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    triggerAtMs,
                    operation
                )
            } else {
                alarmManager.set(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    triggerAtMs,
                    operation
                )
            }
            lastArmedElapsedRealtimeMs = nowMs
        } catch (_: Exception) {
        }
    }

    /**
     * Always issues the cancel rather than tracking a scheduled flag: process
     * death would clear such a flag while leaving the alarm registered with the
     * system, and a no-op cancel is cheaper than a stray wakeup every 9 minutes.
     */
    fun cancel(context: Context) {
        val alarmManager = alarmManager(context) ?: return
        val operation = pendingIntent(context) ?: return
        try {
            alarmManager.cancel(operation)
        } catch (_: Exception) {
        }
        lastArmedElapsedRealtimeMs = Long.MIN_VALUE
    }

    internal fun shouldSkipRearm(nowMs: Long, lastArmedMs: Long): Boolean =
        lastArmedMs != Long.MIN_VALUE && nowMs - lastArmedMs < rearmThrottleMs

    private fun alarmManager(context: Context): AlarmManager? =
        context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager

    private fun pendingIntent(context: Context): PendingIntent? {
        val appContext = context.applicationContext
        val intent = Intent(appContext, PlaybackKeepAliveAlarmReceiver::class.java)
            .setAction(actionHeartbeat)
        return try {
            PendingIntent.getBroadcast(
                appContext,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } catch (_: Exception) {
            null
        }
    }
}
