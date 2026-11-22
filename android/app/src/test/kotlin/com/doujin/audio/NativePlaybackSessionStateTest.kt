package com.doujin.audio

import com.doujin.audio.player.effects.*
import com.doujin.audio.player.service.*
import com.doujin.audio.player.session.*

import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.audio.AudioProcessor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos

class NativePlaybackSessionStateTest {
    @Test
    fun `track stop snapshot preserves independent reasons and the final boundary`() {
        val session = NativePlaybackSession(
            sessionId = "stop", createPlayer = { _, _ -> error("snapshot must not create a player") },
            logWarn = { _, _, _ -> }, elapsedRealtimeMs = { 1_000L }
        )
        session.stopAfterCurrentTrack = true
        session.timerStopAfterCurrentTrack = true
        session.stopAfterCurrentTrack = false
        assertEquals(true, session.snapshot()["stopAfterCurrentTrack"])
        session.timerStopAfterCurrentTrack = false
        session.stoppedAtTrackBoundary = true
        assertEquals(true, session.snapshot()["stopAfterCurrentTrack"])
        session.stoppedAtTrackBoundary = false
        assertEquals(false, session.snapshot()["stopAfterCurrentTrack"])
    }
    @Test
    fun `reconfiguring a deferred session discards previous media duration and buffer`() {
        val first = NativeMediaItemDescriptor(
            path = "/short.mp3",
            uri = "file:///short.mp3",
            title = "Short",
            subtitle = null,
            artUri = null
        )
        val second = first.copy(
            path = "/long.mp3",
            uri = "file:///long.mp3",
            title = "Long"
        )
        val session = NativePlaybackSession(
            sessionId = "deferred",
            createPlayer = { _, _ -> error("player should stay deferred") },
            logWarn = { _, _, _ -> },
            elapsedRealtimeMs = { 2_000L }
        )
        fun configure(descriptor: NativeMediaItemDescriptor, positionMs: Long) {
            session.configure(
                descriptor = descriptor,
                queue = listOf(descriptor),
                queueStartIndex = 0,
                startPositionMs = positionMs,
                volume = 1f,
                speed = 1f,
                repeatOne = false,
                repeatAll = false,
                shuffleModeEnabled = false,
                autoPlay = false,
                deferPlayerCreation = true
            )
        }

        configure(first, 1_000L)
        session.lastDurationMs = 5_000L
        session.lastBufferedPositionMs = 4_000L
        configure(second, 0L)
        session.seekTo(8_000L)

        val snapshot = session.snapshot()
        assertEquals("Long", snapshot["title"])
        assertNull(snapshot["durationMs"])
        assertEquals(8_000L, snapshot["positionMs"])
        assertEquals(8_000L, snapshot["bufferedPositionMs"])
    }

    @Test
    fun `seeking a deferred session updates snapshots without creating a player`() {
        var playerCreationCount = 0
        val descriptor = NativeMediaItemDescriptor(
            path = "/audio.mp3",
            uri = "file:///audio.mp3",
            title = "Audio",
            subtitle = null,
            artUri = null
        )
        val session = NativePlaybackSession(
            sessionId = "deferred",
            createPlayer = { _, _ ->
                playerCreationCount++
                error("player should stay deferred")
            },
            logWarn = { _, _, _ -> },
            elapsedRealtimeMs = { 2_000L }
        )
        session.configure(
            descriptor = descriptor,
            queue = listOf(descriptor),
            queueStartIndex = 0,
            startPositionMs = 1_000L,
            volume = 1f,
            speed = 1f,
            repeatOne = false,
            repeatAll = false,
            shuffleModeEnabled = false,
            autoPlay = false,
            deferPlayerCreation = true
        )
        session.lastDurationMs = 5_000L
        session.lastBufferedPositionMs = 1_500L

        session.seekTo(8_000L)

        assertEquals(0, playerCreationCount)
        assertEquals(5_000L, session.snapshot()["positionMs"])
        assertEquals(5_000L, session.snapshot()["bufferedPositionMs"])
        assertEquals(5_000L, session.storedSnapshot().positionMs)

        session.seekTo(-100L)

        assertEquals(0L, session.snapshot()["positionMs"])
        assertEquals(0, playerCreationCount)
    }

