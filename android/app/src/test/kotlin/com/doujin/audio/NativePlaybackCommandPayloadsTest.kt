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
    fun `deferred prepare uses only the background file command even when another service exists`() {
        val command = parsePlaybackCommand(MethodCall(NativePlaybackMethods.PREPARE_SESSION,
            validPreparePayload() + ("deferPlayerCreation" to true)))
        assertFalse(command.canStartService)
        assertTrue(command.dispatchBackground != null)
        assertNull(command.dispatchAsync)
        assertNull(command.sessionId)
        val stored = NativePlaybackCommandPayloads.parsePrepareSession(
            validPreparePayload() + ("deferPlayerCreation" to true) + ("startPositionMs" to 22_000L)).storedDefinition()
        assertEquals(22_000L, stored.positionMs)
        assertFalse(stored.playing)
        assertFalse(stored.playWhenReady)
        assertEquals(1, stored.queue.size)
    }

    @Test
    fun `global pause and clear cancel pending starts before command delivery`() {
        assertTrue(parsePlaybackCommand(MethodCall(NativePlaybackMethods.PAUSE_ALL, null)).cancelAllPendingStarts)
        assertTrue(parsePlaybackCommand(MethodCall(NativePlaybackMethods.CLEAR_ALL, null)).cancelAllPendingStarts)
    }
    @Test
    fun `cold pause cancels only pending preparation and play for its target without starting service`() {
        val pause = parsePlaybackCommand(MethodCall(NativePlaybackMethods.PAUSE,
            mapOf("sessionId" to "A", "transportCommandId" to 2L)))
        assertEquals("A", pause.cancelPendingStartForSession)
        assertFalse(pause.canStartService)
        assertTrue(pause.dispatchInactive != null)
        assertTrue(isPendingPlaybackStartForSession(NativePlaybackMethods.PREPARE_SESSION, "A", "A"))
        assertTrue(isPendingPlaybackStartForSession(NativePlaybackMethods.PLAY, "A", "A"))
        assertFalse(isPendingPlaybackStartForSession(NativePlaybackMethods.PREPARE_SESSION, "B", "A"))
        assertFalse(isPendingPlaybackStartForSession(NativePlaybackMethods.SET_VOLUME, "A", "A"))
        assertEquals("A", parsePlaybackCommand(MethodCall(NativePlaybackMethods.PREPARE_SESSION,
            validPreparePayload() + ("sessionId" to "A"))).sessionId)
    }
    @Test
    fun `inactive snapshot contains no recovery definitions that could overwrite newer Dart state`() {
        assertEquals(emptyList<Map<String, Any?>>(), inactiveNativePlaybackRuntimeSnapshot["sessions"])
        assertNull(inactiveNativePlaybackRuntimeSnapshot["focusedSessionId"])
        val command = parsePlaybackCommand(MethodCall(NativePlaybackMethods.SNAPSHOT, null))
        assertFalse(command.canStartService)
        assertTrue(command.dispatchInactive != null)
    }
    @Test
    fun `only actual playback or its explicit preparation may start the native service`() {
        assertFalse(parsePlaybackCommand(MethodCall(NativePlaybackMethods.SNAPSHOT, null)).canStartService)
        assertFalse(parsePlaybackCommand(MethodCall(NativePlaybackMethods.SET_VOLUME,
            mapOf("sessionId" to "main", "volume" to 1.0))).canStartService)
        assertFalse(parsePlaybackCommand(MethodCall(NativePlaybackMethods.PREPARE_SESSION,
            validPreparePayload() + ("deferPlayerCreation" to true))).canStartService)
        assertTrue(parsePlaybackCommand(MethodCall(NativePlaybackMethods.PREPARE_SESSION,
            validPreparePayload() + ("deferPlayerCreation" to false))).canStartService)
        assertTrue(parsePlaybackCommand(MethodCall(NativePlaybackMethods.PLAY,
            mapOf("sessionId" to "main", "transportCommandId" to 1L, "exclusive" to false))).canStartService)
    }
    @Test
    fun `independent queue update accepts explicit empty queue and defaults modes`() {
        val args = NativePlaybackCommandPayloads.parseUpdateQueue(mapOf("sessionId" to "main", "queue" to emptyList<Any>()))
        assertEquals(0L, args.queueRevision)
        assertEquals(0, args.queueStartIndex)
        assertFalse(args.repeatOne)
        assertTrue(args.queue.isEmpty())
        assertTrue(isSupportedNativePlaybackMethod("updateQueue"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `queue update rejects missing queue instead of silently clearing playback`() {
        NativePlaybackCommandPayloads.parseUpdateQueue(mapOf("sessionId" to "main"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `queue update rejects negative revisions`() {
        NativePlaybackCommandPayloads.parseUpdateQueue(mapOf("sessionId" to "main", "queue" to emptyList<Any>(), "queueRevision" to -1))
    }
    @Test
    fun `temporary session marker is explicit and normal sessions retain persistence`() {
        assertFalse(NativePlaybackCommandPayloads.parsePrepareSession(validPreparePayload()).isTemporary)
        assertTrue(NativePlaybackCommandPayloads.parsePrepareSession(
            validPreparePayload() + ("isTemporary" to true)
        ).isTemporary)
    }

    @Test
    fun `bridge rejects unknown methods before starting service`() {
        assertTrue(isSupportedNativePlaybackMethod(NativePlaybackMethods.SNAPSHOT))
        assertFalse(isSupportedNativePlaybackMethod("unknownPlaybackMethod"))
    }

    @Test
    fun `simple playback commands are validated before service startup`() {
        parsePlaybackCommand(
            MethodCall(
                NativePlaybackMethods.PLAY,
                mapOf(
                    "sessionId" to "main",
                    "transportCommandId" to 1L,
                    "exclusive" to true
                )
            )
        )

        parsePlaybackCommand(
            MethodCall(
                NativePlaybackMethods.SET_VOLUME,
                mapOf("sessionId" to "main", "volume" to 3.0)
            )
        )

        parsePlaybackCommand(
            MethodCall(
                NativePlaybackMethods.SET_SPEED,
                mapOf("sessionId" to "main", "speed" to 0.25)
            )
        )

        parsePlaybackCommand(
            MethodCall(
                NativePlaybackMethods.SET_TEMPORARY_SPEED,
                mapOf("sessionId" to "main", "speed" to 3.0)
            )
        )
    }

    @Test
    fun `play command requests foreground bootstrap before service startup`() {
        val command = parsePlaybackCommand(
            MethodCall(
                NativePlaybackMethods.PLAY,
                mapOf("sessionId" to "main", "transportCommandId" to 1L, "exclusive" to false)
            )
        )

        assertTrue(command.requireForegroundBootstrap)
    }

    @Test
    fun `prepare command requests foreground bootstrap only for autoplay`() {
        val paused = parsePlaybackCommand(
            MethodCall(NativePlaybackMethods.PREPARE_SESSION, validPreparePayload())
        )
        val autoplay = parsePlaybackCommand(
            MethodCall(
                NativePlaybackMethods.PREPARE_SESSION,
                validPreparePayload() + ("autoPlay" to true)
            )
        )

        assertFalse(paused.requireForegroundBootstrap)
        assertTrue(autoplay.requireForegroundBootstrap)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `play command rejects missing exclusive flag before service startup`() {
        parsePlaybackCommand(
            MethodCall(
                NativePlaybackMethods.PLAY,
                mapOf("sessionId" to "main", "transportCommandId" to 1L)
            )
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `foreground command rejects missing enabled flag before service startup`() {
        parsePlaybackCommand(MethodCall(NativePlaybackMethods.SET_FOREGROUND_ENABLED, emptyMap<String, Any>()))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `simple playback commands reject volume above amplified range`() {
        parsePlaybackCommand(
            MethodCall(
                NativePlaybackMethods.SET_VOLUME,
                mapOf("sessionId" to "main", "volume" to 3.01)
            )
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `simple playback commands reject non finite values before service startup`() {
        parsePlaybackCommand(
            MethodCall(
                NativePlaybackMethods.SET_VOLUME,
                mapOf("sessionId" to "main", "volume" to Double.NaN)
            )
        )
    }

    @Test
    fun `playback behavior requires a complete boolean payload`() {
        parsePlaybackCommand(
            MethodCall(
                NativePlaybackMethods.SET_PLAYBACK_BEHAVIOR,
                mapOf(
                    "pauseOnAudioDeviceDisconnect" to true,
                    "requestAudioFocus" to false,
                    "pauseOnTransientAudioFocusLoss" to false,
                    "resumeAfterTransientAudioFocusGain" to true
                )
            )
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `playback behavior rejects missing values before service startup`() {
        parsePlaybackCommand(
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
