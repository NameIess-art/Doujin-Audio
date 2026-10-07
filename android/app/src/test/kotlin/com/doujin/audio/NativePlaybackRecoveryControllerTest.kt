package com.doujin.audio

import com.doujin.audio.player.recovery.*
import com.doujin.audio.player.session.*

import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackRecoveryControllerTest {
    @Test
    fun `explicit retry can reprepare an intended session without a pending error`() {
        val environment = FakeRecoveryEnvironment()
        var playerCreations = 0
        val session = NativePlaybackSession("player", createPlayer = { _, _ ->
            playerCreations++
            error("No native player in a JVM test")
        }, logWarn = { _, _, _ -> }, elapsedRealtimeMs = { environment.now })
        val item = NativeMediaItemDescriptor("/track.mp3", "file:///track.mp3", "Track", null, null)
        session.configure(item, listOf(item), 0, 8_000L, 1f, 1f,
            repeatOne = false, repeatAll = false, shuffleModeEnabled = false,
            autoPlay = true, deferPlayerCreation = true)
        val controller = NativePlaybackRecoveryController(FakeRecoveryHost(session), environment)
        controller.markIntended("player")

        controller.retryNow("player", "user_retry")

        assertEquals(1, playerCreations)
        assertEquals(8_000L, session.lastPositionMs)
        assertFalse(controller.isRecovering("player"))
    }

    @Test
    fun `candidate preparation defers long queue mutation and keeps current position`() {
        val environment = FakeRecoveryEnvironment()
        val session = candidateSession(environment, count = 5_000)
        val host = FakeRecoveryHost(session).apply { deferPreparation = true }
        val controller = NativePlaybackRecoveryController(host, environment)
        startCandidateRetry(controller)

        assertTrue(controller.isRecovering("player"))
        assertEquals("https://one/2750.mp3", session.uri)
        assertEquals(8_000L, session.lastPositionMs)
        val preparedDescriptors = host.preparationQueues.single()
        assertEquals(5_000, preparedDescriptors.size)
        assertEquals("https://two/2750.mp3", preparedDescriptors[2750].uri)
        assertEquals("https://one/2749.mp3", preparedDescriptors[2749].uri)
        controller.retryNow("player", "duplicate_retry")
        assertEquals(1, host.preparationQueues.size)

        host.completePreparation()

        assertFalse(controller.isRecovering("player"))
        assertEquals("https://two/2750.mp3", session.uri)
        val stored = session.storedSnapshot()
        assertEquals(8_000L, stored.positionMs)
        assertEquals(2750, stored.queueStartIndex)
        assertEquals(5_000, stored.queue.size)
        assertTrue(stored.playWhenReady)
    }

    @Test
    fun `paused removed replaced or retargeted sessions reject late candidate preparation`() {
        val invalidations = listOf<(NativePlaybackRecoveryController, NativePlaybackSession,
            MutableMap<String, NativePlaybackSession>, FakeRecoveryEnvironment) -> Unit>(
            { controller, _, _, _ -> controller.clear("player") },
            { controller, _, _, _ -> controller.clearAll() },
            { controller, _, _, _ -> controller.resetHealth("player", "skip_next", cancelRecovery = true) },
            { _, _, sessions, _ -> sessions.remove("player") },
            { _, _, sessions, environment -> sessions["player"] = candidateSession(environment) },
            { _, session, _, _ -> session.queueRevision++ },
            { _, session, _, _ -> session.definitionRevision++ },
            { _, session, _, _ -> session.transportCommandId++ },
            { _, session, _, _ -> session.uri = "https://one/replaced.mp3" }
        )
        invalidations.forEachIndexed { index, invalidate ->
            val environment = FakeRecoveryEnvironment()
            val session = candidateSession(environment)
            val sessions = mutableMapOf("player" to session)
            val host = FakeRecoveryHost(playbackSessions = sessions).apply { deferPreparation = true }
            val controller = NativePlaybackRecoveryController(host, environment)
            startCandidateRetry(controller)
            invalidate(controller, session, sessions, environment)
            val expectedUri = session.uri

            host.completePreparation()

            assertEquals("invalidation $index", expectedUri, session.uri)
            assertFalse("invalidation $index", controller.isRecovering("player"))
        }
    }

    @Test
    fun `old candidate completion cannot end a newer recovery for the same session`() {
        val environment = FakeRecoveryEnvironment()
        val session = candidateSession(environment)
        val host = FakeRecoveryHost(session).apply { deferPreparation = true }
        val controller = NativePlaybackRecoveryController(host, environment)
        startCandidateRetry(controller)
        controller.clear("player")
        startCandidateRetry(controller)

        host.completePreparation()

        assertTrue(controller.isRecovering("player"))
        assertEquals("https://one/0.mp3", session.uri)
        host.completePreparation()
        assertEquals("https://two/0.mp3", session.uri)
        assertFalse(controller.isRecovering("player"))
    }

    @Test
    fun `advancing to an identical queue occurrence rejects the previous candidate preparation`() {
        val environment = FakeRecoveryEnvironment()
        val session = recoverySession(environment)
        val item = NativeMediaItemDescriptor("/track.mp3", "https://one/track.mp3", "Track", null, null)
            .withPlaybackCandidateUris(listOf("https://one/track.mp3", "https://two/track.mp3"))
        session.configure(item, listOf(item, item), 0, 8_000L, 1f, 1f,
            repeatOne = false, repeatAll = false, shuffleModeEnabled = false,
            autoPlay = true, deferPlayerCreation = true)
        val host = FakeRecoveryHost(session).apply { deferPreparation = true }
        val controller = NativePlaybackRecoveryController(host, environment)
        startCandidateRetry(controller)
        session.skipQueue(forward = true)

        host.completePreparation()

        assertEquals(1, session.queueIndex)
        assertEquals("https://one/track.mp3", session.uri)
        assertEquals(0L, session.lastPositionMs)
        assertFalse(controller.isRecovering("player"))
    }

    @Test
    fun `focus interruption during candidate preparation defers mutation until recovery resumes`() {
        val environment = FakeRecoveryEnvironment()
        val session = candidateSession(environment)
        val host = FakeRecoveryHost(session).apply { deferPreparation = true }
        val controller = NativePlaybackRecoveryController(host, environment)
        startCandidateRetry(controller)
        host.interruptionActive = true

        host.completePreparation()

        assertEquals("https://one/0.mp3", session.uri)
        assertTrue(controller.isIntended("player"))
        assertFalse(controller.isRecovering("player"))
        host.interruptionActive = false
        controller.retryNow("player", "focus_returned")
        host.completePreparation()
        assertEquals("https://two/0.mp3", session.uri)
    }

    @Test
    fun `candidate completion after the recovery budget expires cannot resume playback`() {
        val environment = FakeRecoveryEnvironment()
        val session = candidateSession(environment)
        val host = FakeRecoveryHost(session).apply { deferPreparation = true }
        val controller = NativePlaybackRecoveryController(host, environment, maxRecoveryDurationMs = 10_000L)
        startCandidateRetry(controller)
        environment.now = 10_001L

        host.completePreparation()

        assertEquals("https://one/0.mp3", session.uri)
        assertEquals(listOf("player"), host.recoveryTimeouts)
        assertFalse(controller.isIntended("player"))
        assertFalse(controller.isRecovering("player"))
    }

    @Test
    fun `old retry cannot execute or remove a replacement retry after the same session is restarted`() {
        val environment = FakeRecoveryEnvironment()
        val host = FakeRecoveryHost(recoverySession(environment))
        val controller = NativePlaybackRecoveryController(host, environment)
        fun scheduleError() {
            controller.markIntended("player")
            controller.onPlayerError(
                sessionId = "player", recoverable = true,
                errorCodeName = "ERROR_CODE_IO_NETWORK_CONNECTION_FAILED",
                errorMessage = "network", causeDescription = null
            )
        }
        scheduleError()
        val oldRetry = environment.tasks.entries.first { it.value == 2_000L }.key
        controller.clear("player")
        scheduleError()

        oldRetry.run()

        assertEquals(0, host.requestAudioFocusCalls)
        assertTrue(controller.isIntended("player"))
        assertTrue(controller.isPending("player"))
        assertTrue(environment.delays.contains(2_000L))
        controller.clearAll()
        assertTrue(environment.tasks.isEmpty())
    }

    @Test
    fun `scheduled retry preserves intent through a transient focus interruption longer than recovery budget`() {
        val environment = FakeRecoveryEnvironment()
        val host = FakeRecoveryHost(recoverySession(environment))
        var recovered = false
        host.onHealthSample = { _, nowMs ->
            NativePlaybackHealthSample(
                sessionId = "player", positionMs = if (recovered) 2_000L else 1_000L,
                bufferedPositionMs = 5_000L, durationMs = 120_000L, mediaItemIndex = 0,
                playbackState = Player.STATE_READY, playWhenReady = true, isPlaying = recovered,
                playbackSuppressionReason = Player.PLAYBACK_SUPPRESSION_REASON_NONE,
                hasPlayerError = !recovered, capturedElapsedRealtimeMs = nowMs
            )
        }
        val controller = NativePlaybackRecoveryController(
            host, environment, maxRecoveryDurationMs = 10_000L
        )
        controller.markIntended("player")
        controller.onPlayerError(
            sessionId = "player",
            recoverable = true,
            errorCodeName = "ERROR_CODE_IO_NETWORK_CONNECTION_FAILED",
            errorMessage = "network",
            causeDescription = null
        )
        host.interruptionActive = true

        environment.runFirst(2_000L)

        assertTrue(controller.isIntended("player"))
        assertTrue(controller.isPending("player"))
        assertEquals(0, host.requestAudioFocusCalls)
        assertTrue(environment.delays.all { it >= 15_000L })
        repeat(4) { environment.runFirst(15_000L) }
        assertTrue(controller.isIntended("player"))
        assertTrue(host.recoveryTimeouts.isEmpty())

        host.interruptionActive = false
        recovered = true
        environment.runFirst(15_000L)

        assertTrue(controller.isIntended("player"))
        assertFalse(controller.isPending("player"))
        assertTrue(host.recoveryTimeouts.isEmpty())
    }

    @Test
    fun `external recovery trigger during ducking preserves intended playback`() {
        val environment = FakeRecoveryEnvironment()
        val host = FakeRecoveryHost(recoverySession(environment)).apply { interruptionActive = true }
        val controller = NativePlaybackRecoveryController(host, environment)
        controller.markIntended("player")

        controller.trigger("network_available")

        assertTrue(controller.isIntended("player"))
        assertEquals(0, host.requestAudioFocusCalls)
    }

    @Test
    fun `user stop clears deferred recovery during transient focus interruption`() {
        val environment = FakeRecoveryEnvironment()
        val host = FakeRecoveryHost(recoverySession(environment)).apply { interruptionActive = true }
        val controller = NativePlaybackRecoveryController(host, environment)
        controller.markIntended("player")
        controller.onPlayerError(
            sessionId = "player", recoverable = true,
            errorCodeName = "ERROR_CODE_IO_NETWORK_CONNECTION_FAILED",
            errorMessage = "network", causeDescription = null
        )

        controller.clear("player")

        assertFalse(controller.isIntended("player"))
        assertFalse(controller.isPending("player"))
        assertTrue(environment.tasks.isEmpty())
        assertFalse(environment.listening)
    }

    @Test
    fun `health checks isolate a stalled session from progressing sessions`() {
        val environment = FakeRecoveryEnvironment()
        val host = FakeRecoveryHost()
        var stalledRecovered = false
        host.onHealthSample = { sessionId, nowMs ->
            NativePlaybackHealthSample(
                sessionId = sessionId,
                positionMs = if (sessionId == "healthy" || stalledRecovered) {
                    nowMs
                } else {
                    1_000L
                },
                bufferedPositionMs = 5_000L,
                durationMs = 120_000L,
                mediaItemIndex = 0,
                playbackState = Player.STATE_READY,
                playWhenReady = true,
                isPlaying = sessionId == "healthy" || stalledRecovered,
                playbackSuppressionReason = Player.PLAYBACK_SUPPRESSION_REASON_NONE,
                hasPlayerError = false,
                capturedElapsedRealtimeMs = nowMs
            )
        }
        val controller = NativePlaybackRecoveryController(
            host = host,
            environment = environment,
            healthCheckIntervalMs = 15_000L
        )
        controller.markIntended("stalled")
        controller.markIntended("healthy")

        environment.runFirst(15_000L)
        environment.runFirst(15_000L)
        environment.runFirst(15_000L)

        assertTrue(controller.isPending("stalled"))
        assertFalse(controller.isPending("healthy"))
        assertTrue(environment.delays.contains(2_000L))

        stalledRecovered = true
        environment.runFirst(15_000L)

        assertFalse(controller.isPending("stalled"))
        assertTrue(controller.isIntended("stalled"))
        assertFalse(environment.delays.contains(2_000L))
    }

    @Test
    fun foregroundSyncCannotReenterAnActiveRecoveryTrigger() {
        val environment = FakeRecoveryEnvironment()
        val host = FakeRecoveryHost()
        val controller = NativePlaybackRecoveryController(host, environment)
        host.onRequestAudioFocus = { controller.trigger("foreground_sync") }
        controller.markIntended("player")

        controller.trigger("network_available")

        assertEquals(1, host.requestAudioFocusCalls)
    }

    @Test
    fun recoverableErrorSchedulesRetryWithinBoundedWindow() {
        val environment = FakeRecoveryEnvironment()
        val host = FakeRecoveryHost(recoverySession(environment))
        val controller = NativePlaybackRecoveryController(host, environment)
        controller.markIntended("player")

        controller.onPlayerError(
            sessionId = "player",
            recoverable = true,
            errorCodeName = "ERROR_CODE_IO_NETWORK_CONNECTION_FAILED",
            errorMessage = "network",
            causeDescription = null
        )

        assertTrue(controller.isIntended("player"))
        assertTrue(controller.isPending("player"))
        assertTrue(environment.listening)
        assertEquals(listOf(2_000L, 15_000L), environment.delays.sorted())
        assertTrue(controller.shouldKeepAlive())
    }

    @Test
    fun `recoverable playback error times out and releases keep alive responsibility`() {
        val environment = FakeRecoveryEnvironment()
        val host = FakeRecoveryHost(recoverySession(environment))
        val controller = NativePlaybackRecoveryController(
            host = host,
            environment = environment,
            maxRecoveryDurationMs = 10_000L
        )
        controller.markIntended("player")
        controller.onPlayerError(
            sessionId = "player",
            recoverable = true,
            errorCodeName = "ERROR_CODE_IO_NETWORK_CONNECTION_FAILED",
            errorMessage = "network",
            causeDescription = null
        )

        environment.runFirst(2_000L)
        environment.runFirst(6_000L)
        environment.runFirst(2_000L)

        assertFalse(controller.isIntended("player"))
        assertFalse(controller.isPending("player"))
        assertFalse(controller.shouldKeepAlive())
        assertFalse(environment.listening)
        assertEquals(listOf("player"), host.recoveryTimeouts)
        assertTrue(environment.tasks.isEmpty())
    }

    @Test
    fun `nonrecoverable playback errors clear intent immediately`() {
        val environment = FakeRecoveryEnvironment()
        val host = FakeRecoveryHost()
        val controller = NativePlaybackRecoveryController(host, environment)
        controller.markIntended("player")

        controller.onPlayerError(
            sessionId = "player",
            recoverable = false,
            errorCodeName = "ERROR_CODE_IO_FILE_NOT_FOUND",
            errorMessage = "missing",
            causeDescription = null
        )

        assertFalse(controller.isIntended("player"))
        assertFalse(controller.isPending("player"))
        assertFalse(environment.listening)
        assertTrue(environment.tasks.isEmpty())
    }

    @Test
    fun `scheduled recovery stops before focus when foreground cannot be established`() {
        val environment = FakeRecoveryEnvironment()
        val host = FakeRecoveryHost(recoverySession(environment)).apply {
            foregroundPlaybackAllowed = false
        }
        val controller = NativePlaybackRecoveryController(host, environment)
        controller.markIntended("player")
        controller.onPlayerError(
            sessionId = "player",
            recoverable = true,
            errorCodeName = "ERROR_CODE_IO_NETWORK_CONNECTION_FAILED",
            errorMessage = "network",
            causeDescription = null
        )

        environment.runFirst(2_000L)

        assertEquals(0, host.requestAudioFocusCalls)
        assertFalse(controller.isIntended("player"))
        assertFalse(controller.isPending("player"))
    }

    @Test
    fun staleScheduledTasksAreRemovedWhenIntentIsCleared() {
        val environment = FakeRecoveryEnvironment()
        val controller = NativePlaybackRecoveryController(FakeRecoveryHost(), environment)
        controller.markIntended("player")
        controller.onPlayerError(
            sessionId = "player",
            recoverable = true,
            errorCodeName = "ERROR_CODE_IO_NETWORK_CONNECTION_FAILED",
            errorMessage = "network",
            causeDescription = null
        )

        controller.clear("player")

        assertTrue(environment.tasks.isEmpty())
        assertFalse(environment.listening)
        assertFalse(controller.isIntended("player"))
    }

    @Test
    fun `user retry advances playback candidate before repreparing`() {
        val environment = FakeRecoveryEnvironment()
        val session = NativePlaybackSession(
            sessionId = "player",
            createPlayer = { _, _ -> error("unused") },
            logWarn = { _, _, _ -> },
            elapsedRealtimeMs = { environment.now }
        )
        val descriptor = NativeMediaItemDescriptor(
            path = "asmr://work/track",
            uri = "https://api.asmr.one/audio.mp3",
            title = "Track",
            subtitle = null,
            artUri = null
        ).withPlaybackCandidateUris(
            listOf(
                "https://api.asmr.one/audio.mp3",
                "https://api.asmr-100.com/audio.mp3"
            )
        )
        session.configure(
            descriptor = descriptor,
            queue = listOf(descriptor),
            queueStartIndex = 0,
            startPositionMs = 8_000L,
            volume = 1f,
            speed = 1f,
            repeatOne = false,
            repeatAll = false,
            shuffleModeEnabled = false,
            autoPlay = true,
            deferPlayerCreation = true
        )
        val controller = NativePlaybackRecoveryController(
            FakeRecoveryHost(session),
            environment
        )
        controller.markIntended("player")

        controller.onPlayerError(
            sessionId = "player",
            recoverable = true,
            candidateFallbackEligible = true,
            errorCodeName = "ERROR_CODE_IO_BAD_HTTP_STATUS",
            errorMessage = "503",
            causeDescription = null
        )

        assertTrue(environment.delays.contains(0L))
        controller.retryNow("player", "user_retry")
        assertEquals("https://api.asmr-100.com/audio.mp3", session.uri)
        assertEquals("asmr://work/track", session.path)
        assertEquals(8_000L, session.lastPositionMs)
        val snapshot = session.storedSnapshot()
        assertEquals(1, snapshot.queue.size)
        assertEquals("https://api.asmr-100.com/audio.mp3", snapshot.queue.single().uri)
        assertTrue(snapshot.playWhenReady)
    }

    @Test
    fun `clearing playback intent cancels a health-only scheduled task`() {
        val environment = FakeRecoveryEnvironment()
        val controller = NativePlaybackRecoveryController(FakeRecoveryHost(), environment)
        controller.markIntended("prepare-failed")

        assertTrue(controller.isIntended("prepare-failed"))
        assertTrue(environment.delays.contains(15_000L))

        controller.clear("prepare-failed")

        assertFalse(controller.isIntended("prepare-failed"))
        assertTrue(environment.tasks.isEmpty())
    }

    @Test
    fun `stale retry from a cleared generation cannot recover a re-created session`() {
        val environment = FakeRecoveryEnvironment()
        val host = FakeRecoveryHost(recoverySession(environment))
        val controller = NativePlaybackRecoveryController(host, environment)
        controller.markIntended("player")
        controller.onPlayerError(
            sessionId = "player",
            recoverable = true,
            errorCodeName = "ERROR_CODE_IO_NETWORK_CONNECTION_FAILED",
            errorMessage = "network",
            causeDescription = null
        )

        val staleRetry = environment.tasks.entries.first { it.value == 2_000L }.key
        controller.clear("player")
        controller.markIntended("player")
        staleRetry.run()

        assertEquals(0, host.requestAudioFocusCalls)
        assertFalse(controller.isPending("player"))
    }
}

