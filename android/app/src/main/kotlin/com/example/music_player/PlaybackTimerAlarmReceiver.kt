package com.example.music_player

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat

class PlaybackTimerAlarmReceiver : BroadcastReceiver() {
    companion object {
        private const val maxServiceDeliveryAttempts = 8
        private const val serviceDeliveryRetryDelayMs = 160L
        private val mainHandler = Handler(Looper.getMainLooper())
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        val pendingResult = goAsync()
        val appContext = context.applicationContext

        PlaybackTimerAlarmScheduler.promoteKeepAliveService(appContext, action)
        deliverToService(
            context = appContext,
            action = action,
            attempt = 0,
            pendingResult = pendingResult
        )
    }

    private fun deliverToService(
        context: Context,
        action: String,
        attempt: Int,
        pendingResult: PendingResult
    ) {
        val service = NativePlaybackService.ensureStarted(context)
        if (service == null) {
            if (attempt >= maxServiceDeliveryAttempts) {
                pendingResult.finish()
                return
            }
            mainHandler.postDelayed(
                {
                    deliverToService(
                        context = context,
                        action = action,
                        attempt = attempt + 1,
                        pendingResult = pendingResult
                    )
                },
                serviceDeliveryRetryDelayMs
            )
            return
        }

        try {
            when (action) {
                PlaybackTimerAlarmScheduler.actionTimerExpired -> {
                    val pausedSessionIds = service.pausePlayingSessionsForTimer()
                        .ifEmpty {
                            NativePlaybackStateStore.loadSessions(context)
                                .filter { it.playing || it.playWhenReady }
                                .map { it.sessionId }
                        }
                        .ifEmpty {
                            NativePlaybackStateStore.loadTimerCandidateSessionIds(context)
                        }
                    NativePlaybackStateStore.storePausedSessionIds(
                        context,
                        pausedSessionIds
                    )
                }
                PlaybackTimerAlarmScheduler.actionAutoResume -> {
                    val pausedSessionIds =
                        NativePlaybackStateStore.loadPausedSessionIds(context)
                            .ifEmpty {
                                NativePlaybackStateStore.loadTimerCandidateSessionIds(context)
                            }
                    if (pausedSessionIds.isNotEmpty()) {
                        service.resumeSessionsForTimer(pausedSessionIds)
                    }
                    NativePlaybackStateStore.clearPausedSessionIds(context)
                    NativePlaybackStateStore.clearTimerCandidateSessionIds(context)
                }
            }
        } finally {
            pendingResult.finish()
        }
    }
}

object PlaybackTimerAlarmScheduler {
    const val actionTimerExpired = "com.example.music_player.action.TIMER_EXPIRED"
    const val actionAutoResume = "com.example.music_player.action.AUTO_RESUME"

    private const val timerRequestCode = 32001
    private const val autoResumeRequestCode = 32002

    fun sync(
        context: Context,
        timerEndsAtMs: Long?,
        autoResumeAtMs: Long?
    ) {
        if (timerEndsAtMs != null) {
            val timerCandidateSessionIds = NativePlaybackStateStore.loadSessions(context)
                .filter { it.playing || it.playWhenReady }
                .map { it.sessionId }
            NativePlaybackStateStore.storeTimerCandidateSessionIds(
                context,
                timerCandidateSessionIds
            )
            scheduleAlarm(context, actionTimerExpired, timerRequestCode, timerEndsAtMs)
        } else {
            cancelAlarm(context, actionTimerExpired, timerRequestCode)
            if (autoResumeAtMs == null) {
                NativePlaybackStateStore.clearTimerCandidateSessionIds(context)
            }
        }

        if (autoResumeAtMs != null) {
            scheduleAlarm(context, actionAutoResume, autoResumeRequestCode, autoResumeAtMs)
        } else {
            cancelAlarm(context, actionAutoResume, autoResumeRequestCode)
            NativePlaybackStateStore.clearPausedSessionIds(context)
            NativePlaybackStateStore.clearTimerCandidateSessionIds(context)
        }
    }

    fun promoteKeepAliveService(context: Context, action: String) {
        val serviceIntent = Intent(context, PlaybackKeepAliveService::class.java).apply {
            this.action = PlaybackKeepAliveService.ACTION_START
            putExtra(
                PlaybackKeepAliveService.EXTRA_HAS_ACTIVE_PLAYBACK,
                action == actionAutoResume
            )
            putExtra(PlaybackKeepAliveService.EXTRA_HAS_ACTIVE_TIMER, true)
            putExtra(
                PlaybackKeepAliveService.EXTRA_USES_UNIFIED_PLAYBACK_NOTIFICATION,
                UnifiedPlaybackNotificationController.activeNotificationCount > 0
            )
            putExtra(
                PlaybackKeepAliveService.EXTRA_KEEP_FOREGROUND_SERVICE_ALIVE,
                true
            )
        }
        try {
            ContextCompat.startForegroundService(context, serviceIntent)
        } catch (_: Exception) {
            // Best effort only. Native playback still attempts to continue.
        }
    }

    private fun scheduleAlarm(
        context: Context,
        action: String,
        requestCode: Int,
        triggerAtMs: Long
    ) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            ?: return
        val pendingIntent = pendingIntent(
            context = context,
            action = action,
            requestCode = requestCode,
            flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val safeTriggerAtMs = triggerAtMs.coerceAtLeast(System.currentTimeMillis() + 250L)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                alarmManager.canScheduleExactAlarms()
            ) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    safeTriggerAtMs,
                    pendingIntent
                )
            } else {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    safeTriggerAtMs,
                    pendingIntent
                )
            }
        } else {
            alarmManager.setExact(
                AlarmManager.RTC_WAKEUP,
                safeTriggerAtMs,
                pendingIntent
            )
        }
    }

    private fun cancelAlarm(
        context: Context,
        action: String,
        requestCode: Int
    ) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            ?: return
        val pendingIntent = pendingIntent(
            context = context,
            action = action,
            requestCode = requestCode,
            flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        alarmManager.cancel(pendingIntent)
        pendingIntent.cancel()
    }

    private fun pendingIntent(
        context: Context,
        action: String,
        requestCode: Int,
        flags: Int
    ): PendingIntent {
        val intent = Intent(context, PlaybackTimerAlarmReceiver::class.java).apply {
            this.action = action
            `package` = context.packageName
        }
        return PendingIntent.getBroadcast(context, requestCode, intent, flags)
    }
}
