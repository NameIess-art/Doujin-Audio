package com.doujin.audio.player.service

import android.media.AudioManager
import android.content.Intent
import android.os.Bundle
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import com.doujin.audio.channel.*
import com.doujin.audio.player.session.NativeAudioEffects

internal fun shouldPublishProgressHeartbeat(
    isScreenOn: Boolean,
    nowElapsedRealtimeMs: Long,
    lastPublishedElapsedRealtimeMs: Long,
    screenOffIntervalMs: Long
): Boolean =
    isScreenOn ||
        nowElapsedRealtimeMs - lastPublishedElapsedRealtimeMs >= screenOffIntervalMs

/**
 * Delay before the next progress tick.
 *
 * While the screen is off nothing can observe sub-second progress, so the
 * Runnable itself must back off too - otherwise the main thread is woken twice
 * a second for 12 hours straight under a held wake lock, only to decide that
 * there is nothing to publish.
 */
internal fun progressHeartbeatDelayMs(
    isScreenOn: Boolean,
    screenOnIntervalMs: Long,
    screenOffIntervalMs: Long
): Long = if (isScreenOn) screenOnIntervalMs else screenOffIntervalMs

internal fun exclusivePlaybackSessionIdsToPause(
    targetSessionId: String,
    sessionPlaybackIntent: Map<String, Boolean>
): List<String> = sessionPlaybackIntent
    .filter { (sessionId, hasPlaybackIntent) ->
        sessionId != targetSessionId && hasPlaybackIntent
    }
    .keys
    .toList()

internal val playbackRecoveryOffsetsMs = longArrayOf(
    2_000L,
    8_000L,
    30_000L,
    2 * 60 * 1000L,
    4 * 60 * 1000L
)
internal const val PLAYBACK_RECOVERY_LOW_FREQUENCY_INTERVAL_MS = 5 * 60 * 1000L

internal fun idlePlaybackSessionIdsToRelease(
    focusedSessionId: String?,
    idleSessionIds: Collection<String>
): Set<String> {
    return idleSessionIds
        .filterNot { it == focusedSessionId }
        .toSet()
}

internal fun shouldEnsurePlayerForAudioEffects(
    effects: NativeAudioEffects,
    hasPlayer: Boolean
): Boolean {
    if (hasPlayer) return false
    return effects.skipSilenceEnabled ||
        effects.noiseReductionEnabled ||
        effects.eqEnabled ||
        effects.volumeNormalizationEnabled ||
        effects.panning != 0f ||
        effects.channelSwapEnabled
}

internal fun shouldAutoPlayWithAudioFocus(
    autoPlayRequested: Boolean,
    requestAudioFocus: () -> Boolean
): Boolean = autoPlayRequested && requestAudioFocus()

internal data class NativeTimerResumeResult(
    val resumedSessionIds: List<String>,
    val audioFocusDenied: Boolean
)

@Suppress("DEPRECATION")
internal fun Bundle.rawExtra(key: String): Any? = get(key)

internal fun nativePlaybackStartDecision(
    intent: Intent?,
    expectedToken: String,
    tokenExtra: String,
    bootstrapExtra: String,
    onUnreadableExtras: () -> Unit
): NativePlaybackStartDecision {
    if (intent == null) {
        return evaluateNativePlaybackStart(
            intentPresent = false,
            action = null,
            presentedToken = null,
            expectedToken = expectedToken,
            bootstrapExtraPresent = false,
            bootstrapExtra = null
        )
    }
    return try {
        val extras = intent.extras
        evaluateNativePlaybackStart(
            intentPresent = true,
            action = intent.action,
            presentedToken = extras?.rawExtra(tokenExtra) as? String,
            expectedToken = expectedToken,
            bootstrapExtraPresent = extras?.containsKey(bootstrapExtra) == true,
            bootstrapExtra = extras?.rawExtra(bootstrapExtra)
        )
    } catch (_: RuntimeException) {
        onUnreadableExtras()
        NativePlaybackStartDecision(
            source = NativePlaybackStartSource.REJECTED,
            rejectionReason = "unreadable_extras"
        )
    }
}

internal fun resolveNotificationSessionId(
    requestedSessionId: String,
    focusedSessionId: String?,
    activeSessionIds: Collection<String>,
    existingSessionIds: Collection<String>,
    storedActiveSessionIds: Collection<String>,
    storedSessionIds: Collection<String>
): String {
    return requestedSessionId.ifBlank {
        focusedSessionId
            ?: activeSessionIds.firstOrNull()
            ?: existingSessionIds.firstOrNull()
            ?: storedActiveSessionIds.firstOrNull()
            ?: storedSessionIds.firstOrNull()
            ?: ""
    }
}

internal fun playWhenReadyReasonName(reason: Int): String {
    return when (reason) {
        Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST -> "user_request"
        Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS -> "audio_focus_loss"
        Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY -> "audio_becoming_noisy"
        Player.PLAY_WHEN_READY_CHANGE_REASON_REMOTE -> "remote"
        Player.PLAY_WHEN_READY_CHANGE_REASON_END_OF_MEDIA_ITEM -> "end_of_media_item"
        else -> "unknown($reason)"
    }
}

internal fun shouldTrackTransientAudioFocusPause(
    playWhenReady: Boolean,
    reason: Int,
    focusLossMayResume: Boolean,
    playbackSuspended: Boolean
): Boolean {
    return !playWhenReady &&
        reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS &&
        focusLossMayResume &&
        !playbackSuspended
}