private class FakeRecoveryEnvironment : NativePlaybackRecoveryEnvironment {
    var now = 0L
    var listening = false
    val tasks = linkedMapOf<Runnable, Long>()
    val delays: List<Long> get() = tasks.values.toList()

    override fun elapsedRealtimeMs(): Long = now

    override fun postDelayed(runnable: Runnable, delayMs: Long) {
        tasks[runnable] = delayMs
    }

    override fun remove(runnable: Runnable) {
        tasks.remove(runnable)
    }

    override fun startListening(onTrigger: (String) -> Unit) {
        listening = true
    }

    override fun stopListening() {
        listening = false
    }

    fun runFirst(delayMs: Long) {
        val task = tasks.entries.first { it.value == delayMs }.key
        tasks.remove(task)
        now += delayMs
        task.run()
    }
}

private fun recoverySession(environment: FakeRecoveryEnvironment): NativePlaybackSession =
    NativePlaybackSession(
        sessionId = "player",
        createPlayer = { _, _ -> error("unused") },
        logWarn = { _, _, _ -> },
        elapsedRealtimeMs = { environment.now }
    )

private fun candidateSession(environment: FakeRecoveryEnvironment, count: Int = 1): NativePlaybackSession {
    val session = recoverySession(environment)
    val queue = List(count) { index ->
        NativeMediaItemDescriptor("asmr://track/$index", "https://one/$index.mp3", "Track $index", null, null)
            .withPlaybackCandidateUris(listOf("https://one/$index.mp3", "https://two/$index.mp3"))
    }
    val index = count * 55 / 100
    session.configure(queue[index], queue, index, 8_000L, 1f, 1f,
        repeatOne = false, repeatAll = false, shuffleModeEnabled = false,
        autoPlay = true, deferPlayerCreation = true)
    return session
}

