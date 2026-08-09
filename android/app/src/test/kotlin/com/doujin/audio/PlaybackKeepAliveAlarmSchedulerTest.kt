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
}
