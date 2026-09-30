package com.doujin.audio

import com.doujin.audio.player.session.NativePlaybackStatePersistenceCoordinator
import com.doujin.audio.player.session.NativePlaybackStatePersistenceEnvironment
import com.doujin.audio.player.session.StoredNativePlaybackProgress
import com.doujin.audio.player.session.StoredNativePlaybackSession
import com.doujin.audio.player.session.withProgressOverlay
import com.doujin.audio.player.session.NativePlaybackStateStore
import com.doujin.audio.player.session.NativePlaybackSession
import com.doujin.audio.player.session.NativePlaybackSessionManager
import com.doujin.audio.player.session.NativeMediaItemDescriptor
import com.doujin.audio.player.session.mergeNativePlaybackDefinitions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackStatePersistenceCoordinatorTest {
    @Test
    fun `shutdown flushes latest snapshot while debounce is pending`() {
        val environment = FakeStatePersistenceEnvironment()
        var snapshots = listOf(storedSession(positionMs = 120L))
        val coordinator = coordinator(environment, storedSessions = { snapshots })

        coordinator.ensureTicker()
        coordinator.schedulePersist()
        snapshots = listOf(storedSession(positionMs = 840L))
        coordinator.shutdown()
        environment.runBackgroundTasks()

        assertEquals(listOf(snapshots), environment.savedSessions)
        assertTrue(environment.delayedTasks.isEmpty())
        assertTrue(environment.shutdownCalled)
    }

    @Test
    fun `shutdown captures latest snapshot without pending debounce`() {
        val environment = FakeStatePersistenceEnvironment()
        val snapshots = listOf(storedSession(positionMs = 1_240L))
        val coordinator = coordinator(environment, storedSessions = { snapshots })

        coordinator.shutdown()
        environment.runBackgroundTasks()

        assertEquals(listOf(snapshots), environment.savedSessions)
    }

    @Test
    fun `shutdown generation supersedes an older queued snapshot`() {
        val environment = FakeStatePersistenceEnvironment()
        var snapshots = listOf(storedSession(positionMs = 120L))
        val coordinator = coordinator(environment, storedSessions = { snapshots })

        coordinator.persistNow()
        snapshots = listOf(storedSession(positionMs = 2_400L))
        coordinator.shutdown()
        environment.runBackgroundTasks()

        assertEquals(listOf(snapshots), environment.savedSessions)
    }

    @Test
    fun `shutdown without runtime sessions preserves cold recovery definitions`() {
        val environment = FakeStatePersistenceEnvironment()
        val coordinator = coordinator(
            environment,
            hasSessions = { false },
            storedSessions = { error("No snapshots should be captured") }
        )

        coordinator.shutdown()
        environment.runBackgroundTasks()

        assertEquals(0, environment.clearCount)
        assertTrue(environment.savedSessions.isEmpty())
    }

    @Test
    fun `ticker runs only while playback is active and flushes when playback pauses`() {
        val environment = FakeStatePersistenceEnvironment()
        var active = false
        var snapshots = listOf(storedSession(positionMs = 120L))
        val coordinator = coordinator(
            environment,
            hasActivePlayback = { active },
            storedSessions = { snapshots }
        )

        coordinator.ensureTicker()
        assertTrue(environment.delayedTasks.isEmpty())

        active = true
        coordinator.onPlaybackActivityChanged()
        assertEquals(listOf(10_000L), environment.delayedTasks.values.toList())

        snapshots = listOf(storedSession(positionMs = 840L))
        active = false
        coordinator.onPlaybackActivityChanged()
        environment.runBackgroundTasks()

        assertTrue(environment.delayedTasks.isEmpty())
        assertEquals(listOf(snapshots), environment.savedSessions)
    }

    @Test
    fun `identical snapshots are not written repeatedly`() {
        val environment = FakeStatePersistenceEnvironment()
        val snapshots = listOf(storedSession(positionMs = 1_240L))
        val coordinator = coordinator(environment, storedSessions = { snapshots })

        coordinator.persistNow()
        coordinator.persistNow()
        environment.runBackgroundTasks()

        assertEquals(listOf(snapshots), environment.savedSessions)
    }

    @Test
    fun `position only changes write the small progress payload not the whole queue`() {
        val environment = FakeStatePersistenceEnvironment()
        var snapshots = listOf(storedSession(positionMs = 1_000L))
        val coordinator = coordinator(environment, storedSessions = { snapshots })

        coordinator.persistNow()
        environment.runBackgroundTasks()
        snapshots = listOf(storedSession(positionMs = 6_000L))
        coordinator.persistNow()
        environment.runBackgroundTasks()
        snapshots = listOf(storedSession(positionMs = 11_000L))
        coordinator.persistNow()
        environment.runBackgroundTasks()

        // One structural write, then progress-only writes.
        assertEquals(1, environment.savedSessions.size)
        assertEquals(
            listOf(6_000L, 11_000L),
            environment.savedProgress.map { it.single().positionMs }
        )
    }

    @Test
    fun `progress overlay wins over the structural snapshot on restore`() {
        val stored = storedSession(positionMs = 1_000L)

        val merged = stored.withProgressOverlay(
            StoredNativePlaybackProgress(
                sessionId = "session-1",
                positionMs = 3_600_000L,
                playing = true,
                playWhenReady = true
            )
        )

        assertEquals(3_600_000L, merged.positionMs)
        assertEquals(true, merged.playing)
        assertEquals(true, merged.playWhenReady)
        // Everything structural is untouched.
        assertEquals(stored.queue, merged.queue)
        assertEquals(stored.speed, merged.speed)
    }

    @Test
    fun `progress overlay is ignored without a match and clamps negatives`() {
        val stored = storedSession(positionMs = 1_000L)

        assertEquals(stored, stored.withProgressOverlay(null))
        assertEquals(
            stored,
            stored.withProgressOverlay(
                StoredNativePlaybackProgress("other", 9_000L, true, true)
            )
        )
        assertEquals(
            0L,
            stored.withProgressOverlay(
                StoredNativePlaybackProgress("session-1", -5L, false, false)
            ).positionMs
        )
    }

    @Test
    fun `progress only writes wait until a structural write has landed`() {
        val environment = FakeStatePersistenceEnvironment()
        var snapshots = listOf(storedSession(positionMs = 1_000L))
        val coordinator = coordinator(environment, storedSessions = { snapshots })

        // Structural write still queued on the storage thread.
        coordinator.persistNow()
        snapshots = listOf(storedSession(positionMs = 6_000L))
        coordinator.persistNow()
        environment.runBackgroundTasks()

        // Must not degrade to a progress-only write, or the queue would never
        // reach disk: the first structural write is dropped as superseded.
        assertEquals(0, environment.savedProgress.size)
        assertEquals(listOf(6_000L), environment.savedSessions.map { it.single().positionMs })
    }

    @Test
    fun `structural changes still write the full snapshot`() {
        val environment = FakeStatePersistenceEnvironment()
        var snapshots = listOf(storedSession(positionMs = 1_000L))
        val coordinator = coordinator(environment, storedSessions = { snapshots })

        coordinator.persistNow()
        environment.runBackgroundTasks()
        snapshots = listOf(storedSession(positionMs = 2_000L, speed = 1.5f))
        coordinator.persistNow()
        environment.runBackgroundTasks()

        assertEquals(2, environment.savedSessions.size)
        assertEquals(0, environment.savedProgress.size)
    }

    @Test
    fun `retired paused runtime publishes final position then leaves only the other runtime`() {
        val environment = FakeStatePersistenceEnvironment()
        val manager = NativePlaybackSessionManager { id -> NativePlaybackSession(id,
            createPlayer = { _, _ -> error("Cold sessions must not create a player") },
            logWarn = { _, _, _ -> }, elapsedRealtimeMs = { 1L }) }
        val paused = manager.getOrCreate("paused")
        val descriptor = NativeMediaItemDescriptor("/a.mp3", "file:///a.mp3", "A", null, null)
        paused.configure(descriptor, listOf(descriptor), 0, 22_000L, 1f, 1f,
            false, false, false, autoPlay = false, deferPlayerCreation = true)
        manager.getOrCreate("other")
        val coordinator = coordinator(environment, storedSessions = { manager.storedSnapshots(emptySet()) })
        val published = mutableListOf<Map<String, Any?>>()

        val response = manager.releaseIdleSession(paused, coordinator) { published += it.snapshot() }
        coordinator.persistNow()
        environment.runBackgroundTasks()

        assertEquals("idle", response["processingState"])
        assertEquals(22_000L, response["positionMs"])
        assertEquals(listOf(response), published)
        assertEquals(setOf("other"), manager.sessionIds)
        assertEquals(setOf("paused", "other"), environment.storedDefinitions.map { it.sessionId }.toSet())
        assertEquals(22_000L, environment.storedDefinitions.first { it.sessionId == "paused" }.positionMs)
    }

    @Test
    fun `writing B runtime keeps the exact paused A definition`() {
        val environment = FakeStatePersistenceEnvironment()
        val paused = storedSession(22_000L).copy(sessionId = "A", speed = 1.5f)
        environment.storedDefinitions = listOf(paused)
        val active = storedSession(9_000L).copy(sessionId = "B", playing = true, playWhenReady = true)
        val coordinator = coordinator(environment, storedSessions = { listOf(active) })

        coordinator.persistNow()
        environment.runBackgroundTasks()

        assertTrue(environment.storedDefinitions.first { it.sessionId == "A" } === paused)
        assertEquals(listOf("B"), environment.savedSessions.single().map { it.sessionId })
    }

    @Test
    fun `natural completion publishes completion once and retires runtime without retaining play intent`() {
        val environment = FakeStatePersistenceEnvironment()
        val manager = NativePlaybackSessionManager { id -> NativePlaybackSession(id,
            createPlayer = { _, _ -> error("Completed session must not allocate a player") },
            logWarn = { _, _, _ -> }, elapsedRealtimeMs = { 1L }) }
        val completed = manager.getOrCreate("completed")
        val descriptor = NativeMediaItemDescriptor("/a.mp3", "file:///a.mp3", "A", null, null)
        completed.configure(descriptor, listOf(descriptor), 0, 22_000L, 1f, 1f,
            false, false, false, autoPlay = false, deferPlayerCreation = true)
        completed.lastPlaybackState = "completed"
        completed.lastPlayWhenReady = true // Media3 may retain this after STATE_ENDED.
        completed.snapshot()
        manager.updateProgressSession(completed.sessionId)
        assertTrue(manager.progressAnchors().isEmpty())
        val coordinator = coordinator(environment, storedSessions = { manager.storedSnapshots(emptySet()) })
        val published = mutableListOf<Map<String, Any?>>()

        val response = manager.releaseIdleSession(completed, coordinator, "completed") { published += it.snapshot() }
        environment.runBackgroundTasks()

        assertEquals(listOf(response), published)
        assertEquals("completed", response["processingState"])
        assertEquals(false, response["playWhenReady"])
        assertEquals(false, response["playing"])
        assertEquals(22_000L, response["positionMs"])
        assertTrue(manager.isEmpty)
        assertTrue(manager.progressAnchors().isEmpty())
        assertEquals(false, environment.storedDefinitions.single().playWhenReady)
        assertEquals(true, environment.storedDefinitions.single().completed)
        assertEquals(22_000L, environment.storedDefinitions.single().positionMs)
    }

    @Test
    fun `late retired write cannot override newer cold selection or resurrect a removed definition`() {
        val environment = FakeStatePersistenceEnvironment(filterRevisions = true)
        val old = storedSession(1_000L).copy(sessionId = "retired-race")
        val coordinator = coordinator(environment, storedSessions = { emptyList() })
        val oldRevision = NativePlaybackStateStore.sessionRevision(old.sessionId)
        coordinator.persistSession(old, oldRevision)
        val newer = old.copy(path = "/new.mp3", uri = "file:///new.mp3", positionMs = 22_000L)
        NativePlaybackStateStore.invalidateSession(old.sessionId)
        environment.storedDefinitions = listOf(newer)
        environment.runBackgroundTasks()
        assertEquals(listOf(newer), environment.storedDefinitions)
        assertTrue(environment.savedSessions.isEmpty())

        coordinator.persistSession(old, NativePlaybackStateStore.sessionRevision(old.sessionId))
        coordinator.removeSession(old.sessionId)
        environment.runBackgroundTasks()
        assertTrue(environment.storedDefinitions.isEmpty())
        assertTrue(environment.savedSessions.isEmpty())
    }

    @Test
    fun `new prepare version rejects old runtime progress while B still persists`() {
        val environment = FakeStatePersistenceEnvironment(filterRevisions = true)
        val a = storedSession(5_000L).copy(sessionId = "progress-race-A")
        val b = a.copy(sessionId = "progress-race-B")
        val revisions = listOf(a, b).associate { it.sessionId to NativePlaybackStateStore.sessionRevision(it.sessionId) }
        var snapshots = listOf(a, b)
        val coordinator = NativePlaybackStatePersistenceCoordinator(environment, 10_000L, 800L,
            { true }, { true }, { snapshots }, { revisions })
        coordinator.persistNow()
        environment.runBackgroundTasks()
        snapshots = listOf(a.copy(positionMs = 6_000L), b.copy(positionMs = 7_000L))
        coordinator.persistNow()
        NativePlaybackStateStore.invalidateSession(a.sessionId)
        environment.runBackgroundTasks()

        assertEquals(listOf(b.sessionId), environment.savedProgress.single().map { it.sessionId })
        assertEquals(5_000L, environment.storedDefinitions.first { it.sessionId == a.sessionId }.positionMs)
        assertEquals(7_000L, environment.storedDefinitions.first { it.sessionId == b.sessionId }.positionMs)
    }

    private fun coordinator(
        environment: FakeStatePersistenceEnvironment,
        hasSessions: () -> Boolean = { true },
        hasActivePlayback: () -> Boolean = { true },
        storedSessions: () -> List<StoredNativePlaybackSession>
    ) = NativePlaybackStatePersistenceCoordinator(
        environment = environment,
        intervalMs = 10_000L,
        debounceMs = 800L,
        hasSessions = hasSessions,
        hasActivePlayback = hasActivePlayback,
        storedSessions = storedSessions
    )
}

