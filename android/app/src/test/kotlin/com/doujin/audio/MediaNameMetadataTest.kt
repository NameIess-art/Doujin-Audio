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
    fun `preserves literal plus signs and malformed percent sequences`() {
        assertEquals(
            "Track A+B Remix.mp3",
            MediaNameMetadata.normalizeDisplayName("Track%20A+B%20Remix.mp3")
        )
        assertEquals(
            "100% pure audio.mp3",
            MediaNameMetadata.normalizeDisplayName("100% pure%20audio.mp3")
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

    @Test
    fun `rejects blank extensions dotfiles directories and unknown extensions`() {
        assertNull(MediaNameMetadata.mediaNameInfoOrNull(""))
        assertNull(MediaNameMetadata.mediaNameInfoOrNull("README"))
        assertNull(MediaNameMetadata.mediaNameInfoOrNull(".nomedia"))
        assertNull(MediaNameMetadata.mediaNameInfoOrNull(".hidden"))
        assertNull(MediaNameMetadata.mediaNameInfoOrNull("notes.ini"))
        assertNull(MediaNameMetadata.mediaNameInfoOrNull("Subfolder", "vnd.android.document/directory"))
    }

    @Test
    fun `recognizes supported audio extensions and explicit audio mime`() {
        val mp3 = MediaNameMetadata.mediaNameInfoOrNull("track.mp3")
        assertEquals("track", mp3?.title)
        assertEquals(false, mp3?.isVideo)

        val opus = MediaNameMetadata.mediaNameInfoOrNull("voice.opus")
        assertEquals("voice", opus?.title)
        assertEquals(false, opus?.isVideo)

        val mimeOnly = MediaNameMetadata.mediaNameInfoOrNull("stream", "audio/mpeg")
        assertEquals("stream", mimeOnly?.title)
        assertEquals(false, mimeOnly?.isVideo)
    }
}
