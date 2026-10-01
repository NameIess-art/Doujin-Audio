package com.doujin.audio

import com.doujin.audio.player.service.*
import com.doujin.audio.player.session.StoredNativePlaybackSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackRestoreCoordinatorTest {
    @Test
    fun `new restore generation discards stale main-thread completion`() {
        val environment = FakeRestoreEnvironment()
        val restoredBatches = mutableListOf<List<String>>()
        val coordinator = coordinator(environment, completeRestore = { ids ->
            restoredBatches += ids
        })
        environment.sessions = listOf(storedSession("first"))
        coordinator.restoreAfterServiceRestart(startId = 1)
        environment.runBackground()
        environment.sessions = listOf(storedSession("second"))
        coordinator.restoreAfterServiceRestart(startId = 2)
        environment.runBackground()
        environment.runMain()
        assertEquals(listOf(listOf("second")), restoredBatches)
    }

    @Test
    fun `empty restore defers idle exit until command deliveries settle`() {
        val environment = FakeRestoreEnvironment()
        var pendingDelivery = true
        val stops = mutableListOf<Pair<Int, String>>()
        val coordinator = coordinator(
            environment,
            hasPendingCommandDelivery = { pendingDelivery },
            stopIdleService = { startId, reason -> stops += startId to reason }
        )
        coordinator.acceptStart(41)
        coordinator.restoreAfterServiceRestart(startId = 41)
        environment.runAll()
        assertTrue(stops.isEmpty())
        pendingDelivery = false
        coordinator.onPendingCommandDeliveriesSettled()
        environment.runMain()
        assertEquals(listOf(41 to "sticky_restore_empty"), stops)
    }

    @Test
    fun `timer restore loads only missing requested sessions without autoplay`() {
        val environment = FakeRestoreEnvironment().apply {
            sessions = listOf(storedSession("existing"), storedSession("missing"))
        }
        val restored = mutableListOf<String>()
        val autoPlayValues = mutableListOf<Boolean>()
        val coordinator = coordinator(
            environment,
            restore = { stored, autoPlay, onRestored ->
                stored.map { session ->
                    autoPlayValues += autoPlay(session)
                    onRestored(session.sessionId)
                    session.sessionId
                }
            },
            onMissingSessionsRestored = restored::addAll
        )
        coordinator.restoreMissingSessions(
            sessionIds = listOf("existing", "missing"),
            existingSessionIds = setOf("existing")
        )
        assertEquals(0, environment.loadCount)
        assertTrue(restored.isEmpty())
        environment.runAll()
        assertEquals(listOf("missing"), restored)
        assertEquals(listOf(false), autoPlayValues)
    }

    @Test
    fun `manual playback restore loads a persisted paused session`() {
        val environment = FakeRestoreEnvironment().apply {
            sessions = listOf(
                storedSession("paused").copy(playing = false, playWhenReady = false)
            )
        }
        val restored = mutableListOf<String>()
        val coordinator = coordinator(
            environment,
            restore = { stored, autoPlay, _ ->
                stored.map { session ->
                    assertEquals(false, autoPlay(session))
                    session.sessionId
                }
            },
            onMissingSessionsRestored = restored::addAll
        )

        coordinator.restoreMissingSessions(
            sessionIds = listOf("paused"),
            existingSessionIds = emptySet()
        )
        environment.runAll()
        assertEquals(listOf("paused"), restored)
    }

    @Test
    fun `removal cancels missing-session disk restore and its playback continuation`() {
        val environment = FakeRestoreEnvironment().apply { sessions = listOf(storedSession("removed")) }
        val restored = mutableListOf<String>()
        var accepted: Boolean? = null
        val coordinator = coordinator(environment, onMissingSessionsRestored = restored::addAll)
        coordinator.restoreMissingSessions(listOf("removed"), emptySet()) { accepted = it }
        coordinator.excludeSessionFromRestartRestore("removed")
        environment.runAll()
        assertTrue(restored.isEmpty())
        assertEquals(false, accepted)
    }

    @Test
    fun `new live session is preserved during missing-session disk restore`() {
        val environment = FakeRestoreEnvironment().apply { sessions = listOf(storedSession("live")) }
        val states = mutableSetOf<String>()
        val restored = mutableListOf<String>()
        val coordinator = coordinator(environment, sessionExists = states::contains,
            onMissingSessionsRestored = restored::addAll)
        coordinator.restoreMissingSessions(listOf("live"), emptySet())
        states.add("live")
        environment.runAll()
        assertTrue(restored.isEmpty())
    }

    @Test
    fun `restore after service restart restores snapshot without autoplay`() {
        val environment = FakeRestoreEnvironment().apply {
            sessions = listOf(storedSession("player"))
        }
        val autoPlayValues = mutableListOf<Boolean>()
        val coordinator = coordinator(
            environment = environment,
            restore = { stored, autoPlay, _ ->
                stored.map { session ->
                    autoPlayValues += autoPlay(session)
                    session.sessionId
                }
            },
            startBootstrap = { NativePlaybackForegroundStartResult.STARTED }
        )

        coordinator.restoreAfterServiceRestart(startId = 1)
        environment.runAll()

        assertEquals(listOf(false), autoPlayValues)
    }

    @Test
    fun `live session created during disk load keeps its queue and playback state`() {
        val environment = FakeRestoreEnvironment().apply {
            sessions = listOf(storedSession("live"), storedSession("other"))
        }
        val sessionStates = mutableMapOf<String, String>()
        var resetCount = 0
        val coordinator = coordinator(
            environment,
            sessionExists = sessionStates::containsKey,
            resetRestoreState = { resetCount++ },
            restore = { stored, _, _ ->
                stored.map { sessionStates[it.sessionId] = "old paused queue"; it.sessionId }
            }
        )

        coordinator.restoreAfterServiceRestart(1)
        sessionStates["live"] = "new playing queue at 30000"
        environment.runAll()

        assertEquals("new playing queue at 30000", sessionStates["live"])
        assertEquals("old paused queue", sessionStates["other"])
        assertEquals(0, resetCount)
    }

    @Test
    fun `live session created between restore steps is skipped while others restore`() {
        val environment = FakeRestoreEnvironment().apply {
            sessions = listOf(storedSession("first"), storedSession("live"), storedSession("last"))
        }
        val sessionStates = mutableMapOf<String, String>()
        val completed = mutableListOf<String>()
        val coordinator = coordinator(
            environment,
            sessionExists = sessionStates::containsKey,
            restore = { stored, _, _ ->
                stored.map { sessionStates[it.sessionId] = "paused"; it.sessionId }
            },
            completeRestore = completed::addAll
        )

        coordinator.restoreAfterServiceRestart(1)
        environment.runBackground()
        environment.runNextMain()
        sessionStates["first"] = "playing at 40000"
        sessionStates["live"] = "prepared at 90000"
        environment.runMain()

        assertEquals("playing at 40000", sessionStates["first"])
        assertEquals("prepared at 90000", sessionStates["live"])
        assertEquals("paused", sessionStates["last"])
        assertEquals(listOf("first", "last"), completed)
    }

    @Test
    fun `session removed during disk load is not recreated`() {
        val environment = FakeRestoreEnvironment().apply {
            sessions = listOf(storedSession("removed"), storedSession("other"))
        }
        val restored = mutableListOf<String>()
        val coordinator = coordinator(environment, completeRestore = restored::addAll)

        coordinator.restoreAfterServiceRestart(1)
        coordinator.excludeSessionFromRestartRestore("removed")
        environment.runAll()

        assertEquals(listOf("other"), restored)
    }

    @Test
    fun `global stop cancels pending restore and completion`() {
        for (stopDuringDiskLoad in listOf(true, false)) {
            val environment = FakeRestoreEnvironment().apply {
                sessions = listOf(storedSession("first"), storedSession("second"))
            }
            val restored = mutableListOf<String>()
            var completed = false
            val coordinator = coordinator(
                environment,
                restore = { stored, _, _ -> stored.map { restored += it.sessionId; it.sessionId } },
                completeRestore = { completed = true }
            )

            coordinator.restoreAfterServiceRestart(1)
            if (!stopDuringDiskLoad) {
                environment.runBackground()
                environment.runNextMain()
            }
            coordinator.cancelRestartRestore()
            environment.runAll()

            assertEquals(if (stopDuringDiskLoad) emptyList<String>() else listOf("first"), restored)
            assertEquals(false, completed)
        }
    }

    @Test
    fun `missing session load failure completes on main without restoring`() {
        val environment = FakeRestoreEnvironment().apply { loadFailure = IllegalStateException("Disk failure") }
        var accepted: Boolean? = null
        var restorations = 0
        val coordinator = coordinator(environment, restore = { _, _, _ -> restorations += 1; emptyList() })
        coordinator.restoreMissingSessions(listOf("session"), emptySet()) { accepted = it }
        environment.runBackground()
        assertEquals(null, accepted)
        environment.runMain()
        assertEquals(false, accepted)
        assertEquals(0, restorations)
    }

    @Test
    fun `queue preparation failure discards partial structures and returns the error`() {
        val environment = FakeRestoreEnvironment().apply { sessions = listOf(storedSession("session")) }
        val failure = IllegalStateException("Invalid queue")
        val discarded = mutableListOf<String>()
        val failures = mutableListOf<Throwable>()
        var completed = false
        val coordinator = coordinator(environment,
            prepareQueues = { throw failure }, discardQueues = { discarded += it.map { session -> session.sessionId } })
        coordinator.restoreMissingSessions(listOf("session"), emptySet(), onFailure = failures::add) {
            completed = true
        }
        environment.runAll()
        assertEquals(listOf(failure), failures)
        assertEquals(listOf("session"), discarded)
        assertEquals(false, completed)
    }

    @Test
    fun `shutdown settles queued timer restoration once`() {
        val environment = FakeRestoreEnvironment().apply { sessions = listOf(storedSession("session")) }
        val coordinator = coordinator(environment)
        val completed = mutableListOf<String>()
        coordinator.restoreMissingSessions(listOf("session"), emptySet()) {
            assertEquals(false, it)
            completed += "timer"
        }
        coordinator.shutdown()
        environment.runAll()
        assertEquals(listOf("timer"), completed)
    }

    private fun coordinator(
        environment: FakeRestoreEnvironment,
        restore: (
            List<StoredNativePlaybackSession>,
            (StoredNativePlaybackSession) -> Boolean,
            (String) -> Unit
        ) -> List<String> = { stored, _, onRestored ->
            stored.map { onRestored(it.sessionId); it.sessionId }
        },
        hasPendingCommandDelivery: () -> Boolean = { false },
        stopIdleService: (Int, String) -> Unit = { _, _ -> },
        completeRestore: (List<String>) -> Unit = {},
        sessionExists: (String) -> Boolean = { false },
        resetRestoreState: () -> Unit = {},
        onMissingSessionsRestored: (List<String>) -> Unit = {},
        startBootstrap: () -> NativePlaybackForegroundStartResult = {
            NativePlaybackForegroundStartResult.STARTED
        },
        prepareQueues: (List<StoredNativePlaybackSession>) -> Unit = {},
        discardQueues: (List<StoredNativePlaybackSession>) -> Unit = {}
    ) = NativePlaybackRestoreCoordinator(
        environment = environment,
        restoreSessions = restore,
        startBootstrap = startBootstrap,
        resetRestoreState = resetRestoreState,
        completeRestore = completeRestore,
        sessionExists = sessionExists,
        hasSessions = { environment.sessions.any { sessionExists(it.sessionId) } },
        hasPlaybackToKeepAlive = { false },
        hasPendingCommandDelivery = hasPendingCommandDelivery,
        stopIdleService = stopIdleService,
        onMissingSessionsRestored = onMissingSessionsRestored,
        logInfo = {},
        prepareSessionsOnBackground = prepareQueues,
        discardPreparedSessions = discardQueues
    )
}