    @Test
    fun `temporary speed affects progress without changing persisted speed`() {
        val descriptor = NativeMediaItemDescriptor(
            path = "/video.mp4",
            uri = "file:///video.mp4",
            title = "Video",
            subtitle = null,
            artUri = null
        )
        val session = NativePlaybackSession(
            sessionId = "video",
            createPlayer = { _, _ -> error("player should stay deferred") },
            logWarn = { _, _, _ -> },
            elapsedRealtimeMs = { 1_000L }
        )
        session.configure(
            descriptor = descriptor,
            queue = listOf(descriptor),
            queueStartIndex = 0,
            startPositionMs = 0,
            volume = 1f,
            speed = 1.25f,
            repeatOne = false,
            repeatAll = false,
            shuffleModeEnabled = false,
            autoPlay = false,
            deferPlayerCreation = true
        )

        session.applyTemporarySpeed(2f)
        val temporarySnapshot = session.snapshot()

        assertEquals(1.25, temporarySnapshot["speed"] as Double, 0.001)
        assertEquals(1.25f, session.storedSnapshot().speed, 0.001f)
        assertEquals(2f, session.progressAnchorSnapshot().speed, 0.001f)

        session.applyTemporarySpeed(null)
        session.snapshot()
        assertEquals(1.25f, session.progressAnchorSnapshot().speed, 0.001f)

        session.applyTemporarySpeed(2f)
        session.releasePlayer()
        session.snapshot()
        assertEquals(1.25f, session.progressAnchorSnapshot().speed, 0.001f)
        assertEquals(1.25f, session.storedSnapshot().speed, 0.001f)
    }

    @Test
    fun `duration keeps zero duration but filters unset and negative values`() {
        assertNull(durationOrNull(C.TIME_UNSET))
        assertNull(durationOrNull(-1L))
        assertEquals(0L, durationOrNull(0L))
        assertEquals(42L, durationOrNull(42L))
    }

    @Test
    fun `playback state names remain stable for persisted snapshots`() {
        assertEquals("idle", playbackStateName(Player.STATE_IDLE))
        assertEquals("buffering", playbackStateName(Player.STATE_BUFFERING))
        assertEquals("ready", playbackStateName(Player.STATE_READY))
        assertEquals("completed", playbackStateName(Player.STATE_ENDED))
        assertEquals("unknown", playbackStateName(Int.MIN_VALUE))
    }

    @Test
    fun `deferred session registration does not eagerly create a player`() {
        assertEquals(false, shouldCreatePlayerForConfiguration(true, false))
        assertEquals(true, shouldCreatePlayerForConfiguration(false, false))
        assertEquals(true, shouldCreatePlayerForConfiguration(true, true))
    }

    @Test
    fun `editing effects and queue of a deferred session does not create a player`() {
        val session = NativePlaybackSession(
            sessionId = "idle", createPlayer = { _, _ -> error("Idle session created a player") },
            logWarn = { _, _, _ -> }, elapsedRealtimeMs = { 0L }
        )
        session.applyAudioEffects(NativeAudioEffects(eqEnabled = true, channelSwapEnabled = true))
        val queue = listOf(NativeMediaItemDescriptor("/a.mp3", "file:///a.mp3", "A", null, null))
        session.updateQueue(queue, 0, true, false, false)
        assertEquals(false, session.hasPlayer())
        assertEquals("/a.mp3", session.snapshot()["path"])
        assertEquals(true, session.storedSnapshot().eqEnabled)
        assertEquals(true, session.storedSnapshot().repeatOne)
        org.junit.Assert.assertSame(session.storedSnapshot().queue, session.storedSnapshot().queue)
    }

