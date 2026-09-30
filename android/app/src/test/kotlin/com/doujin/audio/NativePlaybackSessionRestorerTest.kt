package com.doujin.audio

import com.doujin.audio.player.session.*

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class NativePlaybackSessionRestorerTest {
    @Test
    fun `timer write cannot interleave target deletion read update and overwrite the newest alarm`() {
        val initial = StoredPlaybackTimerRuntimeState(1, 60_000L, false, 100_000L, 5_000L,
            true, 7, 30, 200_000L, listOf("A", "B"), 9)
        val state = AtomicReference(initial)
        val oldStateRead = CountDownLatch(1)
        val allowDelete = CountDownLatch(1)
        val writerStarted = CountDownLatch(1)
        val writerCompleted = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val deleting = executor.submit {
                NativePlaybackStateStore.withTimerState {
                    val old = state.get()
                    oldStateRead.countDown()
                    assertTrue(allowDelete.await(2, TimeUnit.SECONDS))
                    state.set(old.withoutSession("A"))
                }
            }
            assertTrue(oldStateRead.await(2, TimeUnit.SECONDS))
            val updating = executor.submit {
                writerStarted.countDown()
                NativePlaybackStateStore.withTimerState {
                    state.set(initial.copy(autoResumeAtMs = 900_000L, pausedSessionIds = listOf("B"), generation = 10))
                }
                writerCompleted.countDown()
            }
            assertTrue(writerStarted.await(2, TimeUnit.SECONDS))
            assertFalse(writerCompleted.await(100, TimeUnit.MILLISECONDS))
            allowDelete.countDown()
            deleting.get(2, TimeUnit.SECONDS)
            updating.get(2, TimeUnit.SECONDS)

            assertEquals(initial.copy(autoResumeAtMs = 900_000L, pausedSessionIds = listOf("B"), generation = 10), state.get())
        } finally {
            allowDelete.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun `timer storage does not wait for the session queue serialization monitor`() {
        val queueWriting = CountDownLatch(1)
        val allowQueueWrite = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val queue = executor.submit {
                synchronized(NativePlaybackStateStore) {
                    queueWriting.countDown()
                    assertTrue(allowQueueWrite.await(2, TimeUnit.SECONDS))
                }
            }
            assertTrue(queueWriting.await(2, TimeUnit.SECONDS))
            val timer = executor.submit<Boolean> { NativePlaybackStateStore.withTimerState { true } }
            assertTrue(timer.get(2, TimeUnit.SECONDS))
            allowQueueWrite.countDown()
            queue.get(2, TimeUnit.SECONDS)
        } finally {
            allowQueueWrite.countDown()
            executor.shutdownNow()
        }
    }
    @Test
    fun `completed definitions preserve end position on disk but explicit restore starts at zero`() {
        val completed = storedSession(emptyList()).copy(completed = true, positionMs = 22_000L)
        val manager = NativePlaybackSessionManager { id -> NativePlaybackSession(id,
            createPlayer = { _, _ -> error("No SDK is needed during restore configuration") },
            logWarn = { _, _, _ -> }, elapsedRealtimeMs = { 1L }) }
        val restorer = NativePlaybackSessionRestorer(manager::getOrCreate, { manager.remove(it) }, {},
            { _, error -> throw error })

        assertEquals(listOf(completed.sessionId), restorer.restore(listOf(completed), { false }))
        assertEquals(22_000L, completed.positionMs)
        assertEquals(0L, manager.get(completed.sessionId)?.snapshot()?.get("positionMs"))
    }
    @Test
    fun `temporary cold definitions restore pause position in memory without creating a player`() {
        val id = "temporary-cold-restore"
        val temporary = storedSession(emptyList()).copy(sessionId = id, isTemporary = true,
            uri = "file:///temporary.mp3", path = "/temporary.mp3", positionMs = 22_000L,
            playing = false, playWhenReady = false)
        NativePlaybackStateStore.invalidateSession(id)
        NativePlaybackStateStore.saveTemporarySession(temporary)
        try {
            val loaded = NativePlaybackStateStore.loadTemporarySessions().filter { it.sessionId == id }
            val manager = NativePlaybackSessionManager { sessionId -> NativePlaybackSession(sessionId,
                createPlayer = { _, _ -> error("Pause restore must stay cold") },
                logWarn = { _, _, _ -> }, elapsedRealtimeMs = { 1L }) }
            val restorer = NativePlaybackSessionRestorer(manager::getOrCreate, { manager.remove(it) }, {},
                { _, error -> throw error },
                isStoredSessionCurrent = { NativePlaybackStateStore.sessionRevision(it.sessionId) == it.definitionRevision })

            assertEquals(listOf(id), restorer.restore(loaded, { false }))
            assertEquals(true, manager.get(id)?.isTemporary)
            assertEquals(22_000L, manager.get(id)?.snapshot()?.get("positionMs"))
            assertEquals(emptyList<StoredNativePlaybackSession>(), manager.storedSnapshots(emptySet()))
        } finally {
            NativePlaybackStateStore.removeTemporarySession(id)
        }
    }

    @Test
    fun `removing one paused target keeps another timer restore target and its alarm`() {
        val timer = StoredPlaybackTimerRuntimeState(1, 60_000L, false, 100_000L, 5_000L,
            true, 7, 30, 200_000L, listOf("A", "B"), 9)
        assertEquals(timer.copy(pausedSessionIds = listOf("B")), timer.withoutSession("A"))
        assertEquals(timer, timer.withoutSession("missing"))
    }
    @Test
    fun `a definition replaced after background load is discarded before runtime creation`() {
        val stored = storedSession(emptyList())
        var current = true
        var created = 0
        val restorer = NativePlaybackSessionRestorer(
            getOrCreateSession = { created++; error("Stale restore must not create runtime") },
            removeSession = { error("No runtime exists") }, focusSession = {},
            logRestoreFailure = { _, _ -> }, isStoredSessionCurrent = { current })
        current = false

        assertEquals(emptyList<String>(), restorer.restore(listOf(stored), { true }))
        assertEquals(0, created)
    }
    @Test
    fun `restored queue keeps persisted queue metadata`() {
        val stored = storedSession(
            queue = listOf(
                StoredNativePlaybackQueueItem(
                    path = "first-path",
                    uri = "first-uri",
                    title = "First",
                    subtitle = "One",
                    artUri = "first-art",
                    candidateUris = listOf(
                        "https://example.com/first.mp3",
                        "https://backup.example.com/first.mp3"
                    )
                ),
                StoredNativePlaybackQueueItem(
                    path = "second-path",
                    uri = "second-uri",
                    title = "Second",
                    subtitle = null,
                    artUri = null
                )
            )
        )

        val restored = stored.restoredQueue()

        assertEquals(listOf("first-path", "second-path"), restored.map { it.path })
        assertEquals(listOf("First", "Second"), restored.map { it.title })
        assertEquals(
            listOf(
                "first-uri",
                "https://example.com/first.mp3",
                "https://backup.example.com/first.mp3"
            ),
            restored.first().candidateUris
        )
        assertEquals(listOf("second-uri"), restored[1].candidateUris)
    }

    @Test
    fun `restored queue falls back to current persisted item`() {
        val stored = storedSession(queue = emptyList())

        val restored = stored.restoredQueue()

        assertEquals(1, restored.size)
        assertEquals(stored.path, restored.single().path)
        assertEquals(stored.uri, restored.single().uri)
    }

    private fun storedSession(
        queue: List<StoredNativePlaybackQueueItem>
    ): StoredNativePlaybackSession {
        return StoredNativePlaybackSession(
            sessionId = "session",
            uri = "uri",
            path = "path",
            title = "Title",
            subtitle = "Subtitle",
            artUri = "art",
            positionMs = 10,
            volume = 1f,
            speed = 1f,
            skipSilenceEnabled = false,
            noiseReductionEnabled = false,
            eqEnabled = false,
            eqPresetId = null,
            eqBandLevels = emptyMap(),
            volumeNormalizationEnabled = false,
            panning = 0f,
            repeatOne = false,
            repeatAll = false,
            shuffleModeEnabled = false,
            queueStartIndex = 0,
            queue = queue,
            channelSwapEnabled = false,
            playing = true,
            playWhenReady = true
        )
    }
}
