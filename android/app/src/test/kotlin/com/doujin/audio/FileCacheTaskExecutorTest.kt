package com.doujin.audio

import com.doujin.audio.channel.*

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FileCacheTaskExecutorTest {
    @Test
    fun `ordinary file task concurrency never exceeds two`() {
        val executor = FileCacheTaskExecutor()
        val releaseTasks = CountDownLatch(1)
        val firstTwoStarted = CountDownLatch(2)
        val allFinished = CountDownLatch(8)
        val active = AtomicInteger()
        val peak = AtomicInteger()
        val threadNames = Collections.synchronizedSet(mutableSetOf<String>())

        repeat(8) { index ->
            assertTrue(
                executor.submit(
                    block = {
                        threadNames.add(Thread.currentThread().name)
                        val running = active.incrementAndGet()
                        peak.updateAndGet { current -> maxOf(current, running) }
                        firstTwoStarted.countDown()
                        releaseTasks.await(5, TimeUnit.SECONDS)
                        active.decrementAndGet()
                        index
                    },
                    completion = {
                        assertEquals(index, (it as FileCacheTaskResult.Success).value)
                        allFinished.countDown()
                    }
                )
            )
        }

        assertTrue(firstTwoStarted.await(5, TimeUnit.SECONDS))
        assertEquals(2, peak.get())
        releaseTasks.countDown()
        assertTrue(allFinished.await(5, TimeUnit.SECONDS))
        assertTrue(threadNames.all { it.startsWith("doujin-file-task-") })
        executor.shutdownNow()
    }

    @Test
    fun `task failures reach the completion callback`() {
        val executor = FileCacheTaskExecutor()
        val finished = CountDownLatch(1)
        var failure: Exception? = null

        assertTrue(
            executor.submit(
                block = { throw IllegalStateException("broken") },
                completion = {
                    failure = (it as FileCacheTaskResult.Failure).exception
                    finished.countDown()
                }
            )
        )

        assertTrue(finished.await(5, TimeUnit.SECONDS))
        assertTrue(failure is IllegalStateException)
        assertEquals("broken", failure?.message)
        executor.shutdownNow()
    }

    @Test
    fun `blocked transfers do not delay interactive tasks and remain serialized`() {
        val executor = FileCacheTaskExecutor()
        val transferStarted = CountDownLatch(1)
        val releaseTransfer = CountDownLatch(1)
        val transferFinished = CountDownLatch(2)
        val interactiveFinished = CountDownLatch(1)
        val queuedTransferStarted = CountDownLatch(1)
        try {
            assertTrue(executor.submitTransfer(
                block = {
                    transferStarted.countDown()
                    releaseTransfer.await()
                },
                completion = { transferFinished.countDown() }
            ))
            assertTrue(transferStarted.await(5, TimeUnit.SECONDS))
            assertTrue(executor.submitTransfer(
                block = { queuedTransferStarted.countDown() },
                completion = { transferFinished.countDown() }
            ))
            assertTrue(executor.submit(
                block = { "subtitle" },
                completion = { interactiveFinished.countDown() }
            ))

            assertTrue(interactiveFinished.await(5, TimeUnit.SECONDS))
            assertEquals(1L, releaseTransfer.count)
            assertEquals(1L, queuedTransferStarted.count)
            releaseTransfer.countDown()
            assertTrue(transferFinished.await(5, TimeUnit.SECONDS))
            assertEquals(0L, queuedTransferStarted.count)
        } finally {
            releaseTransfer.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun `transfer failures reach completion and do not poison the queue`() {
        val executor = FileCacheTaskExecutor()
        val failed = CountDownLatch(1)
        val nextFinished = CountDownLatch(1)
        var failure: Exception? = null
        try {
            assertTrue(executor.submitTransfer(
                block = { throw IllegalStateException("copy failed") },
                completion = {
                    failure = (it as FileCacheTaskResult.Failure).exception
                    failed.countDown()
                }
            ))
            assertTrue(executor.submitTransfer(
                block = { true },
                completion = { nextFinished.countDown() }
            ))
            assertTrue(failed.await(5, TimeUnit.SECONDS))
            assertEquals("copy failed", failure?.message)
            assertTrue(nextFinished.await(5, TimeUnit.SECONDS))
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun `shutdown interrupts running tasks in both queues and discards queued transfers`() {
        val executor = FileCacheTaskExecutor()
        val started = CountDownLatch(2)
        val interrupted = CountDownLatch(2)
        val queuedTransferRuns = AtomicInteger()
        val block = {
            started.countDown()
            try {
                CountDownLatch(1).await()
            } catch (exception: InterruptedException) {
                interrupted.countDown()
                throw exception
            }
        }
        try {
            assertTrue(executor.submit(block, completion = {}))
            assertTrue(executor.submitTransfer(block, completion = {}))
            assertTrue(started.await(5, TimeUnit.SECONDS))
            assertTrue(executor.submitTransfer(
                block = { queuedTransferRuns.incrementAndGet() },
                completion = {}
            ))
            executor.shutdownNow()
            assertTrue(interrupted.await(5, TimeUnit.SECONDS))
            assertEquals(0, queuedTransferRuns.get())
            assertFalse(executor.submitTransfer(block = { true }, completion = {}))
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun `shutdown is idempotent and rejects new tasks`() {
        val executor = FileCacheTaskExecutor()
        executor.shutdownNow()
        executor.shutdownNow()

        assertFalse(executor.submit(block = { true }, completion = {}))
        assertFalse(executor.submitTransfer(block = { true }, completion = {}))
    }
}
