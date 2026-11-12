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
        val interval = if (activePlayback) activeIntervalMs else intervalMs
        val triggerAtMs = SystemClock.elapsedRealtime() + interval
        val pendingDeadline = pendingDeadlineMs
        // Replacing the same PendingIntent also cancels its existing alarm.
        // Keep an earlier deadline even if Android has delayed its delivery.
        if (pendingDeadline != null && pendingDeadline <= triggerAtMs) return
        val alarmManager = alarmManager(context) ?: return
        val operation = pendingIntent(context) ?: return
        try {
            scheduleAlarmCompat(alarmManager, triggerAtMs, operation)
            pendingDeadlineMs = triggerAtMs
        } catch (_: Exception) {
        }
    }

    internal fun onAlarmDelivered() {
        val pendingDeadline = pendingDeadlineMs ?: return
        // A broadcast already queued before cancellation can arrive after rearming.
        if (pendingDeadline <= SystemClock.elapsedRealtime()) pendingDeadlineMs = null
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
                // Leave the inexact Doze alarm allowance to the playback timer.
                alarmManager.set(
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
