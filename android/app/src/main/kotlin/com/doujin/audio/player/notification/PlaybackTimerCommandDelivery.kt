package com.doujin.audio.player.notification

import com.doujin.audio.player.session.StoredPlaybackTimerRuntimeState
import java.util.concurrent.atomic.AtomicBoolean

internal class PlaybackControlDeliveryCompletion(
    private val onFinish: () -> Unit
) {
    private val finished = AtomicBoolean(false)

    fun finish(beforeFinish: () -> Unit = {}): Boolean {
        if (!finished.compareAndSet(false, true)) return false
        try {
            beforeFinish()
        } finally {
            onFinish()
        }
        return true
    }
}

internal typealias PlaybackTimerAction = (
    String, StoredPlaybackTimerRuntimeState?, Int?, Int, (String) -> Unit
) -> Unit

internal class PlaybackTimerCommandDelivery(
    private val startService: () -> PlaybackTimerAction?,
    private val loadRuntimeState: () -> StoredPlaybackTimerRuntimeState?,
    private val postDelayed: (() -> Unit, Long) -> Unit,
    private val beginCommandDelivery: () -> Unit,
    private val endCommandDelivery: () -> Unit,
    private val logInfo: (String) -> Unit,
    private val logWarn: (String, Throwable) -> Unit
) {
    private val maxServiceDeliveryAttempts = 40
    private val serviceDeliveryRetryDelayMs = 250L

    fun executeNow(
        action: String,
        generation: Int?,
        autoResumeAttempt: Int = 0,
        onComplete: (String) -> Unit
    ) {
        val runtimeState = loadRuntimeState()
        if (!isCurrent(action, generation, runtimeState)) {
            logInfo("execute_skip_stale_or_unscheduled action=$action generation=$generation")
            onComplete(PlaybackTimerAlarmProtocol.resultStale)
            return
        }
        beginCommandDelivery()
        val completion = PlaybackControlDeliveryCompletion(endCommandDelivery)
        val complete: (String) -> Unit = { outcome ->
            completion.finish { onComplete(outcome) }
        }
        logInfo("execute_now action=$action generation=$generation")
        deliverToService(action, generation, autoResumeAttempt, 0, complete)
    }

    private fun deliverToService(
        action: String,
        generation: Int?,
        autoResumeAttempt: Int,
        attempt: Int,
        complete: (String) -> Unit
    ) {
        if (!isCurrent(action, generation, loadRuntimeState())) {
            complete(PlaybackTimerAlarmProtocol.resultStale)
            return
        }
        val executeAction = startService()
        if (executeAction == null) {
            if (attempt >= maxServiceDeliveryAttempts) {
                logInfo("deliver_to_service_give_up action=$action attempt=$attempt")
                complete(PlaybackTimerAlarmProtocol.resultFailed)
                return
            }
            logInfo("deliver_to_service_retry action=$action attempt=$attempt")
            postDelayed(
                { deliverToService(action, generation, autoResumeAttempt, attempt + 1, complete) },
                serviceDeliveryRetryDelayMs
            )
            return
        }
        val latestState = loadRuntimeState()
        if (!isCurrent(action, generation, latestState)) {
            complete(PlaybackTimerAlarmProtocol.resultStale)
            return
        }
        try {
            logInfo("deliver_to_service_execute action=$action")
            // The service completes this only after any asynchronous restore and
            // generation validation. A queued action has not executed yet.
            executeAction(action, latestState, generation, autoResumeAttempt, complete)
        } catch (error: Throwable) {
            logWarn("deliver_to_service_failed action=$action", error)
            complete(PlaybackTimerAlarmProtocol.resultFailed)
        }
    }

    private fun isCurrent(
        action: String,
        generation: Int?,
        runtime: StoredPlaybackTimerRuntimeState?
    ): Boolean = hasScheduledPlaybackTimerRuntime(action, runtime) &&
        (generation == null || runtime?.generation == generation)
}
