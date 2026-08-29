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
    val recoveryTimeouts = mutableListOf<String>()
    var foregroundPlaybackAllowed = true

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
