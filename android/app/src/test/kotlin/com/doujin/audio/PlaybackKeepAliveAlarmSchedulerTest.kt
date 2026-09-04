package com.doujin.audio

import com.doujin.audio.player.notification.PlaybackKeepAliveAlarmScheduler
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackKeepAliveAlarmSchedulerTest {
    @Test
    fun `unarmed sentinel is never throttled`() {
        assertFalse(
            PlaybackKeepAliveAlarmScheduler.shouldSkipRearm(
                nowMs = 1_000L,
                lastArmedMs = Long.MIN_VALUE,
            )
        )
    }

    @Test
    fun `recent alarm is throttled`() {
        assertTrue(
            PlaybackKeepAliveAlarmScheduler.shouldSkipRearm(
                nowMs = 61_000L,
                lastArmedMs = 2_000L,
            )
        )
    }

    @Test
    fun `alarm outside throttle window can rearm`() {
        assertFalse(
            PlaybackKeepAliveAlarmScheduler.shouldSkipRearm(
                nowMs = 62_001L,
                lastArmedMs = 2_000L,
            )
        )
    }

    @Test
    fun `active alarm throttle window allows faster rearm`() {
        assertFalse(
            PlaybackKeepAliveAlarmScheduler.shouldSkipRearm(
                nowMs = 32_000L,
                lastArmedMs = 1_000L,
                throttleMs = PlaybackKeepAliveAlarmScheduler.activeRearmThrottleMs
            )
        )
        assertTrue(
            PlaybackKeepAliveAlarmScheduler.shouldSkipRearm(
                nowMs = 26_000L,
                lastArmedMs = 1_000L,
                throttleMs = PlaybackKeepAliveAlarmScheduler.activeRearmThrottleMs
            )
        )
    }

    @Test
    fun `active interval is shorter than idle backstop interval`() {
        assertTrue(
            PlaybackKeepAliveAlarmScheduler.activeIntervalMs <
                PlaybackKeepAliveAlarmScheduler.intervalMs
        )
    }
}
