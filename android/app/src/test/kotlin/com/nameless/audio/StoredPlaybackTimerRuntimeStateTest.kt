package com.nameless.audio

import android.content.Intent
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
        val autoResumeState = pausedState.copy(
            autoResumeAtMs = 1_700_000_000_000L
        )

        assertTrue(waitingState.hasRuntime)
        assertTrue(waitingState.shouldKeepForegroundServiceAlive)
        assertTrue(pausedState.hasRuntime)
        assertFalse(pausedState.shouldKeepForegroundServiceAlive)
        assertTrue(autoResumeState.hasRuntime)
        assertTrue(autoResumeState.shouldKeepForegroundServiceAlive)
    }

    @Test
    fun `auto resume target survives reboot and package replacement`() {
        assertFalse(
            shouldRecalculateAutoResumeAfterSystemEvent(Intent.ACTION_BOOT_COMPLETED)
        )
        assertFalse(
            shouldRecalculateAutoResumeAfterSystemEvent(Intent.ACTION_MY_PACKAGE_REPLACED)
        )
    }

    @Test
    fun `auto resume target follows wall clock changes`() {
        assertTrue(
            shouldRecalculateAutoResumeAfterSystemEvent(Intent.ACTION_TIME_CHANGED)
        )
        assertTrue(
            shouldRecalculateAutoResumeAfterSystemEvent(Intent.ACTION_TIMEZONE_CHANGED)
        )
    }
}
