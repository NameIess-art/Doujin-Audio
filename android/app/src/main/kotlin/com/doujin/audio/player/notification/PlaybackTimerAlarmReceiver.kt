package com.doujin.audio.player.notification

import com.doujin.audio.common.*
import com.doujin.audio.player.service.*
import com.doujin.audio.player.session.*

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import java.util.Calendar

class PlaybackTimerAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (!isPlaybackTimerAlarmAction(action)) return
        PlaybackTimerAlarmScheduler.logInfo(
            context,
            "receiver_on_receive action=$action"
        )
        val generation = intent.getIntExtra(
            PlaybackTimerAlarmScheduler.extraGeneration,
            Int.MIN_VALUE
        ).takeIf { it != Int.MIN_VALUE }
        val autoResumeAttempt = intent.getIntExtra(
            PlaybackTimerAlarmScheduler.extraAutoResumeAttempt,
            0
        ).coerceAtLeast(0)
        PlaybackTimerAlarmScheduler.executeNow(
            context = context.applicationContext,
            action = action,
            generation = generation,
            autoResumeAttempt = autoResumeAttempt,
            pendingResult = goAsync(),
            deliveryWakeLock = PlaybackTimerAlarmScheduler.acquireDeliveryWakeLock(context)
        )
    }
}

object PlaybackTimerAlarmScheduler {
    const val actionTimerExpired = PlaybackTimerAlarmProtocol.actionTimerExpired
    const val actionAutoResume = PlaybackTimerAlarmProtocol.actionAutoResume
    const val extraGeneration = PlaybackTimerAlarmProtocol.extraGeneration
    const val extraAutoResumeAttempt = PlaybackTimerAlarmProtocol.extraAutoResumeAttempt
    const val resultExecuted = PlaybackTimerAlarmProtocol.resultExecuted
    const val resultStale = PlaybackTimerAlarmProtocol.resultStale
    const val resultFailed = PlaybackTimerAlarmProtocol.resultFailed

    private const val logTag = "PlaybackTimerAlarm"
    private const val timerRequestCode = 32001
    private const val autoResumeRequestCode = 32002
    private const val autoResumeRetryDelayMs = 30_000L

    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    private fun commandDelivery(context: Context) = PlaybackTimerCommandDelivery(
            startService = {
                NativePlaybackService.ensureStarted(context, requireForegroundBootstrap = true)?.let { service ->
                    { action, runtime, generation, attempt, complete ->
                        when (action) {
                            actionTimerExpired -> {
                                executeTimerExpired(context, service, runtime)
                                complete(resultExecuted)
                            }
                            actionAutoResume -> {
                                executeAutoResume(context, service, runtime, generation, attempt, complete)
                            }
                            else -> complete(resultFailed)
                        }
                    }
                }
            },
            loadRuntimeState = { NativePlaybackStateStore.loadTimerRuntimeState(context) },
            postDelayed = { task, delay -> mainHandler.postDelayed(task, delay) },
            beginCommandDelivery = NativePlaybackService::beginCommandDelivery,
            endCommandDelivery = NativePlaybackService::endCommandDelivery,
            logInfo = { logInfo(context, it) },
            logWarn = { message, error -> logWarn(context, message, error) }
        )

