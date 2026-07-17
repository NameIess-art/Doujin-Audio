package com.nameless.audio

import com.nameless.audio.player.session.NativePlaybackStatePersistenceCoordinator
import com.nameless.audio.player.session.NativePlaybackStatePersistenceEnvironment
import com.nameless.audio.player.session.StoredNativePlaybackSession
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
    fun `shutdown clears persisted sessions when no sessions remain`() {
        val environment = FakeStatePersistenceEnvironment()
        val coordinator = coordinator(
            environment,
            hasSessions = { false },
            storedSessions = { error("No snapshots should be captured") }
        )

        coordinator.shutdown()
        environment.runBackgroundTasks()

        assertEquals(1, environment.clearCount)
        assertTrue(environment.savedSessions.isEmpty())
    }

    private fun coordinator(
        environment: FakeStatePersistenceEnvironment,
        hasSessions: () -> Boolean = { true },
        storedSessions: () -> List<StoredNativePlaybackSession>
    ) = NativePlaybackStatePersistenceCoordinator(
        environment = environment,
        intervalMs = 10_000L,
        debounceMs = 800L,
        hasSessions = hasSessions,
        storedSessions = storedSessions
    )
}

private class FakeStatePersistenceEnvironment : NativePlaybackStatePersistenceEnvironment {
    val delayedTasks = linkedMapOf<Runnable, Long>()
    val backgroundTasks = mutableListOf<() -> Unit>()
    val savedSessions = mutableListOf<List<StoredNativePlaybackSession>>()
    var clearCount = 0
    var shutdownCalled = false

    override fun postDelayed(runnable: Runnable, delayMs: Long) {
        delayedTasks[runnable] = delayMs
    }

    override fun removeCallbacks(runnable: Runnable) {
        delayedTasks.remove(runnable)
    }

    override fun execute(task: () -> Unit) {
        backgroundTasks += task
    }

    override fun saveSessions(sessions: List<StoredNativePlaybackSession>) {
        savedSessions += sessions
    }

    override fun clearSessions() {
        clearCount += 1
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

private fun storedSession(positionMs: Long) = StoredNativePlaybackSession(
    sessionId = "session-1",
    uri = "file:///music/track.mp3",
    path = "/music/track.mp3",
    title = "Track",
    subtitle = null,
    artUri = null,
    positionMs = positionMs,
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
    queue = emptyList(),
    channelSwapEnabled = false,
    playing = false,
    playWhenReady = false
)