    @Test
    fun `clearing a deferred queue removes media and progress while preserving settings`() {
        val session = NativePlaybackSession("idle", { _, _ -> error("Player created") }, { _, _, _ -> }, { 0L })
        session.updateQueue(listOf(NativeMediaItemDescriptor("/a", "file:///a", "A", null, null)), 0, false, false, false)
        session.applyVolume(0.4f)
        session.seekTo(1_000L)
        session.clearQueue()
        assertEquals(null, session.snapshot()["path"])
        assertEquals(0L, session.snapshot()["positionMs"])
        assertEquals(emptyList<StoredNativePlaybackQueueItem>(), session.storedSnapshot().queue)
        assertEquals(0.4f, session.volume)
    }

    @Test
    fun `deferred queue preserves the selected occurrence of a repeated media path`() {
        val session = NativePlaybackSession("idle", { _, _ -> error("Player created") }, { _, _, _ -> }, { 0L })
        val descriptor = NativeMediaItemDescriptor("/a", "file:///a", "A", null, null)
        session.updateQueue(listOf(descriptor, descriptor), 1, false, false, false)
        assertEquals(1, session.snapshot()["queueIndex"])
        assertEquals(1, session.storedSnapshot().queueStartIndex)
    }

    @Test
    fun `audio effects sync only when audio session id changes`() {
        assertEquals(true, shouldSyncAudioSessionState(C.AUDIO_SESSION_ID_UNSET, 42))
        assertEquals(false, shouldSyncAudioSessionState(42, 42))
        assertEquals(true, shouldSyncAudioSessionState(42, 84))
        assertEquals(false, shouldSyncAudioSessionState(42, C.AUDIO_SESSION_ID_UNSET))
    }

    @Test
    fun `progress ticker skips paused sessions without playback intent`() {
        assertEquals(false, shouldIncludeInProgressHeartbeat(false, false))
        assertEquals(true, shouldIncludeInProgressHeartbeat(true, true))
        assertEquals(true, shouldIncludeInProgressHeartbeat(false, true))
    }

    @Test
    fun `progress anchor extrapolates position using playback speed`() {
        val normal = progressAnchor(speed = 1f).updateAt(2500L)
        val faster = progressAnchor(speed = 1.5f).updateAt(2500L)

        assertEquals(2500L, normal?.positionMs)
        assertEquals(3250L, faster?.positionMs)
    }

    @Test
    fun `progress anchor stays fixed while buffering or paused`() {
        val buffering = progressAnchor(
            isPlaying = false,
            playWhenReady = true
        ).updateAt(5000L)
        val paused = progressAnchor(
            isPlaying = false,
            playWhenReady = false
        ).updateAt(5000L)

        assertEquals(1000L, buffering?.positionMs)
        assertNull(paused)
    }

    @Test
    fun `progress anchor clamps position and buffer to duration`() {
        val update = progressAnchor(
            positionMs = 4500L,
            bufferedPositionMs = 6000L,
            durationMs = 5000L
        ).updateAt(3000L)

        assertEquals(5000L, update?.positionMs)
        assertEquals(5000L, update?.bufferedPositionMs)
    }

    @Test
    fun `progress event only includes sessions with playback intent`() {
        val event = buildNativePlaybackProgressEvent(
            listOf(
                progressAnchor(sessionId = "playing"),
                progressAnchor(
                    sessionId = "paused",
                    isPlaying = false,
                    playWhenReady = false
                )
            ),
            nowElapsedRealtimeMs = 1500L
        )
        val updates = event?.get("updates") as List<*>
        val update = updates.single() as Map<*, *>

        assertEquals("progress", event["eventType"])
        assertEquals("playing", update["sessionId"])
        assertEquals(1500L, update["nativeElapsedRealtimeMs"])
    }

    @Test
    fun `exclusive playback pauses only other sessions with playback intent`() {
        assertEquals(
            listOf("playing", "buffering"),
            exclusivePlaybackSessionIdsToPause(
                targetSessionId = "target",
                sessionPlaybackIntent = linkedMapOf(
                    "target" to true,
                    "playing" to true,
                    "paused" to false,
                    "buffering" to true
                )
            )
        )
    }