    fun acquireDeliveryWakeLock(context: Context): PowerManager.WakeLock? = try {
        val manager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        manager?.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "${context.packageName}:playback_timer_delivery"
        )?.apply {
            setReferenceCounted(false)
            acquire(15_000L)
        }
    } catch (_: Exception) {
        null
    }

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
        generation: Int,
        timerCandidateSessionIds: List<String>
    ) {
        if (timerEndsAtWallClockMs != null || pausedSessionIds.isEmpty()) {
            NativePlaybackService.controller()?.cancelTimerStopAfterCurrentTrack()
        }
        logInfo(
            context,
            "sync timerMode=$timerModeIndex durationMs=$durationMs " +
                "waiting=$waitingForPlayback timerEndsAt=$timerEndsAtWallClockMs " +
                "autoResumeEnabled=$autoResumeEnabled autoResumeAt=$autoResumeAtMs " +
                "pausedSessionCount=${pausedSessionIds.size} generation=$generation"
        )
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
            return
        }

        if (runtimeState.autoResumeEnabled &&
            runtimeState.pausedSessionIds.isNotEmpty() &&
            runtimeState.autoResumeAtMs != null
        ) {
            val shouldRecalculateAutoResume =
                shouldRecalculateAutoResumeAfterSystemEvent(reasonAction)
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
    }

    fun executeNow(
        context: Context,
        action: String,
        generation: Int?,
        autoResumeAttempt: Int = 0,
        pendingResult: BroadcastReceiver.PendingResult? = null,
        deliveryWakeLock: PowerManager.WakeLock? = null,
        onComplete: ((String) -> Unit)? = null
    ) = commandDelivery(context).executeNow(action, generation, autoResumeAttempt) { outcome ->
        try {
            pendingResult?.finish()
        } finally {
            try {
                if (deliveryWakeLock?.isHeld == true) deliveryWakeLock.release()
            } catch (_: RuntimeException) {
            } finally {
                onComplete?.invoke(outcome)
            }
        }
    }

    fun completeTimerStopAfterCurrentTracks(context: Context, generation: Int?) {
        val runtimeState = NativePlaybackStateStore.loadTimerRuntimeState(context) ?: return
        if (generation != null && runtimeState.generation != generation) return
        val pausedSessionIds = runtimeState.pausedSessionIds
        if (runtimeState.autoResumeEnabled && pausedSessionIds.isNotEmpty()) {
            val nextState = runtimeState.copy(
                autoResumeAtMs = nextClockTimeMillis(
                    nowWallClockMs = System.currentTimeMillis(),
                    hour = runtimeState.autoResumeHour,
                    minute = runtimeState.autoResumeMinute
                )
            )
            NativePlaybackStateStore.saveTimerRuntimeState(context, nextState)
        } else {
            NativePlaybackStateStore.clearTimerRuntimeState(context)
            NativePlaybackStateStore.clearPausedSessionIds(context)
            NativePlaybackStateStore.clearTimerCandidateSessionIds(context)
        }
        rescheduleFromStoredState(context)
    }

    private fun executeTimerExpired(
        context: Context,
        service: NativePlaybackService,
        runtimeState: StoredPlaybackTimerRuntimeState?
    ) {
        val timerStopSessionIds = service.stopPlayingSessionsAfterCurrentTrackForTimer(
            runtimeState?.generation ?: 0
        )
        val pausedSessionIds = timerStopSessionIds
            .ifEmpty {
                NativePlaybackStateStore.loadSessions(context)
                    .filter { it.playing || it.playWhenReady }
                    .map { it.sessionId }
            }
            .ifEmpty {
                NativePlaybackStateStore.loadTimerCandidateSessionIds(context)
            }
        NativePlaybackStateStore.storePausedSessionIds(context, pausedSessionIds)
        logInfo(
            context,
            "timer_expired pausedSessionCount=${pausedSessionIds.size} " +
                "autoResumeEnabled=${runtimeState?.autoResumeEnabled == true}"
        )
        // The target sessions are still playing their current items. Schedule
        // automatic resume only after each one has paused at its item boundary.
        val nextAutoResumeAtMs: Long? = null
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
        if (timerStopSessionIds.isEmpty()) {
            completeTimerStopAfterCurrentTracks(context, runtimeState?.generation)
        }
    }

    private fun executeAutoResume(
        context: Context,
        service: NativePlaybackService,
        runtimeState: StoredPlaybackTimerRuntimeState?,
        generation: Int?,
        autoResumeAttempt: Int,
        complete: (String) -> Unit
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
        service.restoreSessionsForTimer(pausedSessionIds) { restored ->
            try {
                val currentState = NativePlaybackStateStore.loadTimerRuntimeState(context)
                if (restored.getOrThrow() && currentState?.generation == runtimeState?.generation) {
                    finishAutoResume(context, service, runtimeState, generation, autoResumeAttempt, pausedSessionIds)
                    complete(resultExecuted)
                } else {
                    complete(resultStale)
                }
            } catch (error: Throwable) {
                logWarn(context, "auto_resume_failed", error)
                complete(resultFailed)
            }
        }
    }

    private fun finishAutoResume(
        context: Context,
        service: NativePlaybackService,
        runtimeState: StoredPlaybackTimerRuntimeState?,
        generation: Int?,
        autoResumeAttempt: Int,
        pausedSessionIds: List<String>
    ) {
        if (pausedSessionIds.isNotEmpty()) {
            val resumeResult = service.resumeSessionsForTimer(pausedSessionIds)
            val resumedSessionIds = resumeResult.resumedSessionIds
            logInfo(
                context,
                "auto_resume requestedSessionCount=${pausedSessionIds.size} " +
                    "resumedSessionCount=${resumedSessionIds.size}"
            )
            if (resumeResult.audioFocusDenied) {
                val nextAttempt = nextPlaybackTimerAutoResumeAttempt(autoResumeAttempt)
                if (nextAttempt != null) {
                    val retryAtMs = System.currentTimeMillis() + autoResumeRetryDelayMs
                    NativePlaybackStateStore.storePausedSessionIds(context, pausedSessionIds)
                    runtimeState?.copy(
                        autoResumeAtMs = retryAtMs,
                        pausedSessionIds = pausedSessionIds
                    )?.let { NativePlaybackStateStore.saveTimerRuntimeState(context, it) }
                    scheduleRtcAlarm(
                        context = context,
                        action = actionAutoResume,
                        requestCode = autoResumeRequestCode,
                        triggerAtWallClockMs = retryAtMs,
                        generation = runtimeState?.generation ?: generation ?: 0,
                        autoResumeAttempt = nextAttempt
                    )
                    logInfo(
                        context,
                        "auto_resume_focus_retry_scheduled attempt=$nextAttempt " +
                            "delayMs=$autoResumeRetryDelayMs"
                    )
                    return
                }

                NativePlaybackStateStore.storePausedSessionIds(context, pausedSessionIds)
                runtimeState?.copy(
                    autoResumeEnabled = false,
                    autoResumeAtMs = null,
                    pausedSessionIds = pausedSessionIds
                )?.let { NativePlaybackStateStore.saveTimerRuntimeState(context, it) }
                cancelAlarm(context, actionAutoResume, autoResumeRequestCode)
                logInfo(
                    context,
                    "auto_resume_focus_retry_exhausted attempt=$autoResumeAttempt " +
                        "pausedSessionCount=${pausedSessionIds.size}"
                )
                return
            }
        } else {
            logInfo(context, "auto_resume_skip no_paused_sessions")
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
        val triggerRtcMs = System.currentTimeMillis() + (safeTriggerAtMs - SystemClock.elapsedRealtime())

        try {
            logInfo(
                context,
                "schedule_elapsed_alarm action=$action triggerElapsed=$safeTriggerAtMs " +
                    "triggerRtc=$triggerRtcMs generation=$generation"
            )
            alarmManager.setAlarmClock(
                AlarmManager.AlarmClockInfo(triggerRtcMs, pendingIntent),
                pendingIntent
            )
        } catch (error: SecurityException) {
            logWarn(context, "schedule_elapsed_alarm_exact_denied action=$action", error)
            alarmManager.setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                safeTriggerAtMs,
                pendingIntent
            )
        }
    }

    private fun scheduleRtcAlarm(
        context: Context,
        action: String,
        requestCode: Int,
        triggerAtWallClockMs: Long,
        generation: Int,
        autoResumeAttempt: Int = 0
    ) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            ?: return
        val pendingIntent = pendingIntent(
            context = context,
            action = action,
            requestCode = requestCode,
            generation = generation,
            autoResumeAttempt = autoResumeAttempt,
            flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val safeTriggerAtMs = triggerAtWallClockMs.coerceAtLeast(System.currentTimeMillis() + 250L)

        try {
            logInfo(
                context,
                "schedule_rtc_alarm action=$action triggerAt=$safeTriggerAtMs " +
                    "generation=$generation"
            )
            alarmManager.setAlarmClock(
                AlarmManager.AlarmClockInfo(safeTriggerAtMs, pendingIntent),
                pendingIntent
            )
        } catch (error: SecurityException) {
            logWarn(context, "schedule_rtc_alarm_exact_denied action=$action", error)
            alarmManager.setAndAllowWhileIdle(
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
        logInfo(context, "cancel_alarm action=$action requestCode=$requestCode")
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
        autoResumeAttempt: Int = 0,
        flags: Int
    ): PendingIntent {
        val intent = Intent(context, PlaybackTimerAlarmReceiver::class.java).apply {
            this.action = action
            `package` = context.packageName
            addFlags(Intent.FLAG_RECEIVER_FOREGROUND)
            putExtra(extraGeneration, generation)
            putExtra(extraAutoResumeAttempt, autoResumeAttempt)
        }
        return PendingIntent.getBroadcast(context, requestCode, intent, flags)
    }

    fun onPlaybackStarted(context: Context, sessionId: String) {
        if (sessionId.isBlank()) return
        val pausedSessionIds = NativePlaybackStateStore.loadPausedSessionIds(context)
        if (sessionId !in pausedSessionIds) return
        val remainingPausedIds = pausedSessionIds.filterNot { it == sessionId }
        val remainingCandidateIds = NativePlaybackStateStore
            .loadTimerCandidateSessionIds(context)
            .filterNot { it == sessionId }
        if (remainingPausedIds.isEmpty()) {
            NativePlaybackStateStore.clearPausedSessionIds(context)
        } else {
            NativePlaybackStateStore.storePausedSessionIds(context, remainingPausedIds)
        }
        if (remainingCandidateIds.isEmpty()) {
            NativePlaybackStateStore.clearTimerCandidateSessionIds(context)
        } else {
            NativePlaybackStateStore.storeTimerCandidateSessionIds(context, remainingCandidateIds)
        }
        NativePlaybackStateStore.loadTimerRuntimeState(context)?.let { stored ->
            if (sessionId !in stored.pausedSessionIds) return@let
            val remainingRuntimeIds = stored.pausedSessionIds.filterNot { it == sessionId }
            val updated = stored.copy(
                autoResumeAtMs = stored.autoResumeAtMs.takeIf { remainingRuntimeIds.isNotEmpty() },
                pausedSessionIds = remainingRuntimeIds
            )
            if (updated.hasRuntime) {
                NativePlaybackStateStore.saveTimerRuntimeState(context, updated)
            } else {
                NativePlaybackStateStore.clearTimerRuntimeState(context)
            }
            if (remainingRuntimeIds.isEmpty()) {
                cancelAlarm(context, actionAutoResume, autoResumeRequestCode)
            }
        }
        logInfo(context, "manual_playback_cleared_timer_pause sessionId=$sessionId")
    }

    fun logInfo(context: Context, message: String) {
        AppFileLogger.info(context.applicationContext, logTag, message)
    }

    private fun logWarn(context: Context, message: String, error: Throwable) {
        AppFileLogger.warn(context.applicationContext, logTag, message, error)
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