private fun startCandidateRetry(controller: NativePlaybackRecoveryController) {
    controller.markIntended("player")
    controller.onPlayerError("player", recoverable = true, candidateFallbackEligible = true,
        errorCodeName = "ERROR_CODE_IO_BAD_HTTP_STATUS", errorMessage = "503", causeDescription = null)
    controller.retryNow("player", "user_retry")
}

private class FakeRecoveryHost(
    playbackSession: NativePlaybackSession? = null,
    private val playbackSessions: Map<String, NativePlaybackSession> =
        playbackSession?.let { mapOf(it.sessionId to it) }.orEmpty()
) : NativePlaybackRecoveryHost {
    override var interruptionActive = false
    var syncForegroundCalls = 0
    var onSyncForeground: () -> Unit = {}
    var requestAudioFocusCalls = 0
    var onRequestAudioFocus: () -> Unit = {}
    var onHealthSample: (String, Long) -> NativePlaybackHealthSample? = { _, _ -> null }
    val recoveryTimeouts = mutableListOf<String>()
    var foregroundPlaybackAllowed = true
    var deferPreparation = false
    val preparationQueues = mutableListOf<List<NativeMediaItemDescriptor>>()
    private val preparationCompletions = ArrayDeque<() -> Unit>()

    override fun prepareRecoveryQueue(
        sessionId: String,
        queue: List<NativeMediaItemDescriptor>,
        isCurrent: () -> Boolean,
        complete: (Result<NativePlaybackQueue>) -> Unit
    ) {
        preparationQueues += queue
        val completion = {
            complete(if (isCurrent()) Result.success(NativePlaybackQueue(queue))
                else Result.failure(IllegalStateException("superseded")))
        }
        if (deferPreparation) preparationCompletions += completion else completion()
    }

    fun completePreparation() = preparationCompletions.removeFirst().invoke()

    override fun session(sessionId: String): NativePlaybackSession? = playbackSessions[sessionId]
    override fun healthSample(
        sessionId: String,
        nowElapsedRealtimeMs: Long
    ): NativePlaybackHealthSample? = onHealthSample(sessionId, nowElapsedRealtimeMs)
    override fun requestAudioFocus(): Boolean {
        requestAudioFocusCalls += 1
        onRequestAudioFocus()
        return !interruptionActive
    }
    override fun establishForegroundPlayback(sessionId: String): Boolean =
        foregroundPlaybackAllowed
    override fun focusSession(sessionId: String) = Unit
    override fun ensurePlayer(session: NativePlaybackSession): ExoPlayer = error("unused")
    override fun onRecoveryTimedOut(sessionId: String) {
        recoveryTimeouts += sessionId
    }
    override fun publishSession(sessionId: String) = Unit
    override fun publishAllSessions() = Unit
    override fun persistNow() = Unit
    override fun schedulePersist() = Unit
    override fun syncForeground() {
        syncForegroundCalls += 1
        onSyncForeground()
    }
    override fun logInfo(message: String, session: NativePlaybackSession?) = Unit
    override fun logWarn(
        message: String,
        session: NativePlaybackSession?,
        error: PlaybackException?
    ) = Unit
}