    @Test
    fun `noise reduction curve stays conservative for ASMR details`() {
        assertEquals(NOISE_REDUCTION_LOW_GAIN_DB, noiseReductionGainFor(60), 0.001f)
        assertEquals(0f, noiseReductionGainFor(1000), 0.001f)
        assertEquals(0f, noiseReductionGainFor(3000), 0.001f)
        assertEquals(NOISE_REDUCTION_HIGH_GAIN_DB, noiseReductionGainFor(12000), 0.001f)
    }

    @Test
    fun `volume normalization tuning avoids fixed boost`() {
        assertEquals(2.0f, VOLUME_NORMALIZATION_MBC_RATIO, 0.001f)
        assertEquals(-12f, VOLUME_NORMALIZATION_MBC_THRESHOLD_DB, 0.001f)
        assertEquals(-2f, VOLUME_NORMALIZATION_LIMITER_THRESHOLD_DB, 0.001f)
        assertEquals(0f, VOLUME_NORMALIZATION_OUTPUT_GAIN_DB, 0.001f)
    }

    @Test
    fun `focus duck multiplier is independent from user volume and fade`() {
        assertEquals(
            0.1f,
            effectiveNativePlaybackVolume(
                playerVolume = 1f,
                fadeMultiplier = 0.5f,
                focusDuckMultiplier = 0.2f
            ),
            0.001f
        )
        assertEquals(
            0.5f,
            effectiveNativePlaybackVolume(
                playerVolume = 1f,
                fadeMultiplier = 0.5f,
                focusDuckMultiplier = 1f
            ),
            0.001f
        )
    }

    @Test
    fun `skip silence responds to short low level gaps`() {
        assertEquals(250_000L, STRICT_SKIP_SILENCE_MIN_DURATION_US)
        assertEquals(32.toShort(), STRICT_SKIP_SILENCE_THRESHOLD_LEVEL)
    }

    @Test
    fun `audio effects reprepare only when stereo processing enters or leaves the pipeline`() {
        val controller = NativeAudioEffectsController()
        assertEquals(false, controller.apply(NativeAudioEffects(skipSilenceEnabled = true)))
        assertEquals(true, controller.apply(NativeAudioEffects(panning = 0.5f)))
        assertEquals(false, controller.apply(NativeAudioEffects(channelSwapEnabled = true)))
        assertEquals(false, controller.apply(NativeAudioEffects(panning = -0.5f, channelSwapEnabled = true)))
        assertEquals(false, controller.apply(NativeAudioEffects(panning = -0.5f)))
        assertEquals(true, controller.apply(NativeAudioEffects()))
        assertEquals(true, controller.apply(NativeAudioEffects(panning = 0.5f, channelSwapEnabled = true)))
        assertEquals(true, controller.apply(NativeAudioEffects()))
    }

    @Test
    fun `subthreshold balance and unchanged effects never reprepare`() {
        val controller = NativeAudioEffectsController()
        val effects = NativeAudioEffects(panning = 0.0009f, skipSilenceEnabled = true)
        assertEquals(false, controller.apply(effects))
        assertEquals(false, controller.apply(effects))
    }

    @Test
    fun `front back position stays live through neutral until player release`() {
        val controller = NativeAudioEffectsController { testSpatialResponses() }
        assertTrue(controller.apply(NativeAudioEffects(frontBack = 0.5f)))
        assertEquals(false, controller.apply(NativeAudioEffects(frontBack = -0.5f)))
        assertEquals(-0.5, controller.snapshot()["frontBack"])
        assertEquals(false, controller.apply(NativeAudioEffects()))
        controller.release()
        assertTrue(controller.apply(NativeAudioEffects(frontBack = 0.5f)))
    }

    @Test
    fun `audio effects controller snapshot preserves enabled effects`() {
        val controller = NativeAudioEffectsController()
        controller.apply(
            NativeAudioEffects(
                noiseReductionEnabled = true,
                eqEnabled = true,
                eqPresetId = "voice",
                eqBandLevels = mapOf(1000 to 3.5f),
                volumeNormalizationEnabled = true,
                panning = -0.25f
            )
        )

        val snapshot = controller.snapshot()
        val levels = snapshot["eqBandLevels"] as List<*>
        val level = levels.single() as Map<*, *>

        assertEquals(true, snapshot["noiseReductionEnabled"])
        assertEquals(true, snapshot["eqEnabled"])
        assertEquals("voice", snapshot["eqPresetId"])
        assertEquals(1000, level["frequencyHz"])
        assertEquals(3.5, level["gainDb"])
        assertEquals(true, snapshot["volumeNormalizationEnabled"])
        assertEquals(-0.25, snapshot["panning"])
    }

