package com.doujin.audio

import com.doujin.audio.metadata.coverBridgeCacheKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class CoverArtworkSourceFingerprintTest {
    @Test
    fun `unchanged SAF source keeps the same bridge key`() {
        assertEquals(
            coverBridgeCacheKey("content://tree/cover.jpg", 100L, 200L),
            coverBridgeCacheKey("content://tree/cover.jpg", 100L, 200L)
        )
    }

    @Test
    fun `changed source metadata creates a new bridge key`() {
        val original = coverBridgeCacheKey("content://tree/cover.jpg", 100L, 200L)

        assertNotEquals(
            original,
            coverBridgeCacheKey("content://tree/cover.jpg", 101L, 200L)
        )
        assertNotEquals(
            original,
            coverBridgeCacheKey("content://tree/cover.jpg", 100L, 201L)
        )
    }
}
