package com.doujin.audio.player.notification

import android.content.Intent
import com.doujin.audio.player.session.StoredPlaybackTimerRuntimeState

internal object PlaybackTimerAlarmProtocol {
    const val actionTimerExpired = "com.doujin.audio.action.TIMER_EXPIRED"
    const val actionAutoResume = "com.doujin.audio.action.AUTO_RESUME"
    const val extraGeneration = "generation"
    const val extraAutoResumeAttempt = "auto_resume_attempt"
    const val resultExecuted = "executed"
    const val resultStale = "stale"
    const val resultFailed = "failed"

}

internal fun isPlaybackTimerAlarmAction(action: String?): Boolean {
    return action == PlaybackTimerAlarmProtocol.actionTimerExpired ||
        action == PlaybackTimerAlarmProtocol.actionAutoResume
}

internal fun hasScheduledPlaybackTimerRuntime(
    action: String,
    runtimeState: StoredPlaybackTimerRuntimeState?
): Boolean = when (action) {
    PlaybackTimerAlarmProtocol.actionTimerExpired ->
        runtimeState?.timerEndsAtWallClockMs != null
    PlaybackTimerAlarmProtocol.actionAutoResume ->
        runtimeState?.autoResumeAtMs != null
    else -> false
}


internal fun nextPlaybackTimerAutoResumeAttempt(
    currentAttempt: Int,
    maxRetries: Int = 3
): Int? {
    val normalizedAttempt = currentAttempt.coerceAtLeast(0)
    return (normalizedAttempt + 1).takeIf { normalizedAttempt < maxRetries }
}

internal fun shouldRecalculateAutoResumeAfterSystemEvent(reasonAction: String?): Boolean {
    return reasonAction == Intent.ACTION_TIME_CHANGED ||
        reasonAction == Intent.ACTION_TIMEZONE_CHANGED
}
