package com.doujin.audio

import com.doujin.audio.metadata.VideoFrameSize
import com.doujin.audio.metadata.calculateVideoFrameSize
import com.doujin.audio.metadata.shouldDecodeLegacyVideoFrame
import com.doujin.audio.metadata.videoFrameCacheKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FileCacheVideoFrameResolverTest {
    @Test
    fun `landscape video frame is scaled to the maximum edge`() {
        assertEquals(
            VideoFrameSize(width = 1200, height = 675),
            calculateVideoFrameSize(width = 3840, height = 2160)
        )
    }

    @Test
    fun `portrait video frame keeps its aspect ratio`() {
        assertEquals(
            VideoFrameSize(width = 675, height = 1200),
            calculateVideoFrameSize(width = 1080, height = 1920)
        )
    }

    @Test
    fun `small video frame keeps its original dimensions`() {
        assertEquals(
            VideoFrameSize(width = 640, height = 360),
            calculateVideoFrameSize(width = 640, height = 360)
        )
    }

    @Test
    fun `invalid video dimensions are rejected`() {
        assertNull(calculateVideoFrameSize(width = 0, height = 1080))
        assertNull(calculateVideoFrameSize(width = 1920, height = -1))
    }

    @Test
    fun `legacy decoder only accepts known dimensions within the limit`() {
        assertTrue(shouldDecodeLegacyVideoFrame(width = 1200, height = 675))
        assertFalse(shouldDecodeLegacyVideoFrame(width = 1920, height = 1080))
        assertFalse(shouldDecodeLegacyVideoFrame(width = null, height = 1080))
    }

    @Test
    fun `source modification creates a new video frame key`() {
        assertEquals(
            videoFrameCacheKey("/media/work.mp4", 100L),
            videoFrameCacheKey("/media/work.mp4", 100L)
        )
        assertFalse(
            videoFrameCacheKey("/media/work.mp4", 100L) ==
                videoFrameCacheKey("/media/work.mp4", 101L)
        )
    }
}
