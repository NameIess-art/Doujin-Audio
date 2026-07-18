package com.nameless.audio

import com.nameless.audio.player.service.shouldAutoPlayWithAudioFocus
import com.nameless.audio.player.session.handleMediaSessionPlayerCommandRequest

import androidx.media3.common.Player
import androidx.media3.session.SessionResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeMediaSessionCommandPolicyTest {
    @Test
    fun `auto play requests focus before allowing playback`() {
        var focusRequests = 0

        val granted = shouldAutoPlayWithAudioFocus(autoPlayRequested = true) {
            focusRequests += 1
            true
        }
        val paused = shouldAutoPlayWithAudioFocus(autoPlayRequested = false) {
            focusRequests += 1
            true
        }

        assertTrue(granted)
        assertFalse(paused)
        assertEquals(1, focusRequests)
    }

    @Test
    fun `auto play remains paused when focus is denied`() {
        val shouldAutoPlay = shouldAutoPlayWithAudioFocus(autoPlayRequested = true) { false }

        assertFalse(shouldAutoPlay)
    }

    @Test
    fun `external play obtains focus and records playback intent`() {
        var marked = 0
        var cleared = 0

        val result = handleMediaSessionPlayerCommandRequest(
            command = Player.COMMAND_PLAY_PAUSE,
            playWhenReady = false,
            requestAudioFocus = { true },
            markPlaybackIntended = { marked += 1 },
            clearPlaybackIntent = { cleared += 1 }
        )

        assertEquals(SessionResult.RESULT_SUCCESS, result)
        assertEquals(1, marked)
        assertEquals(0, cleared)
    }

    @Test
    fun `external play is rejected and intent cleared when focus is denied`() {
        var marked = 0
        var cleared = 0

        val result = handleMediaSessionPlayerCommandRequest(
            command = Player.COMMAND_PLAY_PAUSE,
            playWhenReady = false,
            requestAudioFocus = { false },
            markPlaybackIntended = { marked += 1 },
            clearPlaybackIntent = { cleared += 1 }
        )

        assertEquals(SessionResult.RESULT_ERROR_INVALID_STATE, result)
        assertEquals(0, marked)
        assertEquals(1, cleared)
    }

    @Test
    fun `external pause and stop clear playback intent without requesting focus`() {
        var focusRequests = 0
        var cleared = 0
        val requestFocus = {
            focusRequests += 1
            true
        }

        val pauseResult = handleMediaSessionPlayerCommandRequest(
            command = Player.COMMAND_PLAY_PAUSE,
            playWhenReady = true,
            requestAudioFocus = requestFocus,
            markPlaybackIntended = {},
            clearPlaybackIntent = { cleared += 1 }
        )
        val stopResult = handleMediaSessionPlayerCommandRequest(
            command = Player.COMMAND_STOP,
            playWhenReady = true,
            requestAudioFocus = requestFocus,
            markPlaybackIntended = {},
            clearPlaybackIntent = { cleared += 1 }
        )

        assertEquals(SessionResult.RESULT_SUCCESS, pauseResult)
        assertEquals(SessionResult.RESULT_SUCCESS, stopResult)
        assertEquals(0, focusRequests)
        assertEquals(2, cleared)
    }
}
