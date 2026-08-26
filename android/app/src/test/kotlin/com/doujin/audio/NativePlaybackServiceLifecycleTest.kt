package com.doujin.audio

import com.doujin.audio.player.service.runPlaybackShutdownActions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class NativePlaybackServiceLifecycleTest {
    @Test
    fun `shutdown attempts every action and returns the first failure`() {
        val calls = mutableListOf<Int>()
        val first = IllegalStateException("first")

        val failure = runPlaybackShutdownActions(
            listOf(
                { calls += 1; throw first },
                { calls += 2 },
                { calls += 3; throw IllegalArgumentException("later") }
            )
        )

        assertEquals(listOf(1, 2, 3), calls)
        assertSame(first, failure)
    }
}
