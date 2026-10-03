package com.doujin.audio

import com.doujin.audio.scanner.FolderScanTask
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class FolderScanBackpressureTest {
    @Test
    fun `worker cannot produce next chunk until consumer acknowledges current chunk`() {
        val task = FolderScanTask("generation-1")
        val executor = Executors.newSingleThreadExecutor()
        val waiting = CountDownLatch(1)
        val producedNext = CountDownLatch(1)
        try {
            assertEquals(1L, task.beginChunk())
            val worker = executor.submit {
                waiting.countDown()
                task.awaitChunkAcknowledgement()
                assertEquals(2L, task.beginChunk())
                producedNext.countDown()
            }
            assertTrue(waiting.await(2, TimeUnit.SECONDS))
            assertFalse(producedNext.await(100, TimeUnit.MILLISECONDS))
            assertFalse(task.acknowledgeChunk(2))
            assertFalse(producedNext.await(100, TimeUnit.MILLISECONDS))
            assertTrue(task.acknowledgeChunk(1))
            assertTrue(producedNext.await(2, TimeUnit.SECONDS))
            worker.get(2, TimeUnit.SECONDS)
        } finally {
            task.cancel()
            executor.shutdownNow()
        }
    }

    @Test
    fun `acknowledgement arriving before worker waits is not lost`() {
        val task = FolderScanTask("generation-1")
        val executor = Executors.newSingleThreadExecutor()
        try {
            assertEquals(1L, task.beginChunk())
            assertTrue(task.acknowledgeChunk(1))
            executor.submit { task.awaitChunkAcknowledgement() }.get(2, TimeUnit.SECONDS)
            assertEquals(2L, task.beginChunk())
            assertFalse(task.acknowledgeChunk(1))
            assertTrue(task.acknowledgeChunk(2))
            assertFalse(task.acknowledgeChunk(2))
        } finally {
            task.cancel()
            executor.shutdownNow()
        }
    }

    @Test
    fun `cancelling while waiting releases worker and rejects late acknowledgements`() {
        val task = FolderScanTask("generation-1")
        val executor = Executors.newSingleThreadExecutor()
        val waiting = CountDownLatch(1)
        try {
            task.beginChunk()
            val worker = executor.submit {
                waiting.countDown()
                task.awaitChunkAcknowledgement()
            }
            assertTrue(waiting.await(2, TimeUnit.SECONDS))
            task.cancel()
            worker.get(2, TimeUnit.SECONDS)
            assertTrue(task.cancelled)
            assertFalse(task.acknowledgeChunk(1))
            assertNull(task.beginChunk())
        } finally {
            task.cancel()
            executor.shutdownNow()
        }
    }

    @Test
    fun `cancelling before worker waits also releases pending chunk`() {
        val task = FolderScanTask("generation-1")
        val executor = Executors.newSingleThreadExecutor()
        try {
            task.beginChunk()
            task.cancel()
            executor.submit { task.awaitChunkAcknowledgement() }.get(2, TimeUnit.SECONDS)
            assertNull(task.beginChunk())
        } finally {
            task.cancel()
            executor.shutdownNow()
        }
    }
}
