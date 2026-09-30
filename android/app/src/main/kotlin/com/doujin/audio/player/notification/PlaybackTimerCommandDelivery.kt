package com.doujin.audio.player.notification

import android.content.BroadcastReceiver
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import com.doujin.audio.player.session.NativePlaybackStateStore
import com.doujin.audio.player.session.StoredPlaybackTimerRuntimeState

internal typealias PlaybackTimerAction = (String, StoredPlaybackTimerRuntimeState?, Int?, Int) -> Boolean

internal class PlaybackTimerCommandDelivery(
    private val startService: (Context) -> PlaybackTimerAction?,
    private val beginCommandDelivery: () -> Unit,
    private val endCommandDelivery: () -> Unit,
    private val logInfo: (Context, String) -> Unit,
    private val logWarn: (Context, String, Throwable) -> Unit
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val maxServiceDeliveryAttempts = 40
    private val serviceDeliveryRetryDelayMs = 250L
    private val deliveryWakeLockTimeoutMs = 15_000L

    fun acquireDeliveryWakeLock(context: Context): PowerManager.WakeLock? {
        return try {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            powerManager?.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "${context.packageName}:playback_timer_delivery"
            )?.apply {
                setReferenceCounted(false)
                acquire(deliveryWakeLockTimeoutMs)
            }
        } catch (_: Exception) {
            null
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
    ) {
        val runtimeState = NativePlaybackStateStore.loadTimerRuntimeState(context)
        if (runtimeState != null &&
            generation != null &&
            runtimeState.generation != generation
        ) {
            logInfo(
                context,
                "execute_skip_stale_generation action=$action expected=${runtimeState.generation} " +
                    "actual=$generation"
            )
            finishDelivery(
                pendingResult,
                deliveryWakeLock,
                commandDeliveryRegistered = false
            )
            onComplete?.invoke(PlaybackTimerAlarmProtocol.resultStale)
            return
        }
        if (!hasScheduledPlaybackTimerRuntime(action, runtimeState)) {
            logInfo(context, "execute_skip_unscheduled_action action=$action")
            finishDelivery(
                pendingResult,
                deliveryWakeLock,
                commandDeliveryRegistered = false
            )
            onComplete?.invoke(PlaybackTimerAlarmProtocol.resultStale)
            return
        }
        beginCommandDelivery()
        logInfo(context, "execute_now action=$action generation=$generation")
        deliverToService(
            context = context,
            action = action,
            runtimeState = runtimeState,
            generation = generation,
            autoResumeAttempt = autoResumeAttempt,
            attempt = 0,
            pendingResult = pendingResult,
            deliveryWakeLock = deliveryWakeLock,
            onComplete = onComplete
        )
    }

    private fun deliverToService(
        context: Context,
        action: String,
        runtimeState: StoredPlaybackTimerRuntimeState?,
        generation: Int?,
        autoResumeAttempt: Int,
        attempt: Int,
        pendingResult: BroadcastReceiver.PendingResult?,
        deliveryWakeLock: PowerManager.WakeLock?,
        onComplete: ((String) -> Unit)?
    ) {
        val currentState = NativePlaybackStateStore.loadTimerRuntimeState(context)
        if (currentState != null &&
            generation != null &&
            currentState.generation != generation
        ) {
            finishDelivery(pendingResult, deliveryWakeLock)
            onComplete?.invoke(PlaybackTimerAlarmProtocol.resultStale)
            return
        }
        if (!hasScheduledPlaybackTimerRuntime(action, currentState)) {
            finishDelivery(pendingResult, deliveryWakeLock)
            onComplete?.invoke(PlaybackTimerAlarmProtocol.resultStale)
            return
        }
        val executeAction = startService(context)
        if (executeAction == null) {
            if (attempt >= maxServiceDeliveryAttempts) {
                logInfo(context, "deliver_to_service_give_up action=$action attempt=$attempt")
                finishDelivery(pendingResult, deliveryWakeLock)
                onComplete?.invoke(PlaybackTimerAlarmProtocol.resultFailed)
                return
            }
            logInfo(context, "deliver_to_service_retry action=$action attempt=$attempt")
            mainHandler.postDelayed(
                {
                    deliverToService(
                        context = context,
                        action = action,
                        runtimeState = runtimeState,
                        generation = generation,
                        autoResumeAttempt = autoResumeAttempt,
                        attempt = attempt + 1,
                        pendingResult = pendingResult,
                        deliveryWakeLock = deliveryWakeLock,
                        onComplete = onComplete
                    )
                },
                serviceDeliveryRetryDelayMs
            )
            return
        }

        val latestState = NativePlaybackStateStore.loadTimerRuntimeState(context)
        if (latestState != null &&
            generation != null &&
            latestState.generation != generation
        ) {
            finishDelivery(pendingResult, deliveryWakeLock)
            onComplete?.invoke(PlaybackTimerAlarmProtocol.resultStale)
            return
        }
        if (!hasScheduledPlaybackTimerRuntime(action, latestState)) {
            finishDelivery(pendingResult, deliveryWakeLock)
            onComplete?.invoke(PlaybackTimerAlarmProtocol.resultStale)
            return
        }

        val outcome = try {
            logInfo(context, "deliver_to_service_execute action=$action")
            val supported = executeAction(
                action, latestState ?: runtimeState, generation, autoResumeAttempt
            )
            if (supported) PlaybackTimerAlarmProtocol.resultExecuted else PlaybackTimerAlarmProtocol.resultFailed
        } catch (error: Throwable) {
            logWarn(context, "deliver_to_service_failed action=$action", error)
            PlaybackTimerAlarmProtocol.resultFailed
        }
        try {
            finishDelivery(pendingResult, deliveryWakeLock)
        } finally {
            onComplete?.invoke(outcome)
        }
    }

    private fun finishDelivery(
        pendingResult: BroadcastReceiver.PendingResult?,
        deliveryWakeLock: PowerManager.WakeLock?,
        commandDeliveryRegistered: Boolean = true
    ) {
        try {
            pendingResult?.finish()
        } finally {
            try {
                if (deliveryWakeLock?.isHeld == true) {
                    deliveryWakeLock.release()
                }
            } catch (_: RuntimeException) {
            } finally {
                if (commandDeliveryRegistered) {
                    endCommandDelivery()
                }
            }
        }
    }

}
