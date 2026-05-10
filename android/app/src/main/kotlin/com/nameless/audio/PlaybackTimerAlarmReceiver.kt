package com.nameless.audio

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
        val deliveredGeneration = intent.getIntExtra("generation", Int.MIN_VALUE)
        val pendingResult = goAsync()
        val appContext = context.applicationContext
        val runtimeState = NativePlaybackStateStore.loadTimerRuntimeState(appContext)

        if (runtimeState != null &&
            deliveredGeneration != Int.MIN_VALUE &&
            runtimeState.generation != deliveredGeneration
        ) {
            pendingResult.finish()
            return
        }

        PlaybackTimerAlarmScheduler.promoteKeepAliveService(appContext, action)
        deliverToService(
            context = appContext,
            action = action,
            runtimeState = runtimeState,
            attempt = 0,
            pendingResult = pendingResult
        )
    }

    private fun deliverToService(
        context: Context,
        action: String,
        runtimeState: StoredPlaybackTimerRuntimeState?,
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
                        runtimeState = runtimeState,
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
                    val nextState = runtimeState?.copy(
                        waitingForPlayback = false,
                        timerEndsAtMs = null,
                        pausedSessionIds = pausedSessionIds
                    ) ?: StoredPlaybackTimerRuntimeState(
                        timerModeIndex = null,
                        durationMs = null,
                        waitingForPlayback = false,
                        timerEndsAtMs = null,
                        autoResumeAtMs = null,
                        pausedSessionIds = pausedSessionIds,
                        generation = 0
                    )
                    if (nextState.hasRuntime) {
                        NativePlaybackStateStore.saveTimerRuntimeState(context, nextState)
                    } else {
                        NativePlaybackStateStore.clearTimerRuntimeState(context)
                    }
                    PlaybackTimerAlarmScheduler.rescheduleFromStoredState(context)
                }
                PlaybackTimerAlarmScheduler.actionAutoResume -> {
                    val pausedSessionIds = runtimeState?.pausedSessionIds
                        ?.ifEmpty {
                            NativePlaybackStateStore.loadPausedSessionIds(context)
                        }
                        ?.ifEmpty {
                            NativePlaybackStateStore.loadTimerCandidateSessionIds(context)
                        }
                        ?: NativePlaybackStateStore.loadPausedSessionIds(context)
                            .ifEmpty {
                                NativePlaybackStateStore.loadTimerCandidateSessionIds(context)
                            }
                    if (pausedSessionIds.isNotEmpty()) {
                        service.resumeSessionsForTimer(pausedSessionIds)
                    }
                    NativePlaybackStateStore.clearPausedSessionIds(context)
                    NativePlaybackStateStore.clearTimerCandidateSessionIds(context)
                    NativePlaybackStateStore.clearTimerRuntimeState(context)
                    PlaybackTimerAlarmScheduler.rescheduleFromStoredState(context)
                }
            }
        } finally {
            pendingResult.finish()
        }
    }
}

object PlaybackTimerAlarmScheduler {
    const val actionTimerExpired = "com.nameless.audio.action.TIMER_EXPIRED"
    const val actionAutoResume = "com.nameless.audio.action.AUTO_RESUME"

    private const val timerRequestCode = 32001
    private const val autoResumeRequestCode = 32002
    private const val extraGeneration = "generation"

    fun sync(
        context: Context,
        timerModeIndex: Int?,
        durationMs: Long?,
        waitingForPlayback: Boolean,
        timerEndsAtMs: Long?,
        autoResumeAtMs: Long?,
        pausedSessionIds: List<String>,
        generation: Int
    ) {
        val runtimeState = StoredPlaybackTimerRuntimeState(
            timerModeIndex = timerModeIndex,
            durationMs = durationMs,
            waitingForPlayback = waitingForPlayback,
            timerEndsAtMs = timerEndsAtMs,
            autoResumeAtMs = autoResumeAtMs,
            pausedSessionIds = pausedSessionIds,
            generation = generation
        )
        if (runtimeState.hasRuntime) {
            NativePlaybackStateStore.saveTimerRuntimeState(context, runtimeState)
        } else {
            NativePlaybackStateStore.clearTimerRuntimeState(context)
        }

        if (timerEndsAtMs != null) {
            val timerCandidateSessionIds = NativePlaybackStateStore.loadSessions(context)
                .filter { it.playing || it.playWhenReady }
                .map { it.sessionId }
            NativePlaybackStateStore.storeTimerCandidateSessionIds(
                context,
                timerCandidateSessionIds
            )
            scheduleAlarm(
                context,
                actionTimerExpired,
                timerRequestCode,
                timerEndsAtMs,
                generation
            )
        } else {
            cancelAlarm(context, actionTimerExpired, timerRequestCode)
            if (autoResumeAtMs == null) {
                NativePlaybackStateStore.clearTimerCandidateSessionIds(context)
            }
        }

        if (autoResumeAtMs != null) {
            scheduleAlarm(
                context,
                actionAutoResume,
                autoResumeRequestCode,
                autoResumeAtMs,
                generation
            )
        } else {
            cancelAlarm(context, actionAutoResume, autoResumeRequestCode)
            NativePlaybackStateStore.clearPausedSessionIds(context)
            if (timerEndsAtMs == null) {
                NativePlaybackStateStore.clearTimerCandidateSessionIds(context)
            }
        }
        syncKeepAliveService(context, runtimeState)
    }

