package com.doujin.audio

import com.doujin.audio.player.recovery.*
import com.doujin.audio.player.service.playbackRecoveryDelayMs

import androidx.media3.common.Player
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackHealthPolicyTest {
    @Test
    fun `ready playback intent stalls after thirty seconds without output`() {
        val initial = evaluateNativePlaybackHealth(
            previous = null,
            current = sample(
                nowMs = 0L,
                playbackState = Player.STATE_READY,
                isPlaying = false
            )
        )
        val stalled = evaluateNativePlaybackHealth(
            previous = initial.state,
            current = sample(
                nowMs = 30_000L,
                playbackState = Player.STATE_READY,
                isPlaying = false
            )
        )

        assertEquals(NativePlaybackStallReason.READY_NOT_PLAYING, stalled.stallReason)
        assertFalse(stalled.positionAdvanced)
    }

    @Test
    fun `buffer movement resets buffering stall timer`() {
        val initial = evaluateNativePlaybackHealth(
            previous = null,
            current = sample(
                nowMs = 0L,
                playbackState = Player.STATE_BUFFERING,
                bufferedPositionMs = 2_000L,
                isPlaying = false
            )
        )
        val progressing = evaluateNativePlaybackHealth(
            previous = initial.state,
            current = sample(
                nowMs = 30_000L,
                playbackState = Player.STATE_BUFFERING,
                bufferedPositionMs = 5_000L,
                isPlaying = false
            )
        )
        val waiting = evaluateNativePlaybackHealth(
            previous = progressing.state,
            current = sample(
                nowMs = 74_999L,
                playbackState = Player.STATE_BUFFERING,
                bufferedPositionMs = 5_000L,
                isPlaying = false
            )
        )
        val stalled = evaluateNativePlaybackHealth(
            previous = waiting.state,
            current = sample(
                nowMs = 75_000L,
                playbackState = Player.STATE_BUFFERING,
                bufferedPositionMs = 5_000L,
                isPlaying = false
            )
        )

        assertTrue(progressing.bufferAdvanced)
        assertNull(waiting.stallReason)
        assertEquals(NativePlaybackStallReason.BUFFERING, stalled.stallReason)
    }

    @Test
    fun `is playing with frozen position is detected independently`() {
        val initial = evaluateNativePlaybackHealth(
            previous = null,
            current = sample(nowMs = 10_000L, isPlaying = true)
        )
        val stalled = evaluateNativePlaybackHealth(
            previous = initial.state,
            current = sample(nowMs = 40_000L, isPlaying = true)
        )

        assertEquals(NativePlaybackStallReason.POSITION_FROZEN, stalled.stallReason)
    }

    @Test
    fun `position progress marks recovery healthy`() {
        val initial = evaluateNativePlaybackHealth(
            previous = null,
            current = sample(nowMs = 0L, positionMs = 1_000L)
        )
        val progressed = evaluateNativePlaybackHealth(
            previous = initial.state,
            current = sample(nowMs = 15_000L, positionMs = 15_500L)
        )

        assertTrue(progressed.positionAdvanced)
        assertNull(progressed.stallReason)
        assertEquals(15_000L, progressed.state.lastActivityElapsedRealtimeMs)
    }

    @Test
    fun `repeat one loop rewind counts as activity instead of a frozen position`() {
        // A short looping track sampled at the health-check interval can report a
        // position at or below the previous one on the same media item. That is
        // the loop wrapping, not a stall - re-preparing here restarts audio
        // under a sleeping user.
        val initial = evaluateNativePlaybackHealth(
            previous = null,
            current = sample(nowMs = 10_000L, positionMs = 14_000L, isPlaying = true)
        )
        val looped = evaluateNativePlaybackHealth(
            previous = initial.state,
            current = sample(nowMs = 25_000L, positionMs = 500L, isPlaying = true)
        )
        val stillLooping = evaluateNativePlaybackHealth(
            previous = looped.state,
            current = sample(nowMs = 40_000L, positionMs = 200L, isPlaying = true)
        )

        assertNull(looped.stallReason)
        assertEquals(25_000L, looped.state.lastActivityElapsedRealtimeMs)
        assertNull(stillLooping.stallReason)
        assertEquals(40_000L, stillLooping.state.lastActivityElapsedRealtimeMs)
    }

    @Test
    fun `a genuinely frozen position is still detected after the rewind allowance`() {
        val initial = evaluateNativePlaybackHealth(
            previous = null,
            current = sample(nowMs = 10_000L, positionMs = 5_000L, isPlaying = true)
        )
        // Same position within tolerance: neither advanced nor rewound.
        val frozen = evaluateNativePlaybackHealth(
            previous = initial.state,
            current = sample(nowMs = 45_000L, positionMs = 5_100L, isPlaying = true)
        )

        assertEquals(NativePlaybackStallReason.POSITION_FROZEN, frozen.stallReason)
    }

    @Test
    fun `pause suppression seek and track transition reset health baseline`() {
        val stale = NativePlaybackHealthState(
            sample = sample(nowMs = 0L, mediaItemIndex = 0),
            lastActivityElapsedRealtimeMs = 0L
        )

        val paused = evaluateNativePlaybackHealth(
            previous = stale,
            current = sample(nowMs = 60_000L, playWhenReady = false)
        )
        val suppressed = evaluateNativePlaybackHealth(
            previous = stale,
            current = sample(
                nowMs = 60_000L,
                suppressionReason = Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS
            )
        )
        val sought = evaluateNativePlaybackHealth(
            previous = stale,
            current = sample(nowMs = 60_000L, positionMs = 20_000L)
        )
        val transitioned = evaluateNativePlaybackHealth(
            previous = stale,
            current = sample(nowMs = 60_000L, mediaItemIndex = 1)
        )

        assertNull(paused.stallReason)
        assertNull(suppressed.stallReason)
        assertTrue(sought.positionAdvanced)
        assertNull(transitioned.stallReason)
        assertEquals(60_000L, transitioned.state.lastActivityElapsedRealtimeMs)
    }

    @Test
    fun `near end and completed media are never treated as stalled`() {
        val stale = NativePlaybackHealthState(
            sample = sample(nowMs = 0L),
            lastActivityElapsedRealtimeMs = 0L
        )

        val nearEnd = evaluateNativePlaybackHealth(
            previous = stale,
            current = sample(
                nowMs = 60_000L,
                positionMs = 99_000L,
                durationMs = 100_000L,
                isPlaying = false
            )
        )
        val ended = evaluateNativePlaybackHealth(
            previous = stale,
            current = sample(
                nowMs = 60_000L,
                playbackState = Player.STATE_ENDED,
                isPlaying = false
            )
        )

        assertNull(nearEnd.stallReason)
        assertNull(ended.stallReason)
    }

    @Test
    fun `recovery delay stays capped at five minutes after bounded offsets`() {
        assertEquals(2_000L, playbackRecoveryDelayMs(0, 0L, 0L))
        assertEquals(8_000L, playbackRecoveryDelayMs(1, 0L, 0L))
        assertEquals(30_000L, playbackRecoveryDelayMs(2, 0L, 0L))
        assertEquals(120_000L, playbackRecoveryDelayMs(3, 0L, 0L))
        assertEquals(240_000L, playbackRecoveryDelayMs(4, 0L, 0L))
        assertEquals(300_000L, playbackRecoveryDelayMs(5, 0L, 240_000L))
        assertEquals(300_000L, playbackRecoveryDelayMs(20, 0L, 3_600_000L))
    }

    private fun sample(
        nowMs: Long,
        positionMs: Long = 1_000L,
        bufferedPositionMs: Long = 2_000L,
        durationMs: Long? = 120_000L,
        mediaItemIndex: Int = 0,
        playbackState: Int = Player.STATE_READY,
        playWhenReady: Boolean = true,
        isPlaying: Boolean = true,
        suppressionReason: Int = Player.PLAYBACK_SUPPRESSION_REASON_NONE,
        hasPlayerError: Boolean = false
    ) = NativePlaybackHealthSample(
        sessionId = "session",
        positionMs = positionMs,
        bufferedPositionMs = bufferedPositionMs,
        durationMs = durationMs,
        mediaItemIndex = mediaItemIndex,
        playbackState = playbackState,
        playWhenReady = playWhenReady,
        isPlaying = isPlaying,
        playbackSuppressionReason = suppressionReason,
        hasPlayerError = hasPlayerError,
        capturedElapsedRealtimeMs = nowMs
    )
}
