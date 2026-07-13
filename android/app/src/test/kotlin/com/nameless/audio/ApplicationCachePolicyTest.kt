package com.nameless.audio

import com.nameless.audio.common.*

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ApplicationCachePolicyTest {
    @Test
    fun `trim target reserves ten percent for new writes`() {
        assertTrue(applicationCacheTrimTargetBytes(100L) == 90L)
        assertTrue(applicationCacheTrimTargetBytes(1L) == 1L)
    }

    @Test
    fun `evicts while cache exceeds limit and multiple entries remain`() {
        assertTrue(
            shouldEvictApplicationCacheEntry(
                totalBytes = 90,
                maxBytes = 50,
                remainingFiles = 3
            )
        )
    }

    @Test
    fun `keeps final cache entry even when it exceeds limit`() {
        assertFalse(
            shouldEvictApplicationCacheEntry(
                totalBytes = 60,
                maxBytes = 1,
                remainingFiles = 1
            )
        )
    }

    @Test
    fun `does not evict when cache is within limit`() {
        assertFalse(
            shouldEvictApplicationCacheEntry(
                totalBytes = 50,
                maxBytes = 50,
                remainingFiles = 2
            )
        )
    }
}
