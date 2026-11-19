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

    // Service events and the alarm receiver both run on the main thread.
    private var pendingDeadlineMs: Long? = null

    fun ensureScheduled(context: Context, activePlayback: Boolean = true) {
        val alarmManager = alarmManager(context) ?: return
        val canExact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            alarmManager.canScheduleExactAlarms()
        // Without exact alarm permission on Android 12+, setAndAllowWhileIdle is
        // throttled by Doze to ~9 minutes anyway; match that cadence to avoid churn.
        val interval = if (activePlayback && canExact) activeIntervalMs else intervalMs
        val now = SystemClock.elapsedRealtime()
        val triggerAtMs = now + interval
        val pendingDeadline = pendingDeadlineMs
        // Replacing the same PendingIntent also cancels its existing alarm.
        // Keep a still-future earlier deadline, but never let a missed/overdue
        // deadline block re-arming.
        if (pendingDeadline != null && pendingDeadline > now && pendingDeadline <= triggerAtMs) {
            return
        }
        val operation = pendingIntent(context) ?: return
        try {
            scheduleAlarmCompat(alarmManager, triggerAtMs, operation, canExact)
            pendingDeadlineMs = triggerAtMs
        } catch (_: Exception) {
        }
    }

    internal fun onAlarmDelivered() {
        pendingDeadlineMs = null
    }

    private fun scheduleAlarmCompat(
        alarmManager: AlarmManager,
        triggerAtMs: Long,
        operation: PendingIntent,
        canExact: Boolean
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (canExact) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    triggerAtMs,
                    operation
                )
            } else {
                // set() is completely suppressed during Doze; setAndAllowWhileIdle()
                // does not require SCHEDULE_EXACT_ALARM and still wakes from Doze.
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
        pendingDeadlineMs = null
        val alarmManager = alarmManager(context) ?: return
        val operation = pendingIntent(context) ?: return
        try {
            alarmManager.cancel(operation)
        } catch (_: Exception) {
        }
    }

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
