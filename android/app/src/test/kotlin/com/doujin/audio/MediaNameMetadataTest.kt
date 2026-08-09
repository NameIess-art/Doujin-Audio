package com.doujin.audio

import com.doujin.audio.metadata.*

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaNameMetadataTest {
    @Test
    fun `normalizes percent encoded display names`() {
        assertEquals(
            "音声 01.mp3",
            MediaNameMetadata.normalizeDisplayName("%E9%9F%B3%E5%A3%B0%2001.mp3")
        )
    }

    @Test
    fun `rejects blocked non media extensions`() {
        assertNull(MediaNameMetadata.mediaNameInfoOrNull("cover.jpg"))
    }

    @Test
    fun `recognizes video extension and removes extension from title`() {
        val info = MediaNameMetadata.mediaNameInfoOrNull("episode.mp4", "video/mp4")

        assertEquals("episode", info?.title)
        assertTrue(info?.isVideo == true)
    }
}
