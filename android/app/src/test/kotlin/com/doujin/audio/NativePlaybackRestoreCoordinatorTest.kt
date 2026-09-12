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

        assertEquals(listOf("paused"), restored)
    }

    @Test
    fun `notification restore uses provided snapshot and reports restored session`() {
        val environment = FakeRestoreEnvironment()
        val restored = mutableListOf<String>()
        val coordinator = coordinator(
            environment,
            onNotificationSessionRestored = restored::add
        )
        coordinator.restoreSessionForNotification(
            sessionId = "notification",
            loadedSessions = listOf(storedSession("other"), storedSession("notification")),
            sessionExists = false
        )
        assertEquals(listOf("notification"), restored)
        assertEquals(0, environment.loadCount)
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
        onNotificationSessionRestored: (String) -> Unit = {},
        startBootstrap: () -> NativePlaybackForegroundStartResult = {
            NativePlaybackForegroundStartResult.STARTED
        }
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
        onNotificationSessionRestored = onNotificationSessionRestored,
        logInfo = {}
    )
}

private class FakeRestoreEnvironment : NativePlaybackRestoreEnvironment {
    var sessions = emptyList<StoredNativePlaybackSession>()
    var loadCount = 0
    private val background = ArrayDeque<() -> Unit>()
    private val main = ArrayDeque<() -> Unit>()
    override fun loadSessions(): List<StoredNativePlaybackSession> {
        loadCount += 1
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
