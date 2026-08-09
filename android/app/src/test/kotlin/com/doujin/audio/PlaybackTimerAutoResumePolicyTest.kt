package com.doujin.audio

import com.doujin.audio.player.notification.nextPlaybackTimerAutoResumeAttempt

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PlaybackTimerAutoResumePolicyTest {
    @Test
    fun `focus denial schedules three bounded retry alarms`() {
        val first = nextPlaybackTimerAutoResumeAttempt(currentAttempt = 0)
        val second = nextPlaybackTimerAutoResumeAttempt(currentAttempt = 1)
        val third = nextPlaybackTimerAutoResumeAttempt(currentAttempt = 2)

        assertEquals(1, first)
        assertEquals(2, second)
        assertEquals(3, third)
    }

    @Test
    fun `third retry denial exhausts automatic resume`() {
        val exhausted = nextPlaybackTimerAutoResumeAttempt(currentAttempt = 3)

        assertNull(exhausted)
    }
}