    @Test
    fun `volume balance processor stays out of default playback path`() {
        val stereo16Bit = AudioProcessor.AudioFormat(48000, 2, C.ENCODING_PCM_16BIT)
        val mono16Bit = AudioProcessor.AudioFormat(48000, 1, C.ENCODING_PCM_16BIT)

        val defaultProcessor = VolumeBalanceAudioProcessor()
        assertEquals(AudioProcessor.AudioFormat.NOT_SET, defaultProcessor.configure(stereo16Bit))
        assertEquals(false, shouldProcessVolumeBalance(0f))
        assertEquals(false, shouldProcessVolumeBalance(0.0005f))
        assertEquals(true, shouldProcessVolumeBalance(0.5f))

        val monoChannelSwapProcessor = VolumeBalanceAudioProcessor().apply {
            controls = VolumeBalanceAudioProcessor.Controls(channelSwapEnabled = true)
        }
        assertEquals(AudioProcessor.AudioFormat.NOT_SET, monoChannelSwapProcessor.configure(mono16Bit))

        val stereoChannelSwapProcessor = VolumeBalanceAudioProcessor().apply {
            controls = VolumeBalanceAudioProcessor.Controls(channelSwapEnabled = true)
        }
        assertEquals(stereo16Bit, stereoChannelSwapProcessor.configure(stereo16Bit))
    }

    @Test
    fun `stereo processor swaps pcm channels without affecting mono configuration`() {
        val processor = VolumeBalanceAudioProcessor().apply {
            controls = VolumeBalanceAudioProcessor.Controls(channelSwapEnabled = true)
        }
        val stereo16Bit = AudioProcessor.AudioFormat(48000, 2, C.ENCODING_PCM_16BIT)
        assertEquals(stereo16Bit, processor.configure(stereo16Bit))
        processor.flush()

        val input = ByteBuffer.allocateDirect(4).order(ByteOrder.nativeOrder())
        input.putShort(120)
        input.putShort((-340).toShort())
        input.flip()
        processor.queueInput(input)

        val output = processor.output.order(ByteOrder.nativeOrder())
        assertEquals((-340).toShort(), output.short)
        assertEquals(120.toShort(), output.short)
    }

    @Test
    fun `stereo processor keeps left and right samples independent while balancing`() {
        val processor = VolumeBalanceAudioProcessor().apply {
            controls = VolumeBalanceAudioProcessor.Controls(panning = 0.5f)
        }
        val stereo16Bit = AudioProcessor.AudioFormat(48000, 2, C.ENCODING_PCM_16BIT)
        assertEquals(stereo16Bit, processor.configure(stereo16Bit))
        processor.flush()

        val input = ByteBuffer.allocateDirect(4).order(ByteOrder.nativeOrder())
        input.putShort(120)
        input.putShort((-340).toShort())
        input.flip()
        processor.queueInput(input)

        val output = processor.output.order(ByteOrder.nativeOrder())
        assertEquals(60.toShort(), output.short)
        assertEquals((-340).toShort(), output.short)
    }

