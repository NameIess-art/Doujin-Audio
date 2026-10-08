package com.doujin.audio

import com.doujin.audio.player.session.NativePlaybackTimerExecution
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackTimerExecutionTest {
    @Test
    fun `finishing one session keeps timer armed until every target ends`() {
        val pauseAtEnd = mutableMapOf<String, Boolean>()
        val completions = mutableListOf<Int?>()
        val execution = NativePlaybackTimerExecution(
            setPauseAtEnd = { id, enabled -> pauseAtEnd[id] = enabled },
            restoreFade = {},
            onAllTracksFinished = completions::add
        )
        execution.arm(listOf("first", "second"), 7)
        execution.onTrackEnded("unrelated", 7)
        execution.onTrackEnded("first", 7)
        assertTrue(completions.isEmpty())
        assertEquals(false, pauseAtEnd["first"])
        assertEquals(true, pauseAtEnd["second"])
        execution.onTrackEnded("second", 7)
        execution.onTrackEnded("second", 7)
        assertEquals(listOf(7), completions)
    }

    @Test
    fun `cancel releases end of track flags without completing the timer`() {
        val pauseAtEnd = mutableMapOf<String, Boolean>()
        val completions = mutableListOf<Int?>()
        val execution = NativePlaybackTimerExecution(
            setPauseAtEnd = { id, enabled -> pauseAtEnd[id] = enabled },
            restoreFade = {},
            onAllTracksFinished = completions::add
        )
        execution.arm(listOf("session"), 3)
        execution.cancel()
        execution.onTrackEnded("session", execution.generationFor("session"))
        assertEquals(false, pauseAtEnd["session"])
        assertTrue(completions.isEmpty())
    }

    @Test
    fun `rearming uses the latest generation and restores target fades`() {
        val fadesRestored = mutableListOf<String>()
        val completions = mutableListOf<Int?>()
        val execution = NativePlaybackTimerExecution(
            setPauseAtEnd = { _, _ -> },
            restoreFade = fadesRestored::add,
            onAllTracksFinished = completions::add
        )
        execution.arm(listOf("session"), 3)
        execution.arm(listOf("session"), 5)
        execution.onTrackEnded("session", 3)
        assertTrue(completions.isEmpty())
        execution.onTrackEnded("session", execution.generationFor("session"))
        assertEquals(listOf("session", "session", "session", "session"), fadesRestored)
        assertEquals(listOf(5), completions)
    }

    @Test
    fun `manual removal finishes remaining targets and rearm clears old flags`() {
        val flags = mutableMapOf<String, Boolean>()
        val completions = mutableListOf<Int?>()
        val execution = NativePlaybackTimerExecution(
            setPauseAtEnd = { id, value -> flags[id] = value },
            restoreFade = {}, onAllTracksFinished = completions::add
        )
        execution.arm(listOf("old"), 2)
        execution.arm(listOf("first", "second"), 3)
        assertEquals(false, flags["old"])
        execution.removeTarget("first")
        assertTrue(completions.isEmpty())
        execution.removeTarget("second")
        assertEquals(listOf(3), completions)
    }
}
