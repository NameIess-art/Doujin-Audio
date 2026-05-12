package com.nameless.audio

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.content.ContextCompat
import java.util.Calendar

class PlaybackTimerAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        val generation = intent.getIntExtra(
            PlaybackTimerAlarmScheduler.extraGeneration,
            Int.MIN_VALUE
        ).takeIf { it != Int.MIN_VALUE }
        PlaybackTimerAlarmScheduler.executeNow(
            context = context.applicationContext,
            action = action,
            generation = generation,
            pendingResult = goAsync()
        )
    }
}

object PlaybackTimerAlarmScheduler {
    const val actionTimerExpired = "com.nameless.audio.action.TIMER_EXPIRED"
    const val actionAutoResume = "com.nameless.audio.action.AUTO_RESUME"
    const val extraGeneration = "generation"
    private const val actionTimeSet = "android.intent.action.TIME_SET"

    private const val timerRequestCode = 32001
    private const val autoResumeRequestCode = 32002
    private const val maxServiceDeliveryAttempts = 8
    private const val serviceDeliveryRetryDelayMs = 160L
    private val mainHandler = Handler(Looper.getMainLooper())

    fun sync(
        context: Context,
        timerModeIndex: Int?,
        durationMs: Long?,
        waitingForPlayback: Boolean,
        timerEndsAtWallClockMs: Long?,
        autoResumeEnabled: Boolean,
        autoResumeHour: Int,
        autoResumeMinute: Int,
        autoResumeAtMs: Long?,
        pausedSessionIds: List<String>,
        generation: Int
    ) {
        val runtimeState = StoredPlaybackTimerRuntimeState(
            timerModeIndex = timerModeIndex,
            durationMs = durationMs,
            waitingForPlayback = waitingForPlayback,
            timerEndsAtWallClockMs = timerEndsAtWallClockMs,
            timerEndsElapsedRealtimeMs = timerEndsAtWallClockMs?.let(::elapsedTriggerFromWallClock),
            autoResumeEnabled = autoResumeEnabled,
            autoResumeHour = autoResumeHour,
            autoResumeMinute = autoResumeMinute,
            autoResumeAtMs = autoResumeAtMs,
            pausedSessionIds = pausedSessionIds,
            generation = generation
        )
        if (runtimeState.hasRuntime) {
            NativePlaybackStateStore.saveTimerRuntimeState(context, runtimeState)
        } else {
            NativePlaybackStateStore.clearTimerRuntimeState(context)
        }

        if (timerEndsAtWallClockMs != null) {
            val timerCandidateSessionIds = NativePlaybackStateStore.loadSessions(context)
                .filter { it.playing || it.playWhenReady }
                .map { it.sessionId }
            NativePlaybackStateStore.storeTimerCandidateSessionIds(
                context,
                timerCandidateSessionIds
            )
            scheduleElapsedAlarm(
                context = context,
                action = actionTimerExpired,
                requestCode = timerRequestCode,
                triggerElapsedRealtimeMs = runtimeState.timerEndsElapsedRealtimeMs
                    ?: elapsedTriggerFromWallClock(timerEndsAtWallClockMs),
                generation = generation
            )
        } else {
            cancelAlarm(context, actionTimerExpired, timerRequestCode)
            if (autoResumeAtMs == null) {
                NativePlaybackStateStore.clearTimerCandidateSessionIds(context)
            }
        }

        if (autoResumeAtMs != null) {
            scheduleRtcAlarm(
                context = context,
                action = actionAutoResume,
                requestCode = autoResumeRequestCode,
                triggerAtWallClockMs = autoResumeAtMs,
                generation = generation
            )
        } else {
            cancelAlarm(context, actionAutoResume, autoResumeRequestCode)
        }
        syncKeepAliveService(context, runtimeState)
    }