private class FakeStatePersistenceEnvironment(private val filterRevisions: Boolean = false) : NativePlaybackStatePersistenceEnvironment {
    val delayedTasks = linkedMapOf<Runnable, Long>()
    val backgroundTasks = mutableListOf<() -> Unit>()
    val savedSessions = mutableListOf<List<StoredNativePlaybackSession>>()
    val savedProgress = mutableListOf<List<StoredNativePlaybackProgress>>()
    var clearCount = 0
    var shutdownCalled = false
    var storedDefinitions = emptyList<StoredNativePlaybackSession>()

    override fun postDelayed(runnable: Runnable, delayMs: Long) {
        delayedTasks[runnable] = delayMs
    }

    override fun removeCallbacks(runnable: Runnable) {
        delayedTasks.remove(runnable)
    }

    override fun execute(task: () -> Unit) {
        backgroundTasks += task
    }

    override fun saveSessions(sessions: List<StoredNativePlaybackSession>, revisions: Map<String, Long>) {
        val accepted = sessions.filter { !filterRevisions || revisions[it.sessionId] == NativePlaybackStateStore.sessionRevision(it.sessionId) }
        if (accepted.isEmpty()) return
        savedSessions += accepted
        storedDefinitions = mergeNativePlaybackDefinitions(storedDefinitions, accepted)
    }