private class FakeRestoreEnvironment : NativePlaybackRestoreEnvironment {
    var sessions = emptyList<StoredNativePlaybackSession>()
    var loadCount = 0
    var loadFailure: Throwable? = null
    private val background = ArrayDeque<() -> Unit>()
    private val main = ArrayDeque<() -> Unit>()
    override fun loadSessions(): List<StoredNativePlaybackSession> {
        loadCount += 1
        loadFailure?.let { throw it }
        return sessions
    }
    override fun executeBackground(task: () -> Unit) { background += task }
    override fun postMain(task: () -> Unit) { main += task }
    override fun shutdown() { background.clear(); main.clear() }
    fun runBackground() { while (background.isNotEmpty()) background.removeFirst().invoke() }
    fun runNextMain() { main.removeFirst().invoke() }
    fun runMain() { while (main.isNotEmpty()) main.removeFirst().invoke() }
    fun runAll() { runBackground(); runMain() }
}

private fun storedSession(sessionId: String) = StoredNativePlaybackSession(
    sessionId = sessionId,
    uri = "file:///$sessionId.mp3",
    path = "/$sessionId.mp3",
    title = sessionId,
    subtitle = null,
    artUri = null,
    positionMs = 0L,
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
    playing = true,
    playWhenReady = true
)