    fun rescheduleFromStoredState(
        context: Context,
        reasonAction: String? = null
    ) {
        var runtimeState = NativePlaybackStateStore.loadTimerRuntimeState(context)
        if (runtimeState == null || !runtimeState.hasRuntime) {
            cancelAlarm(context, actionTimerExpired, timerRequestCode)
            cancelAlarm(context, actionAutoResume, autoResumeRequestCode)
            NativePlaybackStateStore.clearTimerRuntimeState(context)
            syncKeepAliveService(context, null)
            return
        }

        if (runtimeState.autoResumeEnabled && runtimeState.pausedSessionIds.isNotEmpty()) {
            val shouldRecalculateAutoResume = reasonAction == Intent.ACTION_BOOT_COMPLETED ||
                reasonAction == Intent.ACTION_MY_PACKAGE_REPLACED ||
                reasonAction == actionTimeSet ||
                reasonAction == Intent.ACTION_TIMEZONE_CHANGED
            if (shouldRecalculateAutoResume) {
                val nextAutoResumeAtMs = nextClockTimeMillis(
                    nowWallClockMs = System.currentTimeMillis(),
                    hour = runtimeState.autoResumeHour,
                    minute = runtimeState.autoResumeMinute
                )
                if (runtimeState.autoResumeAtMs != nextAutoResumeAtMs) {
                    runtimeState = runtimeState.copy(autoResumeAtMs = nextAutoResumeAtMs)
                    NativePlaybackStateStore.saveTimerRuntimeState(context, runtimeState)
                }
            }
        }

        if (runtimeState.timerEndsAtWallClockMs != null) {
            val triggerElapsedRealtimeMs = when (reasonAction) {
                Intent.ACTION_BOOT_COMPLETED,
                Intent.ACTION_MY_PACKAGE_REPLACED -> {
                    elapsedTriggerFromWallClock(runtimeState.timerEndsAtWallClockMs)
                }
                else -> {
                    runtimeState.timerEndsElapsedRealtimeMs
                        ?: elapsedTriggerFromWallClock(runtimeState.timerEndsAtWallClockMs)
                }
            }
            scheduleElapsedAlarm(
                context = context,
                action = actionTimerExpired,
                requestCode = timerRequestCode,
                triggerElapsedRealtimeMs = triggerElapsedRealtimeMs,
                generation = runtimeState.generation
            )
        } else {
            cancelAlarm(context, actionTimerExpired, timerRequestCode)
        }

        if (runtimeState.autoResumeAtMs != null) {
            scheduleRtcAlarm(
                context = context,
                action = actionAutoResume,
                requestCode = autoResumeRequestCode,
                triggerAtWallClockMs = runtimeState.autoResumeAtMs,
                generation = runtimeState.generation
            )
        } else {
            cancelAlarm(context, actionAutoResume, autoResumeRequestCode)
        }
        syncKeepAliveService(context, runtimeState)
    }

