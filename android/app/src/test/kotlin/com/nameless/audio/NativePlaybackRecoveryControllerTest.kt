package com.nameless.audio

import com.nameless.audio.player.recovery.*
import com.nameless.audio.player.session.*

import androidx.media3.common.PlaybackException
import androidx.media3.exoplayer.ExoPlayer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackRecoveryControllerTest {
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
        assertEquals(listOf(2_000L, 60_000L), environment.delays.sorted())

        environment.runFirst(2_000L)

        assertFalse(controller.isIntended("player"))
        assertFalse(controller.isPending("player"))
        assertFalse(environment.listening)
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

private class FakeRecoveryHost : NativePlaybackRecoveryHost {
    override fun session(sessionId: String): NativePlaybackSession? = null
    override fun requestAudioFocus(): Boolean = true
    override fun focusSession(sessionId: String) = Unit
    override fun ensurePlayer(session: NativePlaybackSession): ExoPlayer = error("unused")
    override fun publishSession(sessionId: String) = Unit
    override fun publishAllSessions() = Unit
    override fun persistNow() = Unit
    override fun schedulePersist() = Unit
    override fun syncForeground() = Unit
    override fun logInfo(message: String, session: NativePlaybackSession?) = Unit
    override fun logWarn(
        message: String,
        session: NativePlaybackSession?,
        error: PlaybackException?
    ) = Unit
}
