package com.doujin.audio

import com.doujin.audio.player.notification.*
import com.doujin.audio.player.session.StoredPlaybackTimerRuntimeState
import org.junit.Assert.*
import org.junit.Test

class PlaybackTimerCommandDeliveryTest {
    @Test
    fun `async restore keeps delivery open and timer state intact until it completes`() {
        val fixture = TimerDeliveryFixture()
        var finishRestore: ((String) -> Unit)? = null
        fixture.action = { _, _, _, _, complete -> finishRestore = complete }
        fixture.execute { fixture.runtime = null }

        assertEquals(1, fixture.begins)
        assertEquals(0, fixture.ends)
        assertTrue(fixture.outcomes.isEmpty())
        assertNotNull(fixture.runtime)

        finishRestore!!(PlaybackTimerAlarmProtocol.resultExecuted)
        assertEquals(listOf(PlaybackTimerAlarmProtocol.resultExecuted), fixture.outcomes)
        assertEquals(1, fixture.ends)
        assertNull(fixture.runtime)
        finishRestore!!(PlaybackTimerAlarmProtocol.resultExecuted)
        assertEquals(1, fixture.outcomes.size)
        assertEquals(1, fixture.ends)
    }

    @Test
    fun `cancelled async restore ends delivery with stale without reporting execution`() {
        val fixture = TimerDeliveryFixture()
        var finishRestore: ((String) -> Unit)? = null
        fixture.action = { _, _, _, _, complete -> finishRestore = complete }
        fixture.execute()
        fixture.runtime = fixture.runtime!!.copy(generation = 8)
        finishRestore!!(PlaybackTimerAlarmProtocol.resultStale)

        assertEquals(listOf(PlaybackTimerAlarmProtocol.resultStale), fixture.outcomes)
        assertEquals(1, fixture.ends)
        assertEquals(8, fixture.runtime!!.generation)
    }

    @Test
    fun `a generation change during service startup prevents the queued action`() {
        val fixture = TimerDeliveryFixture()
        fixture.action = null
        fixture.execute()
        assertEquals(1, fixture.delayed.size)
        fixture.runtime = fixture.runtime!!.copy(generation = 8)
        var executions = 0
        fixture.action = { _, _, _, _, complete ->
            executions += 1
            complete(PlaybackTimerAlarmProtocol.resultExecuted)
        }
        fixture.delayed.removeFirst().invoke()

        assertEquals(0, executions)
        assertEquals(listOf(PlaybackTimerAlarmProtocol.resultStale), fixture.outcomes)
        assertEquals(1, fixture.begins)
        assertEquals(1, fixture.ends)
    }

    @Test
    fun `an action failure settles once and ignores a late completion`() {
        val fixture = TimerDeliveryFixture()
        var finishRestore: ((String) -> Unit)? = null
        fixture.action = { _, _, _, _, complete ->
            finishRestore = complete
            error("Cannot restore playback.")
        }
        fixture.execute()
        finishRestore!!(PlaybackTimerAlarmProtocol.resultExecuted)

        assertEquals(listOf(PlaybackTimerAlarmProtocol.resultFailed), fixture.outcomes)
        assertEquals(1, fixture.ends)
        assertEquals(1, fixture.failures.size)
    }
}

private class TimerDeliveryFixture {
    var runtime: StoredPlaybackTimerRuntimeState? = StoredPlaybackTimerRuntimeState(
        timerModeIndex = null, durationMs = null, waitingForPlayback = false,
        timerEndsAtWallClockMs = null, timerEndsElapsedRealtimeMs = null,
        autoResumeEnabled = true, autoResumeHour = 7, autoResumeMinute = 0,
        autoResumeAtMs = 1_700_000_000_000L, pausedSessionIds = listOf("session"), generation = 7
    )
    var action: PlaybackTimerAction? = null
    var begins = 0
    var ends = 0
    val delayed = ArrayDeque<() -> Unit>()
    val outcomes = mutableListOf<String>()
    val failures = mutableListOf<Throwable>()
    private val delivery = PlaybackTimerCommandDelivery(
        startService = { action }, loadRuntimeState = { runtime },
        postDelayed = { task, delay -> assertEquals(250L, delay); delayed += task },
        beginCommandDelivery = { begins += 1 }, endCommandDelivery = { ends += 1 },
        logInfo = {}, logWarn = { _, error -> failures += error }
    )

    fun execute(onComplete: () -> Unit = {}) {
        delivery.executeNow(PlaybackTimerAlarmProtocol.actionAutoResume, 7) { outcome ->
            outcomes += outcome
            onComplete()
        }
    }
}
