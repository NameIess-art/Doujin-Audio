package com.nameless.audio

import com.nameless.audio.player.service.*

import android.media.AudioManager
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackFocusRecoveryPolicyTest {
    @Test
    fun `foreground sync waits for system gain during transient focus loss`() {
        assertTrue(
            shouldDeferPlaybackRecoveryForTransientAudioFocusLoss(
                transientAudioFocusLossActive = true
            )
        )
        assertFalse(
            shouldDeferPlaybackRecoveryForTransientAudioFocusLoss(
                transientAudioFocusLossActive = false
            )
        )
    }

    @Test
    fun `keep alive heartbeat triggers recovery unless focus interruption is active`() {
        assertTrue(
            shouldTriggerPlaybackRecoveryOnKeepAlive(
                hasPlaybackToKeepAlive = true,
                transientAudioFocusLossActive = false,
                focusDuckActive = false
            )
        )
        assertFalse(
            shouldTriggerPlaybackRecoveryOnKeepAlive(
                hasPlaybackToKeepAlive = true,
                transientAudioFocusLossActive = true,
                focusDuckActive = false
            )
        )
        assertFalse(
            shouldTriggerPlaybackRecoveryOnKeepAlive(
                hasPlaybackToKeepAlive = true,
                transientAudioFocusLossActive = false,
                focusDuckActive = true
            )
        )
        assertFalse(
            shouldTriggerPlaybackRecoveryOnKeepAlive(
                hasPlaybackToKeepAlive = false,
                transientAudioFocusLossActive = false,
                focusDuckActive = false
            )
        )
    }

    @Test
    fun `duckable focus loss keeps playback running`() {
        assertEquals(
            NativeAudioFocusAction.DUCK,
            nativeAudioFocusAction(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
        )
    }

    @Test
    fun `duckable focus loss can be configured to pause`() {
        assertEquals(
            NativeAudioFocusAction.PAUSE_AND_RESUME_ON_GAIN,
            nativeAudioFocusAction(
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
                pauseOnDuck = true
            )
        )
    }

    @Test
    fun `transient focus loss pauses until focus returns`() {
        assertEquals(
            NativeAudioFocusAction.PAUSE_AND_RESUME_ON_GAIN,
            nativeAudioFocusAction(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        )
    }

    @Test
    fun `permanent focus loss pauses without auto resume`() {
        assertEquals(
            NativeAudioFocusAction.PAUSE_AND_CLEAR_INTENT,
            nativeAudioFocusAction(AudioManager.AUDIOFOCUS_LOSS)
        )
        assertEquals(
            NativeAudioFocusAction.RESTORE,
            nativeAudioFocusAction(AudioManager.AUDIOFOCUS_GAIN)
        )
    }

    @Test
    fun `duck upgraded to transient loss restores volume before gain`() {
        val ducked = nativeFocusDuckMultiplierAfterAction(
            currentMultiplier = 1f,
            action = NativeAudioFocusAction.DUCK
        )
        val paused = nativeFocusDuckMultiplierAfterAction(
            currentMultiplier = ducked,
            action = NativeAudioFocusAction.PAUSE_AND_RESUME_ON_GAIN
        )
        val gained = nativeFocusDuckMultiplierAfterAction(
            currentMultiplier = paused,
            action = NativeAudioFocusAction.RESTORE
        )

        assertEquals(0.2f, ducked, 0.001f)
        assertEquals(1f, paused, 0.001f)
        assertEquals(1f, gained, 0.001f)
    }

    @Test
    fun `last user pause clears stale focus interruption before later play`() {
        assertTrue(
            shouldClearAudioFocusInterruptionState(hasPlaybackToKeepAlive = false)
        )
        assertFalse(
            shouldClearAudioFocusInterruptionState(hasPlaybackToKeepAlive = true)
        )
    }

    @Test
    fun `becoming noisy clears playback intent`() {
        assertTrue(
            shouldClearPlaybackIntentForPlayWhenReadyChange(
                playWhenReady = false,
                reason = Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY
            )
        )
        assertFalse(
            shouldClearPlaybackIntentForPlayWhenReadyChange(
                playWhenReady = false,
                reason = Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS
            )
        )
    }

    @Test
    fun `keeps native transient focus pause pending through player callback`() {
        assertTrue(
            shouldPreservePendingAudioFocusResume(
                playWhenReady = false,
                focusLossMayResume = true,
                alreadyPending = true
            )
        )
        assertFalse(
            shouldPreservePendingAudioFocusResume(
                playWhenReady = true,
                focusLossMayResume = true,
                alreadyPending = true
            )
        )
    }

    @Test
    fun `tracks transient audio focus loss pauses for auto resume`() {
        assertTrue(
            shouldTrackTransientAudioFocusPause(
                playWhenReady = false,
                reason = Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS,
                focusLossMayResume = true,
                playbackSuspended = false
            )
        )
    }

    @Test
    fun `does not track user pause or permanent stop for auto resume`() {
        assertFalse(
            shouldTrackTransientAudioFocusPause(
                playWhenReady = false,
                reason = Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST,
                focusLossMayResume = true,
                playbackSuspended = false
            )
        )
        assertFalse(
            shouldTrackTransientAudioFocusPause(
                playWhenReady = false,
                reason = Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS,
                focusLossMayResume = false,
                playbackSuspended = false
            )
        )
    }

    @Test
    fun `does not auto resume while playback is intentionally suspended`() {
        assertFalse(
            shouldTrackTransientAudioFocusPause(
                playWhenReady = false,
                reason = Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS,
                focusLossMayResume = true,
                playbackSuspended = true
            )
        )
    }

    @Test
    fun `resumes pending focus pause when focus is already held again`() {
        assertTrue(
            shouldResumePendingAudioFocusPause(
                audioFocusHeld = true,
                hasPendingAudioFocusResume = true,
                playbackSuspended = false
            )
        )
    }

    @Test
    fun `does not resume pending focus pause without focus or while suspended`() {
        assertFalse(
            shouldResumePendingAudioFocusPause(
                audioFocusHeld = false,
                hasPendingAudioFocusResume = true,
                playbackSuspended = false
            )
        )
        assertFalse(
            shouldResumePendingAudioFocusPause(
                audioFocusHeld = true,
                hasPendingAudioFocusResume = true,
                playbackSuspended = true
            )
        )
    }

    @Test
    fun `attempts sticky restore whenever service has no sessions and restore not yet attempted`() {
        assertTrue(
            shouldAttemptStickyPlaybackRestore(
                hasSessions = false,
                attemptedStickyPlaybackRestore = false
            )
        )
        assertFalse(
            shouldAttemptStickyPlaybackRestore(
                hasSessions = true,
                attemptedStickyPlaybackRestore = false
            )
        )
        assertFalse(
            shouldAttemptStickyPlaybackRestore(
                hasSessions = false,
                attemptedStickyPlaybackRestore = true
            )
        )
    }

    @Test
    fun `keeps intended playback alive through recoverable failures`() {
        assertTrue(
            shouldKeepAliveForIntendedPlayback(
                playbackState = Player.STATE_READY,
                hasPlayerError = false
            )
        )
        assertTrue(
            shouldRecoverIntendedPlayback(
                playbackState = Player.STATE_IDLE,
                hasPlayerError = false
            )
        )
        assertFalse(
            shouldKeepAliveForIntendedPlayback(
                playbackState = Player.STATE_ENDED,
                hasPlayerError = false
            )
        )
        assertFalse(
            shouldRecoverIntendedPlayback(
                playbackState = Player.STATE_READY,
                hasPlayerError = true,
                hasRecoverablePlaybackError = false
            )
        )
        assertTrue(
            shouldRecoverIntendedPlayback(
                playbackState = Player.STATE_IDLE,
                hasPlayerError = true,
                hasRecoverablePlaybackError = true
            )
        )
    }

    @Test
    fun `uses bounded recovery retry offsets`() {
        assertEquals(2_000L, playbackRecoveryDelayMs(0, 0L, 0L))
        assertEquals(8_000L, playbackRecoveryDelayMs(1, 0L, 0L))
        assertEquals(30_000L, playbackRecoveryDelayMs(2, 0L, 0L))
        assertEquals(120_000L, playbackRecoveryDelayMs(3, 0L, 0L))
        assertEquals(240_000L, playbackRecoveryDelayMs(4, 0L, 0L))
        assertEquals(300_000L, playbackRecoveryDelayMs(5, 0L, 0L))
        assertEquals(300_000L, playbackRecoveryDelayMs(6, 0L, 0L))
    }

    @Test
    fun `retry offsets are measured from the first failure`() {
        assertEquals(
            3_000L,
            playbackRecoveryDelayMs(
                attempt = 1,
                recoveryStartedElapsedRealtimeMs = 10_000L,
                nowElapsedRealtimeMs = 15_000L
            )
        )
        assertEquals(
            0L,
            playbackRecoveryDelayMs(
                attempt = 0,
                recoveryStartedElapsedRealtimeMs = 10_000L,
                nowElapsedRealtimeMs = 20_000L
            )
        )
    }

    @Test
    fun `retries transient network and audio track failures`() {
        assertTrue(
            isRecoverablePlaybackErrorCode(
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED
            )
        )
        assertTrue(
            isRecoverablePlaybackErrorCode(
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT
            )
        )
        assertTrue(
            isRecoverablePlaybackErrorCode(
                PlaybackException.ERROR_CODE_AUDIO_TRACK_WRITE_FAILED
            )
        )
    }

    @Test
    fun `does not retry deterministic source failures`() {
        assertFalse(
            isRecoverablePlaybackErrorCode(
                PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND
            )
        )
        assertFalse(
            isRecoverablePlaybackErrorCode(
                PlaybackException.ERROR_CODE_IO_NO_PERMISSION
            )
        )
        assertFalse(
            isRecoverablePlaybackErrorCode(
                PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED
            )
        )
    }

    @Test
    fun `releases every idle player except the focused session`() {
        assertEquals(
            setOf("session-a", "session-c"),
            idlePlaybackSessionIdsToRelease(
                focusedSessionId = "session-b",
                idleSessionIds = listOf("session-a", "session-b", "session-c")
            )
        )
        assertEquals(
            setOf("session-a", "session-b"),
            idlePlaybackSessionIdsToRelease(
                focusedSessionId = "playing-session",
                idleSessionIds = listOf("session-a", "session-b")
            )
        )
    }
}