    @Test
    fun `spatial processor renders both directions between channel swap and balance`() {
        val processor = VolumeBalanceAudioProcessor().apply {
            controls = VolumeBalanceAudioProcessor.Controls(
                panning = 1f,
                channelSwapEnabled = true,
                frontBack = 1f,
                spatialResponses = testSpatialResponses()
            )
        }
        val stereo = AudioProcessor.AudioFormat(48000, 2, C.ENCODING_PCM_16BIT)
        assertEquals(stereo, processor.configure(stereo))
        processor.flush(AudioProcessor.StreamMetadata.DEFAULT)

        fun render(position: Float): Pair<Short, Short> {
            processor.controls = processor.controls.copy(frontBack = position)
            val input = ByteBuffer.allocateDirect(1_001 * 4).order(ByteOrder.nativeOrder())
            repeat(1_001) { input.putShort(256).putShort(1024) }
            input.flip()
            processor.queueInput(input)
            val output = processor.output.order(ByteOrder.nativeOrder())
            return output.getShort(output.limit() - 4) to output.getShort(output.limit() - 2)
        }

        assertEquals(0.toShort() to 416.toShort(), render(1f))
        assertEquals(0.toShort() to 576.toShort(), render(-1f))
        assertEquals(0.toShort() to 256.toShort(), render(0f))
    }

    @Test
    fun `neutral spatial processing passes through exact PCM float samples after fading out`() {
        val processor = VolumeBalanceAudioProcessor().apply {
            controls = VolumeBalanceAudioProcessor.Controls(
                frontBack = 1f,
                spatialResponses = testSpatialResponses()
            )
        }
        val stereo = AudioProcessor.AudioFormat(48000, 2, C.ENCODING_PCM_FLOAT)
        assertEquals(stereo, processor.configure(stereo))
        processor.flush(AudioProcessor.StreamMetadata.DEFAULT)

        fun render(frames: Int, sample: Int): ByteBuffer {
            val buffer = ByteBuffer.allocateDirect(frames * 8).order(ByteOrder.nativeOrder())
            repeat(frames) { buffer.putInt(sample).putInt(Int.MIN_VALUE) }
            buffer.flip()
            processor.queueInput(buffer)
            assertEquals(0, buffer.remaining())
            return processor.output.order(ByteOrder.nativeOrder())
        }

        render(500, 0.5f.toRawBits())
        processor.controls = processor.controls.copy(frontBack = 0f)
        val fade = render(500, 0.5f.toRawBits())
        assertTrue(fade.float != 0.5f)
        val dry = render(2, 0x7fc01234)
        repeat(2) {
            assertEquals(0x7fc01234, dry.int)
            assertEquals(Int.MIN_VALUE, dry.int)
        }
    }

    @Test
    fun `spatial convolution limits both ears together and clears history on flush`() {
        val direct = floatArrayOf(1f, 1f)
        val cross = floatArrayOf(0.5f, 0.5f)
        val response = arrayOf(direct, cross, cross, direct)
        val renderer = StereoSpatialRenderer(StereoSpatialResponses(48000, response, response), 48000)
        repeat(481) { renderer.process(1f, 0f, 1f, 1f) }
        assertEquals(1f, renderer.left)
        assertEquals(0.5f, renderer.right)
        renderer.process(0f, 0f, 1f, 1f)
        assertEquals(1f, renderer.left)
        renderer.clear()
        renderer.process(0f, 0f, 1f, 1f)
        assertEquals(0f, renderer.left)
        assertEquals(0f, renderer.right)
    }

    @Test
    fun `spatial response delay stays constant when decoding high rate PCM`() {
        val direct = floatArrayOf(0f, 1f)
        val cross = FloatArray(2)
        val response = arrayOf(direct, cross, cross, direct)
        val renderer = StereoSpatialRenderer(StereoSpatialResponses(48000, response, response), 192000)
        repeat(2_000) { renderer.process(0f, 0f, 1f, 1f) }

        renderer.process(0.5f, -0.25f, 1f, 1f)
        assertEquals(0f, renderer.left)
        repeat(3) {
            renderer.process(0f, 0f, 1f, 1f)
            assertEquals(0f, renderer.left)
        }
        renderer.process(0f, 0f, 1f, 1f)
        assertEquals(0.5f, renderer.left)
        assertEquals(-0.25f, renderer.right)
    }

    @Test
    fun `spatial response filters out frequencies above the new Nyquist limit`() {
        val direct = FloatArray(120) { tap ->
            val window = 0.5 - 0.5 * cos(2 * PI * tap / 119)
            (window * cos(2 * PI * tap / 3)).toFloat()
        }
        val cross = FloatArray(direct.size)
        val response = arrayOf(direct, cross, cross, direct)
        val renderer = StereoSpatialRenderer(StereoSpatialResponses(48000, response, response), 16000)

        repeat(161) { renderer.process(0.5f, 0f, 1f, 1f) }
        assertTrue(abs(renderer.left) < 0.01f)
        assertEquals(0f, renderer.right)
    }

