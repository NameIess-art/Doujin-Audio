package com.nameless.audio

import com.nameless.audio.channel.NativePlaybackMethods
import com.nameless.audio.player.common.*
import io.flutter.plugin.common.MethodCall
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackCommandPayloadsTest {
    @Test
    fun `bridge rejects unknown methods before starting service`() {
        assertTrue(isSupportedNativePlaybackMethod(NativePlaybackMethods.SNAPSHOT))
        assertFalse(isSupportedNativePlaybackMethod("unknownPlaybackMethod"))
    }

    @Test
    fun `simple playback commands are validated before service startup`() {
        validatePlaybackArgumentsBeforeService(
            MethodCall(
                NativePlaybackMethods.PLAY,
                mapOf(
                    "sessionId" to "main",
                    "transportCommandId" to 1L,
                    "exclusive" to true
                )
            )
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `simple playback commands reject non finite values before service startup`() {
        validatePlaybackArgumentsBeforeService(
            MethodCall(
                NativePlaybackMethods.SET_VOLUME,
                mapOf("sessionId" to "main", "volume" to Double.NaN)
            )
        )
    }

    @Test
    fun `queue parser accepts fully typed items`() {
        val queue = NativePlaybackCommandPayloads.parseQueue(
            listOf(
                mapOf(
                    "uri" to "content://audio/1",
                    "title" to "Episode 1",
                    "subtitle" to "Episode 1"
                )
            )
        )

        assertEquals(1, queue.size)
        assertEquals("content://audio/1", queue.single().path)
        assertEquals("Episode 1", queue.single().title)
        assertNull(queue.single().artUri)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `queue parser rejects malformed items instead of dropping them`() {
        NativePlaybackCommandPayloads.parseQueue(
            listOf(mapOf("title" to "Missing URI"), "invalid")
        )
    }

    @Test
    fun `audio effects parser validates complete finite payload`() {
        val effects = NativePlaybackCommandPayloads.parseAudioEffects(
            validEffects(
                eqEnabled = true,
                eqBandLevels = listOf(mapOf("frequencyHz" to 100, "gainDb" to 2.5)),
                panning = -0.25
            )
        )

        assertTrue(effects.eqEnabled)
        assertEquals(mapOf(100 to 2.5f), effects.eqBandLevels)
        assertNull(effects.eqPresetId)
        assertEquals(-0.25f, effects.panning)
        assertFalse(effects.skipSilenceEnabled)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `audio effects parser rejects non-finite values`() {
        NativePlaybackCommandPayloads.parseAudioEffects(
            validEffects(panning = Double.NaN)
        )
    }

    @Test
    fun `prepare parser accepts the production payload`() {
        val parsed = NativePlaybackCommandPayloads.parsePrepareSession(
            validPreparePayload()
        )

        assertEquals("session-1", parsed.sessionId)
        assertEquals("https://example.com/audio.mp3", parsed.uri)
        assertEquals(0, parsed.queueStartIndex)
        assertEquals(1, parsed.queue.size)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `prepare parser rejects missing required values`() {
        NativePlaybackCommandPayloads.parsePrepareSession(
            validPreparePayload().toMutableMap().apply { remove("startPositionMs") }
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `prepare parser rejects unsupported URI schemes`() {
        NativePlaybackCommandPayloads.parsePrepareSession(
            validPreparePayload().toMutableMap().apply { put("uri", "javascript:alert(1)") }
        )
    }
}

private fun validPreparePayload(): Map<String, Any?> = mapOf(
    "sessionId" to "session-1",
    "uri" to "https://example.com/audio.mp3",
    "title" to "Audio",
    "startPositionMs" to 0L,
    "volume" to 1.0,
    "speed" to 1.0,
    "audioEffects" to validEffects(),
    "repeatOne" to false,
    "autoPlay" to false,
    "repeatAll" to true,
    "shuffle" to false,
    "deferPlayerCreation" to false
)

private fun validEffects(
    eqEnabled: Boolean = false,
    eqBandLevels: List<Map<String, Number>> = emptyList(),
    panning: Number = 0.0
): Map<String, Any?> = mapOf(
    "skipSilenceEnabled" to false,
    "noiseReductionEnabled" to false,
    "volumeNormalizationEnabled" to false,
    "eqEnabled" to eqEnabled,
    "eqPresetId" to null,
    "eqBandLevels" to eqBandLevels,
    "channelSwapEnabled" to false,
    "panning" to panning
)
