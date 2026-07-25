package com.nameless.audio

import com.nameless.audio.player.recovery.*
import com.nameless.audio.player.session.*

import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackRecoveryControllerTest {
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
            recoveryWindowMs = 60_000L,
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
        val controller = NativePlaybackRecoveryController(host, environment, recoveryWindowMs = 60_000L)
        host.onRequestAudioFocus = { controller.trigger("foreground_sync") }
        controller.markIntended("player")

        controller.trigger("network_available")

        assertEquals(1, host.requestAudioFocusCalls)
    }

    @Test
    fun recoverableErrorSchedulesRetryAndExpiryThenDisposesListeners() {
        val environment = FakeRecoveryEnvironment()
        val host = FakeRecoveryHost()
        val controller = NativePlaybackRecoveryController(host, environment, recoveryWindowMs = 60_000L)
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
        assertEquals(listOf(2_000L, 15_000L, 60_000L), environment.delays.sorted())

        environment.runFirst(2_000L)

        assertFalse(controller.isIntended("player"))
        assertFalse(controller.isPending("player"))
        assertFalse(environment.listening)
    }

    /**
     * Network errors used to retry forever. Recovery keeps the service in its
     * keep-alive state, which holds the playback wake lock, so an item that
     * never comes back drained the battery all night.
     */
    @Test
    fun `network playback errors also stop after the recovery window`() {
        val environment = FakeRecoveryEnvironment()
        val controller = NativePlaybackRecoveryController(
            FakeRecoveryHost(),
            environment,
            recoveryWindowMs = 60_000L
        )
        controller.markIntended("player")
        controller.onPlayerError(
            sessionId = "player",
            recoverable = true,
            errorCodeName = "ERROR_CODE_IO_NETWORK_CONNECTION_FAILED",
            errorMessage = "network",
            causeDescription = null
        )

        environment.runFirst(60_000L)

        assertFalse(controller.isIntended("player"))
        assertFalse(controller.isPending("player"))
        assertFalse(controller.shouldKeepAlive())
        assertFalse(environment.listening)
        assertTrue(environment.tasks.isEmpty())
    }

    @Test
    fun `decoder playback errors stop after the recovery window`() {
        val environment = FakeRecoveryEnvironment()
        val host = FakeRecoveryHost()
        val controller = NativePlaybackRecoveryController(
            host = host,
            environment = environment,
            recoveryWindowMs = 60_000L
        )
        controller.markIntended("player")

        controller.onPlayerError(
            sessionId = "player",
            recoverable = true,
            errorCodeName = "ERROR_CODE_DECODER_INIT_FAILED",
            errorMessage = "decoder",
            causeDescription = null
        )

        environment.runFirst(60_000L)

        assertFalse(controller.isIntended("player"))
        assertFalse(controller.isPending("player"))
        assertFalse(environment.listening)
        assertTrue(environment.tasks.isEmpty())
    }

    @Test
    fun staleScheduledTasksAreRemovedWhenIntentIsCleared() {
        val environment = FakeRecoveryEnvironment()
        val controller = NativePlaybackRecoveryController(
            FakeRecoveryHost(),
            environment,
            recoveryWindowMs = 60_000L
        )
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
    fun `network recovery advances playback candidate before repreparing`() {
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
            environment,
            recoveryWindowMs = 60_000L
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
        environment.runFirst(0L)
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
        val controller = NativePlaybackRecoveryController(
            FakeRecoveryHost(),
            environment,
            recoveryWindowMs = 60_000L
        )
        controller.markIntended("prepare-failed")

        assertTrue(controller.isIntended("prepare-failed"))
        assertTrue(environment.delays.contains(15_000L))

        controller.clear("prepare-failed")

        assertFalse(controller.isIntended("prepare-failed"))
        assertTrue(environment.tasks.isEmpty())
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

private class FakeRecoveryHost(
    playbackSession: NativePlaybackSession? = null,
    private val playbackSessions: Map<String, NativePlaybackSession> =
        playbackSession?.let { mapOf(it.sessionId to it) }.orEmpty()
) : NativePlaybackRecoveryHost {
    var syncForegroundCalls = 0
    var onSyncForeground: () -> Unit = {}
    var requestAudioFocusCalls = 0
    var onRequestAudioFocus: () -> Unit = {}
    var onHealthSample: (String, Long) -> NativePlaybackHealthSample? = { _, _ -> null }

    override fun session(sessionId: String): NativePlaybackSession? = playbackSessions[sessionId]
    override fun healthSample(
        sessionId: String,
        nowElapsedRealtimeMs: Long
    ): NativePlaybackHealthSample? = onHealthSample(sessionId, nowElapsedRealtimeMs)
    override fun requestAudioFocus(): Boolean {
        requestAudioFocusCalls += 1
        onRequestAudioFocus()
        return true
    }
    override fun focusSession(sessionId: String) = Unit
    override fun ensurePlayer(session: NativePlaybackSession): ExoPlayer = error("unused")
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