internal enum class NativeAudioFocusAction {
    PAUSE_AND_CLEAR_INTENT,
    PAUSE_AND_RESUME_ON_GAIN,
    DUCK,
    RESTORE,
    NONE
}

internal fun nativeAudioFocusAction(
    change: Int,
    pauseOnDuck: Boolean = false
): NativeAudioFocusAction = when (change) {
    AudioManager.AUDIOFOCUS_LOSS -> NativeAudioFocusAction.PAUSE_AND_CLEAR_INTENT
    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT ->
        NativeAudioFocusAction.PAUSE_AND_RESUME_ON_GAIN
    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> if (pauseOnDuck) {
        NativeAudioFocusAction.PAUSE_AND_RESUME_ON_GAIN
    } else {
        NativeAudioFocusAction.DUCK
    }
    AudioManager.AUDIOFOCUS_GAIN -> NativeAudioFocusAction.RESTORE
    else -> NativeAudioFocusAction.NONE
}

internal fun nativeFocusDuckMultiplierAfterAction(
    currentMultiplier: Float,
    action: NativeAudioFocusAction
): Float = when (action) {
    NativeAudioFocusAction.DUCK -> 0.2f
    NativeAudioFocusAction.PAUSE_AND_CLEAR_INTENT,
    NativeAudioFocusAction.PAUSE_AND_RESUME_ON_GAIN,
    NativeAudioFocusAction.RESTORE -> 1f
    NativeAudioFocusAction.NONE -> currentMultiplier
}

internal fun shouldClearAudioFocusInterruptionState(
    hasPlaybackToKeepAlive: Boolean
): Boolean = !hasPlaybackToKeepAlive

internal fun shouldClearPlaybackIntentForPlayWhenReadyChange(
    playWhenReady: Boolean,
    reason: Int
): Boolean = !playWhenReady &&
    reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY

internal fun shouldDeferPlaybackRecoveryForTransientAudioFocusLoss(
    transientAudioFocusLossActive: Boolean
): Boolean = transientAudioFocusLossActive

internal fun requestAudioFocusForPlayback(
    requestAudioFocus: Boolean,
    request: () -> Boolean
): Boolean = !requestAudioFocus || request()

internal fun shouldTriggerPlaybackRecoveryOnKeepAlive(
    hasPlaybackToKeepAlive: Boolean,
    transientAudioFocusLossActive: Boolean,
    focusDuckActive: Boolean
): Boolean = hasPlaybackToKeepAlive &&
    !shouldDeferPlaybackRecoveryForTransientAudioFocusLoss(
        transientAudioFocusLossActive || focusDuckActive
    )

internal fun shouldPreservePendingAudioFocusResume(
    playWhenReady: Boolean,
    focusLossMayResume: Boolean,
    alreadyPending: Boolean
): Boolean {
    return !playWhenReady && focusLossMayResume && alreadyPending
}

internal fun shouldResumePendingAudioFocusPause(
    audioFocusHeld: Boolean,
    hasPendingAudioFocusResume: Boolean,
    playbackSuspended: Boolean
): Boolean {
    return audioFocusHeld &&
        hasPendingAudioFocusResume &&
        !playbackSuspended
}

internal fun shouldAttemptStickyPlaybackRestore(
    hasSessions: Boolean,
    attemptedStickyPlaybackRestore: Boolean
): Boolean {
    return !hasSessions && !attemptedStickyPlaybackRestore
}

internal fun shouldKeepAliveForIntendedPlayback(
    playbackState: Int,
    hasPlayerError: Boolean,
    hasRecoverablePlaybackError: Boolean = false
): Boolean {
    return playbackState != Player.STATE_ENDED &&
        (!hasPlayerError || hasRecoverablePlaybackError)
}

internal fun shouldRecoverIntendedPlayback(
    playbackState: Int,
    hasPlayerError: Boolean,
    hasRecoverablePlaybackError: Boolean = false
): Boolean {
    return shouldKeepAliveForIntendedPlayback(
        playbackState = playbackState,
        hasPlayerError = hasPlayerError,
        hasRecoverablePlaybackError = hasRecoverablePlaybackError
    )
}

internal fun playbackRecoveryDelayMs(
    attempt: Int,
    recoveryStartedElapsedRealtimeMs: Long,
    nowElapsedRealtimeMs: Long
): Long {
    val offsetMs = playbackRecoveryOffsetsMs.getOrNull(attempt)
        ?: return PLAYBACK_RECOVERY_LOW_FREQUENCY_INTERVAL_MS
    return (recoveryStartedElapsedRealtimeMs + offsetMs - nowElapsedRealtimeMs)
        .coerceAtLeast(0L)
}

internal fun isRecoverablePlaybackErrorCode(errorCode: Int): Boolean {
    return when (errorCode) {
        PlaybackException.ERROR_CODE_IO_UNSPECIFIED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
        PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
        PlaybackException.ERROR_CODE_AUDIO_TRACK_INIT_FAILED,
        PlaybackException.ERROR_CODE_AUDIO_TRACK_WRITE_FAILED -> true
        else -> false
    }
}

internal fun isCandidateFallbackPlaybackErrorCode(errorCode: Int): Boolean {
    return when (errorCode) {
        PlaybackException.ERROR_CODE_IO_UNSPECIFIED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
        PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS -> true
        else -> false
    }
}
