package com.nameless.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackCommandPayloadsTest {
    @Test
    fun `queue parser keeps compatible defaults and ignores invalid entries`() {
        val queue = NativePlaybackCommandPayloads.parseQueue(
            listOf(
                mapOf(
                    "uri" to "content://audio/1",
                    "subtitle" to "Episode 1"
                ),
                mapOf("title" to "Missing URI"),
                "invalid"
            )
        )

        assertEquals(1, queue.size)
        assertEquals("content://audio/1", queue.single().path)
        assertEquals("content://audio/1", queue.single().uri)
        assertEquals("Audio", queue.single().title)
        assertEquals("Episode 1", queue.single().subtitle)
        assertNull(queue.single().artUri)
    }

    @Test
    fun `audio effects parser keeps valid bands and stable defaults`() {
        val effects = NativePlaybackCommandPayloads.parseAudioEffects(
            mapOf(
                "eqEnabled" to true,
                "eqPresetId" to "",
                "eqBandLevels" to listOf(
                    mapOf("frequencyHz" to 100, "gainDb" to 2.5),
                    mapOf("frequencyHz" to 0, "gainDb" to 9),
                    mapOf("frequencyHz" to "invalid", "gainDb" to 3)
                ),
                "panning" to -0.25
            )
        )

        assertTrue(effects.eqEnabled)
        assertEquals(mapOf(100 to 2.5f), effects.eqBandLevels)
        assertNull(effects.eqPresetId)
        assertEquals(-0.25f, effects.panning)
        assertFalse(effects.skipSilenceEnabled)
        assertFalse(effects.channelSwapEnabled)
    }
}
