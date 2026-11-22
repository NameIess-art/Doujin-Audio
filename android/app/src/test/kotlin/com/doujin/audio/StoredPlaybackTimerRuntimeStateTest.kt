package com.doujin.audio

import com.doujin.audio.player.notification.*
import com.doujin.audio.player.session.*

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

    @Test
    fun `withoutSession clears autoResumeAtMs when the last paused session is removed`() {
        val state = StoredPlaybackTimerRuntimeState(
            timerModeIndex = null,
            durationMs = null,
            waitingForPlayback = false,
            timerEndsAtWallClockMs = null,
            timerEndsElapsedRealtimeMs = null,
            autoResumeEnabled = true,
            autoResumeHour = 7,
            autoResumeMinute = 30,
            autoResumeAtMs = 1_700_000_000_000L,
            pausedSessionIds = listOf("session-1", "session-2"),
            generation = 9
        )

        val unchanged = state.withoutSession("unrelated")
        org.junit.Assert.assertEquals(state, unchanged)

        val afterFirst = state.withoutSession("session-1")
        org.junit.Assert.assertEquals(listOf("session-2"), afterFirst.pausedSessionIds)
        org.junit.Assert.assertEquals(1_700_000_000_000L, afterFirst.autoResumeAtMs)
        assertTrue(afterFirst.hasRuntime)

        val afterLast = afterFirst.withoutSession("session-2")
        assertTrue(afterLast.pausedSessionIds.isEmpty())
        org.junit.Assert.assertNull(afterLast.autoResumeAtMs)
        assertFalse(afterLast.hasRuntime)
    }
}
