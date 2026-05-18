package com.nameless.audio

import androidx.media3.common.Player
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackFocusRecoveryPolicyTest {
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
}