    private fun testSpatialResponses() = StereoSpatialResponses(
        48000,
        arrayOf(floatArrayOf(0.625f), floatArrayOf(0.25f), floatArrayOf(0.25f), floatArrayOf(0.625f)),
        arrayOf(floatArrayOf(0.25f), floatArrayOf(0.5f), floatArrayOf(0.5f), floatArrayOf(0.25f))
    )

    @Test
    fun `publishing session state retries audio session sync before snapshot`() {
        val events = mutableListOf<String>()
        val session = object : NativePlaybackSessionSnapshotSource {
            override fun currentAudioSessionId(): Int = 42

            override fun syncAudioSessionState(audioSessionId: Int) {
                events += "sync:$audioSessionId"
            }

            override fun snapshot(): Map<String, Any?> {
                events += "snapshot"
                return mapOf("sessionId" to "session")
            }
        }

        var listenerSnapshot: Map<String, Any?>? = null
        val publishedSnapshot = publishNativePlaybackSessionState(
            session,
            listOf { snapshot: Map<String, Any?> ->
                listenerSnapshot = snapshot
                events += "listener:${snapshot["sessionId"]}"
            }
        )

        assertEquals(listOf("sync:42", "snapshot", "listener:session"), events)
        assertSame(publishedSnapshot, listenerSnapshot)
    }

    @Test
    fun `publishing session state still emits snapshot when listener fails`() {
        val session = object : NativePlaybackSessionSnapshotSource {
            override fun currentAudioSessionId(): Int = C.AUDIO_SESSION_ID_UNSET

            override fun syncAudioSessionState(audioSessionId: Int) = Unit

            override fun snapshot(): Map<String, Any?> = mapOf("sessionId" to "session")
        }

        var reached = false
        publishNativePlaybackSessionState(
            session,
            listOf { _: Map<String, Any?> -> throw RuntimeException("boom") }
        )
        publishNativePlaybackSessionState(
            session,
            listOf { _: Map<String, Any?> -> reached = true }
        )

        assertTrue(reached)
    }

    @Test
    fun `spatial renderer caches prepared kernels per responses and sample rate and honors frontBack threshold`() {
        val responses = testSpatialResponses()
        val first44k = StereoSpatialRenderer.getOrPrepare(responses, 44100)
        val second44k = StereoSpatialRenderer.getOrPrepare(responses, 44100)
        val first48k = StereoSpatialRenderer.getOrPrepare(responses, 48000)
        assertSame(first44k, second44k)
        assertTrue(first44k !== first48k)

        var loaded = 0
        val controller = NativeAudioEffectsController {
            loaded++
            responses
        }
        assertEquals(false, shouldProcessFrontBack(0f))
        assertEquals(false, shouldProcessFrontBack(0.0005f))
        assertEquals(true, shouldProcessFrontBack(0.001f))
        assertEquals(false, controller.apply(NativeAudioEffects(frontBack = 0.0005f)))
        assertEquals(0, loaded)
        assertEquals(true, controller.apply(NativeAudioEffects(frontBack = 0.25f)))
        assertEquals(1, loaded)
    }

    private fun progressAnchor(
        sessionId: String = "session",
        positionMs: Long = 1000L,
        bufferedPositionMs: Long = 4000L,
        durationMs: Long? = 10000L,
        speed: Float = 1f,
        isPlaying: Boolean = true,
        playWhenReady: Boolean = true
    ): NativePlaybackProgressAnchor = NativePlaybackProgressAnchor(
        sessionId = sessionId,
        positionMs = positionMs,
        bufferedPositionMs = bufferedPositionMs,
        durationMs = durationMs,
        capturedElapsedRealtimeMs = 1000L,
        speed = speed,
        isPlaying = isPlaying,
        playWhenReady = playWhenReady
    )
}
