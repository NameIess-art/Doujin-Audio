package com.doujin.audio.player.service

import android.media.AudioManager
import android.content.Intent
import android.os.Bundle
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import com.doujin.audio.channel.*
import com.doujin.audio.player.session.NativePlaybackSession

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

internal data class NativeTimerPauseResult(
    val sessionIds: List<String>,
    val waitingForTrackEnd: Boolean
)

internal data class NativeTimerPauseTargets(
    val sessionIds: List<String>,
    val trackEndTargets: List<String>,
    val immediatePauseTargets: List<String>
)

internal fun selectTimerPauseTargets(
    activeSessionIds: List<String>,
    interruptedSessionIds: List<String>,
    intendedSessionIds: Set<String>,
    stopAfterCurrentTrack: Boolean
): NativeTimerPauseTargets {
    val sessionIds = (activeSessionIds + interruptedSessionIds + intendedSessionIds).distinct()
    val trackEndTargets = if (stopAfterCurrentTrack) {
        activeSessionIds - interruptedSessionIds.toSet()
    } else {
        emptyList()
    }
    val immediatePauseTargets = if (stopAfterCurrentTrack) {
        sessionIds - trackEndTargets.toSet()
    } else {
        sessionIds
    }
    return NativeTimerPauseTargets(sessionIds, trackEndTargets, immediatePauseTargets)
}

internal fun shouldRetainWarmPausedAudioPlayer(
    sessionId: String,
    focusedSessionId: String?,
    playbackSuspended: Boolean,
    hasActiveUiListeners: Boolean,
    hasActivePlayback: Boolean,
    player: Player?
): Boolean = !playbackSuspended &&
    hasActiveUiListeners &&
    !hasActivePlayback &&
    focusedSessionId == sessionId &&
    player != null &&
    player.playerError == null &&
    player.playbackState != Player.STATE_ENDED

internal fun isTimerDueForStickyRestart(
    timerEndsElapsedRealtimeMs: Long?,
    timerEndsAtWallClockMs: Long?,
    nowElapsedRealtimeMs: Long,
    nowWallClockMs: Long
): Boolean = timerEndsElapsedRealtimeMs?.let { it <= nowElapsedRealtimeMs }
    ?: (timerEndsAtWallClockMs?.let { it <= nowWallClockMs } == true)

internal fun formatPlaybackServiceLogState(
    sessionLogState: String,
    foregroundStarted: Boolean,
    audioFocusHeld: Boolean,
    screenInteractive: Boolean,
    activePlayback: Boolean,
    keepAlivePlayback: Boolean
): String = "${sessionLogState}foregroundStarted=$foregroundStarted " +
    "audioFocusHeld=$audioFocusHeld " +
    "screenInteractive=$screenInteractive " +
    "activePlayback=$activePlayback " +
    "keepAlivePlayback=$keepAlivePlayback"

internal fun dispatchNotificationTransportCommand(
    command: String,
    session: NativePlaybackSession?,
    clearTrackStop: (String) -> Unit,
    play: (String) -> Unit,
    pause: (String) -> Map<String, Any?>,
    publishPauseBatchSnapshots: (List<Map<String, Any?>>) -> Unit,
    publishPauseBatchIds: (List<String>) -> Unit
) {
    val target = session ?: return
    val player = target.playerOrNull()
    when (command) {
        NATIVE_PLAYBACK_TRANSPORT_PREVIOUS -> {
            clearTrackStop(target.sessionId)
            if (player != null && player.hasPreviousMediaItem()) player.seekToPreviousMediaItem()
        }
        NATIVE_PLAYBACK_TRANSPORT_NEXT -> {
            clearTrackStop(target.sessionId)
            if (player != null && player.hasNextMediaItem()) player.seekToNextMediaItem()
        }
        NATIVE_PLAYBACK_TRANSPORT_PLAY_PAUSE -> {
            val isActive = player?.let { it.isPlaying || it.playWhenReady } == true
            if (isActive) {
                @Suppress("UNCHECKED_CAST")
                val pausedSnapshot = pause(target.sessionId)["value"] as? Map<String, Any?>
                if (pausedSnapshot != null) {
                    publishPauseBatchSnapshots(listOf(pausedSnapshot))
                } else {
                    publishPauseBatchIds(listOf(target.sessionId))
                }
            } else {
                play(target.sessionId)
            }
        }
    }
}

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
    transportCommandExtra: String? = null,
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
            bootstrapExtra = extras?.rawExtra(bootstrapExtra),
            transportCommand = transportCommandExtra?.let { extras?.rawExtra(it) }
        )
    } catch (_: RuntimeException) {
        onUnreadableExtras()
        NativePlaybackStartDecision(
            source = NativePlaybackStartSource.REJECTED,
            rejectionReason = "unreadable_extras"
        )
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
    (reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY ||
        reason == Player.PLAY_WHEN_READY_CHANGE_REASON_END_OF_MEDIA_ITEM)

internal fun shouldDeferPlaybackRecoveryForTransientAudioFocusLoss(
    transientAudioFocusLossActive: Boolean
): Boolean = transientAudioFocusLossActive

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
        PlaybackException.ERROR_CODE_TIMEOUT,
        PlaybackException.ERROR_CODE_REMOTE_ERROR,
        PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW,
        PlaybackException.ERROR_CODE_IO_UNSPECIFIED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
        PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
        PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE,
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
        PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FAILED,
        PlaybackException.ERROR_CODE_AUDIO_TRACK_INIT_FAILED,
        PlaybackException.ERROR_CODE_AUDIO_TRACK_WRITE_FAILED -> true
        else -> false
    }
}

internal fun isPlayerRebuildRequiredForErrorCode(errorCode: Int): Boolean {
    return when (errorCode) {
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
        PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FAILED,
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
