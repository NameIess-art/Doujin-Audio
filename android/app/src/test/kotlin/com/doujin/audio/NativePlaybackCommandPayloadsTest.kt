package com.doujin.audio

import com.doujin.audio.channel.NativePlaybackMethods
import com.doujin.audio.player.common.*
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

        validatePlaybackArgumentsBeforeService(
            MethodCall(
                NativePlaybackMethods.SET_VOLUME,
                mapOf("sessionId" to "main", "volume" to 3.0)
            )
        )

        validatePlaybackArgumentsBeforeService(
            MethodCall(
                NativePlaybackMethods.SET_SPEED,
                mapOf("sessionId" to "main", "speed" to 0.25)
            )
        )

        validatePlaybackArgumentsBeforeService(
            MethodCall(
                NativePlaybackMethods.SET_TEMPORARY_SPEED,
                mapOf("sessionId" to "main", "speed" to 3.0)
            )
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `simple playback commands reject volume above amplified range`() {
        validatePlaybackArgumentsBeforeService(
            MethodCall(
                NativePlaybackMethods.SET_VOLUME,
                mapOf("sessionId" to "main", "volume" to 3.01)
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
    fun `playback behavior requires a complete boolean payload`() {
        validatePlaybackArgumentsBeforeService(
            MethodCall(
                NativePlaybackMethods.SET_PLAYBACK_BEHAVIOR,
                mapOf(
                    "pauseOnAudioDeviceDisconnect" to true,
                    "requestAudioFocus" to false,
                    "pauseOnTransientAudioFocusLoss" to false,
                    "resumeAfterTransientAudioFocusGain" to true,
                    "resumePlaybackOnStartupRestore" to false
                )
            )
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `playback behavior rejects missing values before service startup`() {
        validatePlaybackArgumentsBeforeService(
            MethodCall(
                NativePlaybackMethods.SET_PLAYBACK_BEHAVIOR,
                mapOf("pauseOnAudioDeviceDisconnect" to true)
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
        assertEquals(emptyList<String>(), parsed.candidateUris)
    }

    @Test
    fun `prepare parser accepts maximum amplified volume`() {
        val parsed = NativePlaybackCommandPayloads.parsePrepareSession(
            validPreparePayload().toMutableMap().apply { put("volume", 3.0) }
        )

        assertEquals(3.0f, parsed.volume)
    }

    @Test
    fun `prepare parser accepts expanded playback speed boundaries`() {
        val slow = NativePlaybackCommandPayloads.parsePrepareSession(
            validPreparePayload().toMutableMap().apply { put("speed", 0.25) }
        )
        val fast = NativePlaybackCommandPayloads.parsePrepareSession(
            validPreparePayload().toMutableMap().apply { put("speed", 3.0) }
        )

        assertEquals(0.25f, slow.speed)
        assertEquals(3.0f, fast.speed)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `prepare parser rejects volume above amplified range`() {
        NativePlaybackCommandPayloads.parsePrepareSession(
            validPreparePayload().toMutableMap().apply { put("volume", 3.01) }
        )
    }

    @Test
    fun `prepare parser validates and deduplicates candidate uris`() {
        val parsed = NativePlaybackCommandPayloads.parsePrepareSession(
            validPreparePayload().toMutableMap().apply {
                put(
                    "candidateUris",
                    listOf(
                        "https://api.asmr.one/audio.mp3",
                        "https://api.asmr-100.com/audio.mp3",
                        "https://api.asmr.one/audio.mp3"
                    )
                )
            }
        )

        assertEquals(
            listOf(
                "https://api.asmr.one/audio.mp3",
                "https://api.asmr-100.com/audio.mp3"
            ),
            parsed.candidateUris
        )
    }

    @Test
    fun `queue parser validates and keeps candidates for each item`() {
        val parsed = NativePlaybackCommandPayloads.parseQueue(
            listOf(
                mapOf(
                    "uri" to "https://example.com/first.mp3",
                    "title" to "First",
                    "candidateUris" to listOf(
                        "https://cdn-1.example.com/first.mp3",
                        "https://cdn-1.example.com/first.mp3",
                        "https://cdn-2.example.com/first.mp3"
                    )
                ),
                mapOf(
                    "uri" to "https://example.com/second.mp3",
                    "title" to "Second",
                    "candidateUris" to listOf("https://backup.example.com/second.mp3")
                )
            )
        )

        assertEquals(
            listOf(
                "https://example.com/first.mp3",
                "https://cdn-1.example.com/first.mp3",
                "https://cdn-2.example.com/first.mp3"
            ),
            parsed[0].candidateUris
        )
        assertEquals(
            listOf(
                "https://example.com/second.mp3",
                "https://backup.example.com/second.mp3"
            ),
            parsed[1].candidateUris
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `queue parser rejects invalid per item candidate`() {
        NativePlaybackCommandPayloads.parseQueue(
            listOf(
                mapOf(
                    "uri" to "https://example.com/audio.mp3",
                    "title" to "Audio",
                    "candidateUris" to listOf("file:///audio.mp3")
                )
            )
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `prepare parser rejects non http candidate uri`() {
        NativePlaybackCommandPayloads.parsePrepareSession(
            validPreparePayload().toMutableMap().apply {
                put("candidateUris", listOf("file:///audio.mp3"))
            }
        )
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
