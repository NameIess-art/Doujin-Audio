package com.doujin.audio

import com.doujin.audio.metadata.embeddedCoverCacheFileName

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class EmbeddedCoverCacheKeyTest {
    @Test
    fun `same cover bytes share one cache file name`() {
        val cover = byteArrayOf(0x01, 0x23, 0x45, 0x67)

        assertEquals(
            embeddedCoverCacheFileName(cover),
            embeddedCoverCacheFileName(cover.copyOf())
        )
    }

    @Test
    fun `different cover bytes keep separate cache file names`() {
        assertNotEquals(
            embeddedCoverCacheFileName(byteArrayOf(0x01, 0x23)),
            embeddedCoverCacheFileName(byteArrayOf(0x01, 0x24))
        )
    }
}
