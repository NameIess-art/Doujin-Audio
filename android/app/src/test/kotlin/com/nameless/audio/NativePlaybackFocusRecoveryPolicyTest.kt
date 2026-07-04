package com.nameless.audio

import android.media.AudioManager
import androidx.media3.common.Player
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackFocusRecoveryPolicyTest {
    @Test
    fun `duckable focus loss keeps playback running`() {
        assertFalse(
            shouldPauseForAudioFocusChange(
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK
            )
        )
    }

    @Test
    fun `transient focus loss pauses until focus returns`() {
        assertTrue(
            shouldPauseForAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
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
    fun `keeps intended playback alive unless ended or failed`() {
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
                hasPlayerError = true
            )
        )
    }
}
