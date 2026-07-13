package com.nameless.audio

import com.nameless.audio.channel.*

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
        assertTrue(threadNames.all { it.startsWith("nameless-file-task-") })
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
    fun `shutdown is idempotent and rejects new tasks`() {
        val executor = FileCacheTaskExecutor()
        executor.shutdownNow()
        executor.shutdownNow()

        assertFalse(executor.submit(block = { true }, completion = {}))
    }
}
