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

// Dart's countdown uses a wall-clock deadline. Project the native monotonic
// deadline onto the current clock so a manual clock change does not expire it early.
internal fun StoredPlaybackTimerRuntimeState.countdownDeadlineOnWallClock(
    elapsedNow: Long,
    wallNow: Long
): Long? = timerEndsAtWallClockMs?.let { original ->
    timerEndsElapsedRealtimeMs?.let { wallNow + (it - elapsedNow) } ?: original
}

internal fun isPlaybackTimerDue(
    action: String,
    state: StoredPlaybackTimerRuntimeState,
    elapsedNow: Long,
    wallNow: Long
): Boolean = when (action) {
    PlaybackTimerAlarmProtocol.actionTimerExpired ->
        state.countdownDeadlineOnWallClock(elapsedNow, wallNow)?.let { it <= wallNow } == true
    PlaybackTimerAlarmProtocol.actionAutoResume ->
        state.autoResumeAtMs?.let { it <= wallNow } == true
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
