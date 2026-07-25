package com.nameless.audio

import com.nameless.audio.player.effects.*
import com.nameless.audio.player.service.*
import com.nameless.audio.player.session.*

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

class NativePlaybackSessionStateTest {
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
    fun `enabling equalizer for a paused deferred session creates a player`() {
        assertEquals(
            true,
            shouldEnsurePlayerForAudioEffects(
                effects = NativeAudioEffects(eqEnabled = true),
                hasPlayer = false
            )
        )
        assertEquals(
            false,
            shouldEnsurePlayerForAudioEffects(
                effects = NativeAudioEffects(eqEnabled = true),
                hasPlayer = true
            )
        )
        assertEquals(
            false,
            shouldEnsurePlayerForAudioEffects(
                effects = NativeAudioEffects(),
                hasPlayer = false
            )
        )
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
    fun `progress heartbeat uses screen on and five second screen off cadence`() {
        assertEquals(
            true,
            shouldPublishProgressHeartbeat(false, 6000L, 1000L, 5000L)
        )
        assertEquals(
            false,
            shouldPublishProgressHeartbeat(false, 5999L, 1000L, 5000L)
        )
        assertEquals(
            true,
            shouldPublishProgressHeartbeat(true, 1500L, 1000L, 5000L)
        )
    }

    @Test
    fun `progress heartbeat backs off its own reschedule while the screen is off`() {
        // The publish gate alone is not enough: a 500ms reschedule wakes the main
        // thread ~86k times over a 12h screen-off session under a held wake lock,
        // only to decide there is nothing to publish.
        assertEquals(500L, progressHeartbeatDelayMs(true, 500L, 5000L))
        assertEquals(5000L, progressHeartbeatDelayMs(false, 500L, 5000L))
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
    fun `audio effects controller reports reprepare-sensitive changes`() {
        val controller = NativeAudioEffectsController()
        val firstChange = controller.apply(
            NativeAudioEffects(
                skipSilenceEnabled = true,
                panning = 0.5f
            )
        )
        val repeatedChange = controller.apply(
            NativeAudioEffects(
                skipSilenceEnabled = true,
                panning = 0.5f
            )
        )

        assertEquals(true, firstChange.skipSilenceChanged)
        assertEquals(true, firstChange.panningActiveChanged)
        assertEquals(false, repeatedChange.skipSilenceChanged)
        assertEquals(false, repeatedChange.panningActiveChanged)
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
            channelSwapEnabled = true
        }
        assertEquals(AudioProcessor.AudioFormat.NOT_SET, monoChannelSwapProcessor.configure(mono16Bit))

        val stereoChannelSwapProcessor = VolumeBalanceAudioProcessor().apply {
            channelSwapEnabled = true
        }
        assertEquals(stereo16Bit, stereoChannelSwapProcessor.configure(stereo16Bit))
    }

    @Test
    fun `stereo processor swaps pcm channels without affecting mono configuration`() {
        val processor = VolumeBalanceAudioProcessor().apply {
            channelSwapEnabled = true
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
            panning = 0.5f
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
