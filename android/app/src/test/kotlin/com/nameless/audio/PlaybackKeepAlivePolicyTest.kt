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
                hasActiveTimer = false,
                hasActivePlayback = true
            )
        )
    }

    @Test
    fun `timer state can keep keep alive service and wake lock active`() {
        assertTrue(
            PlaybackKeepAlivePolicy.shouldRunKeepAliveService(
                keepForegroundServiceAlive = true,
                hasActiveTimer = true,
                hasActivePlayback = false
            )
        )
        assertTrue(
            PlaybackKeepAlivePolicy.shouldHoldKeepAliveWakeLock(
                enabled = true,
                hasActiveTimer = true,
                hasActivePlayback = false
            )
        )
    }

    @Test
    fun `active playback owns foreground service even when timer is active`() {
        assertFalse(
            PlaybackKeepAlivePolicy.shouldRunKeepAliveService(
                keepForegroundServiceAlive = true,
                hasActiveTimer = true,
                hasActivePlayback = true
            )
        )
        assertFalse(
            PlaybackKeepAlivePolicy.shouldHoldKeepAliveWakeLock(
                enabled = true,
                hasActiveTimer = true,
                hasActivePlayback = true
            )
        )
    }

    @Test
    fun `playback wake lock ownership stays with native playback service`() {
        assertFalse(
            PlaybackKeepAlivePolicy.shouldHoldKeepAliveWakeLock(
                enabled = true,
                hasActiveTimer = false,
                hasActivePlayback = true
            )
        )
    }
}