    override fun saveSessionProgress(progress: List<StoredNativePlaybackProgress>, revisions: Map<String, Long>) {
        val accepted = progress.filter { !filterRevisions || revisions[it.sessionId] == NativePlaybackStateStore.sessionRevision(it.sessionId) }
        if (accepted.isEmpty()) return
        savedProgress += accepted
        storedDefinitions = storedDefinitions.map { stored -> stored.withProgressOverlay(accepted.firstOrNull { it.sessionId == stored.sessionId }) }
    }

    override fun removeSession(sessionId: String, revision: Long) {
        if (!filterRevisions || revision == NativePlaybackStateStore.sessionRevision(sessionId))
            storedDefinitions = storedDefinitions.filterNot { it.sessionId == sessionId }
    }

    override fun clearSessions(revision: Long) {
        clearCount += 1
        storedDefinitions = storedDefinitions.filter { NativePlaybackStateStore.sessionRevision(it.sessionId) > revision }
    }

    override fun shutdown() {
        shutdownCalled = true
    }

    fun runBackgroundTasks() {
        while (backgroundTasks.isNotEmpty()) {
            backgroundTasks.removeAt(0).invoke()
        }
    }
}

private fun storedSession(
    positionMs: Long,
    speed: Float = 1f
) = StoredNativePlaybackSession(
    sessionId = "session-1",
    uri = "file:///music/track.mp3",
    path = "/music/track.mp3",
    title = "Track",
    subtitle = null,
    artUri = null,
    positionMs = positionMs,
    volume = 1f,
    speed = speed,
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
    queue = emptyList(),
    channelSwapEnabled = false,
    playing = false,
    playWhenReady = false
)
