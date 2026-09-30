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
        execution.onTrackEnded("unrelated")
        execution.onTrackEnded("first")
        assertTrue(completions.isEmpty())
        assertEquals(false, pauseAtEnd["first"])
        assertEquals(true, pauseAtEnd["second"])
        execution.onTrackEnded("second")
        execution.onTrackEnded("second")
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
        execution.onTrackEnded("session")
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
        execution.onTrackEnded("session")
        assertEquals(listOf("session", "session"), fadesRestored)
        assertEquals(listOf(5), completions)
    }
}
