package com.nameless.audio

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackKeepAlivePolicyTest {
    @Test
    fun `active playback alone does not require keep alive service`() {
        assertFalse(
            PlaybackKeepAlivePolicy.shouldRunKeepAliveService(
                keepForegroundServiceAlive = true,
                hasActiveTimer = false
            )
        )
    }

    @Test
    fun `timer state can keep keep alive service and wake lock active`() {
        assertTrue(
            PlaybackKeepAlivePolicy.shouldRunKeepAliveService(
                keepForegroundServiceAlive = true,
                hasActiveTimer = true
            )
        )
        assertTrue(
            PlaybackKeepAlivePolicy.shouldHoldKeepAliveWakeLock(
                enabled = true,
                hasActiveTimer = true
            )
        )
    }

    @Test
    fun `playback wake lock ownership stays with native playback service`() {
        assertFalse(
            PlaybackKeepAlivePolicy.shouldHoldKeepAliveWakeLock(
                enabled = true,
                hasActiveTimer = false
            )
        )
    }
}
