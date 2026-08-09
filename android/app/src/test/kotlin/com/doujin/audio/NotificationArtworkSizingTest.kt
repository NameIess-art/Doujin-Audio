package com.doujin.audio

import com.doujin.audio.player.notification.*

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationArtworkSizingTest {
    @Test
    fun `large square image is sampled near target size`() {
        assertEquals(16, calculateNotificationInSampleSize(4096, 4096, 256))
    }

    @Test
    fun `wide image keeps enough pixels for the long edge`() {
        assertEquals(8, calculateNotificationInSampleSize(4096, 1024, 512))
    }

    @Test
    fun `small and invalid images are not sampled`() {
        assertEquals(1, calculateNotificationInSampleSize(128, 128, 256))
        assertEquals(1, calculateNotificationInSampleSize(0, 0, 256))
        assertEquals(1, calculateNotificationInSampleSize(4096, 4096, 0))
    }

    @Test
    fun `stale generation and unrelated artwork cannot refresh notification`() {
        assertFalse(
            shouldRefreshNotificationArtwork(1, 2, "/old.jpg", listOf("/old.jpg"))
        )
        assertFalse(
            shouldRefreshNotificationArtwork(2, 2, "/old.jpg", listOf("/new.jpg"))
        )
        assertTrue(
            shouldRefreshNotificationArtwork(2, 2, "/new.jpg", listOf(" /new.jpg "))
        )
    }
}
