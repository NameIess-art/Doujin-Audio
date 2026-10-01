package com.doujin.audio

import com.doujin.audio.channel.FileCacheTaskResult
import com.doujin.audio.channel.PlaybackTimerSyncArguments
import com.doujin.audio.channel.PlaybackTimerSyncCoordinator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackTimerSyncCoordinatorTest {
    @Test
    fun `cancellation applies immediately and pending read cannot rearm timer`() {
        val reads = mutableListOf<(FileCacheTaskResult<Map<String, Long>>) -> Unit>()
        val applied = mutableListOf<PlaybackTimerSyncArguments>()
        val coordinator = PlaybackTimerSyncCoordinator(
            loadCandidates = { reads.add(it); true },
            isSessionCurrent = { _, _ -> true },
            apply = { args, _ -> applied.add(args) }
        )
        var replies = 0
        val started = arguments(deadline = 1000L)
        val cancelled = arguments(deadline = null)
        coordinator.sync(started) { assertEquals(null, it); replies++ }
        assertTrue(applied.isEmpty())
        coordinator.sync(cancelled) { assertEquals(null, it); replies++ }
        assertEquals(listOf(cancelled), applied)
        reads.single()(FileCacheTaskResult.Success(mapOf("old-session" to 1L)))
        assertEquals(listOf(cancelled), applied)
        assertEquals(2, replies)
    }

    @Test
    fun `same generation settings changes apply only latest read and omit deleted sessions`() {
        val reads = mutableListOf<(FileCacheTaskResult<Map<String, Long>>) -> Unit>()
        val applied = mutableListOf<Pair<PlaybackTimerSyncArguments, List<String>>>()
        val revisions = mutableMapOf("persistent" to 2L, "temporary" to 3L, "deleted" to 5L)
        val coordinator = PlaybackTimerSyncCoordinator(
            loadCandidates = { reads.add(it); true },
            isSessionCurrent = { id, revision -> revisions[id] == revision },
            apply = { args, ids -> applied.add(args to ids) }
        )
        val first = arguments(1000L)
        val latest = first.copy(autoResumeHour = 8)
        coordinator.sync(first) { assertEquals(null, it) }
        coordinator.sync(latest) { assertEquals(null, it) }
        reads[1](FileCacheTaskResult.Success(mapOf("persistent" to 2L, "temporary" to 3L, "deleted" to 4L)))
        reads[0](FileCacheTaskResult.Success(mapOf("persistent" to 2L)))
        assertEquals(listOf(latest to listOf("persistent", "temporary")), applied)
    }

    @Test
    fun `closed handler acknowledges pending read without changing alarms`() {
        lateinit var read: (FileCacheTaskResult<Map<String, Long>>) -> Unit
        var applied = false
        var completed = false
        val coordinator = PlaybackTimerSyncCoordinator(
            loadCandidates = { read = it; true },
            isSessionCurrent = { _, _ -> true },
            apply = { _, _ -> applied = true }
        )
        coordinator.sync(arguments(1000L)) { completed = true }
        coordinator.close()
        read(FileCacheTaskResult.Success(emptyMap()))
        assertEquals(false, applied)
        assertTrue(completed)
    }

    @Test
    fun `failed background read reports failure without scheduling alarms`() {
        val failure = IllegalStateException("read failed")
        var actual: Exception? = null
        val coordinator = PlaybackTimerSyncCoordinator(
            loadCandidates = { it(FileCacheTaskResult.Failure(failure)); true },
            isSessionCurrent = { _, _ -> true },
            apply = { _, _ -> error("Unexpected schedule") }
        )
        coordinator.sync(arguments(1000L)) { actual = it }
        assertSame(failure, actual)
    }

    @Test
    fun `rejected background work replies once without changing alarms`() {
        var replies = 0
        val coordinator = PlaybackTimerSyncCoordinator(
            loadCandidates = { false },
            isSessionCurrent = { _, _ -> true },
            apply = { _, _ -> error("Unexpected schedule") }
        )
        coordinator.sync(arguments(1000L)) {
            assertTrue(it is IllegalStateException)
            replies++
        }
        assertEquals(1, replies)
    }

    private fun arguments(deadline: Long?) = PlaybackTimerSyncArguments(
        timerModeIndex = 0, durationMs = 1000L, waitingForPlayback = false,
        timerEndsAtWallClockMs = deadline, autoResumeEnabled = true,
        autoResumeHour = 7, autoResumeMinute = 0, autoResumeAtMs = null,
        pausedSessionIds = emptyList(), generation = 4
    )
}
