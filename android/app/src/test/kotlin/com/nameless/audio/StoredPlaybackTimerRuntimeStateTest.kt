package com.nameless.audio

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StoredPlaybackTimerRuntimeStateTest {
    @Test
    fun `hasRuntime covers waiting timer and paused sessions`() {
        val waitingState = StoredPlaybackTimerRuntimeState(
            timerModeIndex = 1,
            durationMs = 30_000L,
            waitingForPlayback = true,
            timerEndsAtWallClockMs = null,
            timerEndsElapsedRealtimeMs = null,
            autoResumeEnabled = true,
            autoResumeHour = 7,
            autoResumeMinute = 30,
            autoResumeAtMs = null,
            pausedSessionIds = emptyList(),
            generation = 7
        )
        val pausedState = waitingState.copy(
            timerModeIndex = null,
            durationMs = null,
            waitingForPlayback = false,
            pausedSessionIds = listOf("session-1")
        )

        assertTrue(waitingState.hasRuntime)
        assertTrue(waitingState.shouldKeepForegroundServiceAlive)
        assertTrue(pausedState.hasRuntime)
        assertFalse(pausedState.shouldKeepForegroundServiceAlive)
    }
}