    fun rescheduleFromStoredState(context: Context) {
        val runtimeState = NativePlaybackStateStore.loadTimerRuntimeState(context)
        if (runtimeState == null || !runtimeState.hasRuntime) {
            cancelAlarm(context, actionTimerExpired, timerRequestCode)
            cancelAlarm(context, actionAutoResume, autoResumeRequestCode)
            NativePlaybackStateStore.clearTimerRuntimeState(context)
            syncKeepAliveService(context, null)
            return
        }
        if (runtimeState.timerEndsAtMs != null) {
            scheduleAlarm(
                context,
                actionTimerExpired,
                timerRequestCode,
                runtimeState.timerEndsAtMs,
                runtimeState.generation
            )
        } else {
            cancelAlarm(context, actionTimerExpired, timerRequestCode)
        }
        if (runtimeState.autoResumeAtMs != null) {
            scheduleAlarm(
                context,
                actionAutoResume,
                autoResumeRequestCode,
                runtimeState.autoResumeAtMs,
                runtimeState.generation
            )
        } else {
            cancelAlarm(context, actionAutoResume, autoResumeRequestCode)
        }
        syncKeepAliveService(context, runtimeState)
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
        triggerAtMs: Long,
        generation: Int
    ) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            ?: return
        val pendingIntent = pendingIntent(
            context = context,
            action = action,
            requestCode = requestCode,
            generation = generation,
            flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val safeTriggerAtMs = triggerAtMs.coerceAtLeast(System.currentTimeMillis() + 250L)

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                !alarmManager.canScheduleExactAlarms()
            ) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    alarmManager.setAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        safeTriggerAtMs,
                        pendingIntent
                    )
                } else {
                    alarmManager.set(
                        AlarmManager.RTC_WAKEUP,
                        safeTriggerAtMs,
                        pendingIntent
                    )
                }
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    safeTriggerAtMs,
                    pendingIntent
                )
            } else {
                alarmManager.setExact(
                    AlarmManager.RTC_WAKEUP,
                    safeTriggerAtMs,
                    pendingIntent
                )
            }
        } catch (_: SecurityException) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    safeTriggerAtMs,
                    pendingIntent
                )
            } else {
                alarmManager.set(
                    AlarmManager.RTC_WAKEUP,
                    safeTriggerAtMs,
                    pendingIntent
                )
            }
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
        generation: Int = 0,
        flags: Int
    ): PendingIntent {
        val intent = Intent(context, PlaybackTimerAlarmReceiver::class.java).apply {
            this.action = action
            `package` = context.packageName
            putExtra(extraGeneration, generation)
        }
        return PendingIntent.getBroadcast(context, requestCode, intent, flags)
    }

    private fun syncKeepAliveService(
        context: Context,
        runtimeState: StoredPlaybackTimerRuntimeState?
    ) {
        val shouldKeepAlive = runtimeState?.shouldKeepForegroundServiceAlive == true
        val serviceIntent = Intent(context, PlaybackKeepAliveService::class.java).apply {
            action = if (shouldKeepAlive) {
                PlaybackKeepAliveService.ACTION_START
            } else {
                PlaybackKeepAliveService.ACTION_STOP
            }
            putExtra(PlaybackKeepAliveService.EXTRA_HAS_ACTIVE_PLAYBACK, false)
            putExtra(
                PlaybackKeepAliveService.EXTRA_HAS_ACTIVE_TIMER,
                runtimeState?.shouldKeepForegroundServiceAlive == true
            )
            putExtra(
                PlaybackKeepAliveService.EXTRA_USES_UNIFIED_PLAYBACK_NOTIFICATION,
                UnifiedPlaybackNotificationController.activeNotificationCount > 0
            )
            putExtra(
                PlaybackKeepAliveService.EXTRA_KEEP_FOREGROUND_SERVICE_ALIVE,
                shouldKeepAlive
            )
        }
        try {
            if (shouldKeepAlive) {
                ContextCompat.startForegroundService(context, serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } catch (_: Exception) {
            if (!shouldKeepAlive) {
                context.stopService(Intent(context, PlaybackKeepAliveService::class.java))
            }
        }
    }
}
