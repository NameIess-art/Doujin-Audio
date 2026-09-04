package com.doujin.audio.player.notification

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock

object PlaybackKeepAliveAlarmScheduler {
    const val actionHeartbeat = "com.doujin.audio.action.KEEP_ALIVE_HEARTBEAT"

    private const val requestCode = 32003

    /**
     * Active playback heartbeats fire more frequently (every 3.5 minutes) using
     * exact alarms when permitted, keeping hardware RTC awake to refresh WakeLock
     * and audio decoding pipelines before OEM power managers or deep sleep stall playback.
     */
    const val activeIntervalMs = 3L * 60L * 1000L + 30_000L

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
     * interval, which is the intent - while events keep flowing the handler
     * timers are demonstrably alive and the alarm is not needed.
     */
    const val rearmThrottleMs = 60L * 1000L
    const val activeRearmThrottleMs = 30L * 1000L

    @Volatile
    private var lastArmedElapsedRealtimeMs = Long.MIN_VALUE

    fun ensureScheduled(context: Context, activePlayback: Boolean = true) {
        val nowMs = SystemClock.elapsedRealtime()
        val currentIntervalMs = if (activePlayback) activeIntervalMs else intervalMs
        val currentThrottleMs = if (activePlayback) activeRearmThrottleMs else rearmThrottleMs
        if (shouldSkipRearm(nowMs, lastArmedElapsedRealtimeMs, currentThrottleMs)) return
        val alarmManager = alarmManager(context) ?: return
        val triggerAtMs = nowMs + currentIntervalMs
        val operation = pendingIntent(context) ?: return
        try {
            scheduleAlarmCompat(alarmManager, triggerAtMs, operation)
            lastArmedElapsedRealtimeMs = nowMs
        } catch (_: Exception) {
        }
    }

    private fun scheduleAlarmCompat(
        alarmManager: AlarmManager,
        triggerAtMs: Long,
        operation: PendingIntent
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (alarmManager.canScheduleExactAlarms()) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    triggerAtMs,
                    operation
                )
            } else {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    triggerAtMs,
                    operation
                )
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            alarmManager.setExactAndAllowWhileIdle(
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

    internal fun shouldSkipRearm(
        nowMs: Long,
        lastArmedMs: Long,
        throttleMs: Long = rearmThrottleMs
    ): Boolean =
        lastArmedMs != Long.MIN_VALUE && nowMs - lastArmedMs < throttleMs

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