    fun executeNow(
        context: Context,
        action: String,
        generation: Int?,
        pendingResult: BroadcastReceiver.PendingResult? = null
    ) {
        val runtimeState = NativePlaybackStateStore.loadTimerRuntimeState(context)
        if (runtimeState != null &&
            generation != null &&
            runtimeState.generation != generation
        ) {
            pendingResult?.finish()
            return
        }
        promoteKeepAliveService(context, action)
        deliverToService(
            context = context,
            action = action,
            runtimeState = runtimeState,
            attempt = 0,
            pendingResult = pendingResult
        )
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
                UnifiedPlaybackNotificationController.hasUnifiedNotifications()
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

    private fun deliverToService(
        context: Context,
        action: String,
        runtimeState: StoredPlaybackTimerRuntimeState?,
        attempt: Int,
        pendingResult: BroadcastReceiver.PendingResult?
    ) {
        val service = NativePlaybackService.ensureStarted(
            context,
            requireForegroundBootstrap = true
        )
        if (service == null) {
            if (attempt >= maxServiceDeliveryAttempts) {
                pendingResult?.finish()
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
                actionTimerExpired -> executeTimerExpired(context, service, runtimeState)
                actionAutoResume -> executeAutoResume(context, service, runtimeState)
            }
        } finally {
            pendingResult?.finish()
        }
    }

    private fun executeTimerExpired(
        context: Context,
        service: NativePlaybackService,
        runtimeState: StoredPlaybackTimerRuntimeState?
    ) {
        val pausedSessionIds = service.pausePlayingSessionsForTimer()
            .ifEmpty {
                NativePlaybackStateStore.loadSessions(context)
                    .filter { it.playing || it.playWhenReady }
                    .map { it.sessionId }
            }
            .ifEmpty {
                NativePlaybackStateStore.loadTimerCandidateSessionIds(context)
            }
        NativePlaybackStateStore.storePausedSessionIds(context, pausedSessionIds)
        val nextAutoResumeAtMs = if ((runtimeState?.autoResumeEnabled == true) &&
            pausedSessionIds.isNotEmpty()
        ) {
            nextClockTimeMillis(
                nowWallClockMs = System.currentTimeMillis(),
                hour = runtimeState.autoResumeHour,
                minute = runtimeState.autoResumeMinute
            )
        } else {
            null
        }
        val nextState = runtimeState?.copy(
            waitingForPlayback = false,
            timerEndsAtWallClockMs = null,
            timerEndsElapsedRealtimeMs = null,
            autoResumeAtMs = nextAutoResumeAtMs,
            pausedSessionIds = pausedSessionIds
        ) ?: StoredPlaybackTimerRuntimeState(
            timerModeIndex = null,
            durationMs = null,
            waitingForPlayback = false,
            timerEndsAtWallClockMs = null,
            timerEndsElapsedRealtimeMs = null,
            autoResumeEnabled = false,
            autoResumeHour = 7,
            autoResumeMinute = 0,
            autoResumeAtMs = null,
            pausedSessionIds = pausedSessionIds,
            generation = 0
        )
        if (nextState.hasRuntime) {
            NativePlaybackStateStore.saveTimerRuntimeState(context, nextState)
        } else {
            NativePlaybackStateStore.clearTimerRuntimeState(context)
        }
        rescheduleFromStoredState(context)
    }

    private fun executeAutoResume(
        context: Context,
        service: NativePlaybackService,
        runtimeState: StoredPlaybackTimerRuntimeState?
    ) {
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
        rescheduleFromStoredState(context)
    }

    private fun scheduleElapsedAlarm(
        context: Context,
        action: String,
        requestCode: Int,
        triggerElapsedRealtimeMs: Long,
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
        val safeTriggerAtMs = triggerElapsedRealtimeMs.coerceAtLeast(
            SystemClock.elapsedRealtime() + 250L
        )

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                !alarmManager.canScheduleExactAlarms()
            ) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    alarmManager.setAndAllowWhileIdle(
                        AlarmManager.ELAPSED_REALTIME_WAKEUP,
                        safeTriggerAtMs,
                        pendingIntent
                    )
                } else {
                    alarmManager.set(
                        AlarmManager.ELAPSED_REALTIME_WAKEUP,
                        safeTriggerAtMs,
                        pendingIntent
                    )
                }
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    safeTriggerAtMs,
                    pendingIntent
                )
            } else {
                alarmManager.setExact(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    safeTriggerAtMs,
                    pendingIntent
                )
            }
        } catch (_: SecurityException) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    safeTriggerAtMs,
                    pendingIntent
                )
            } else {
                alarmManager.set(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    safeTriggerAtMs,
                    pendingIntent
                )
            }
        }
    }

    private fun scheduleRtcAlarm(
        context: Context,
        action: String,
        requestCode: Int,
        triggerAtWallClockMs: Long,
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
        val safeTriggerAtMs = triggerAtWallClockMs.coerceAtLeast(System.currentTimeMillis() + 250L)

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
                UnifiedPlaybackNotificationController.hasUnifiedNotifications()
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

    private fun elapsedTriggerFromWallClock(triggerAtWallClockMs: Long): Long {
        val delayMs = (triggerAtWallClockMs - System.currentTimeMillis()).coerceAtLeast(0L)
        return SystemClock.elapsedRealtime() + delayMs
    }

    private fun nextClockTimeMillis(
        nowWallClockMs: Long,
        hour: Int,
        minute: Int
    ): Long {
        val calendar = Calendar.getInstance().apply {
            timeInMillis = nowWallClockMs
            set(Calendar.HOUR_OF_DAY, hour)
            set(Calendar.MINUTE, minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            if (timeInMillis <= nowWallClockMs) {
                add(Calendar.DAY_OF_YEAR, 1)
            }
        }
        return calendar.timeInMillis
    }
}
