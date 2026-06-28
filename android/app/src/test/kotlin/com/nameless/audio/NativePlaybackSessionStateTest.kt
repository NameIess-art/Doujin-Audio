package com.nameless.audio

import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.audio.AudioProcessor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull
import org.junit.Test

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
    fun `audio effects sync only when audio session id changes`() {
        assertEquals(true, shouldSyncAudioSessionState(C.AUDIO_SESSION_ID_UNSET, 42))
        assertEquals(false, shouldSyncAudioSessionState(42, 42))
        assertEquals(true, shouldSyncAudioSessionState(42, 84))
        assertEquals(false, shouldSyncAudioSessionState(42, C.AUDIO_SESSION_ID_UNSET))
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
    fun `skip silence only targets near digital silence`() {
        assertEquals(900_000L, STRICT_SKIP_SILENCE_MIN_DURATION_US)
        assertEquals(4.toShort(), STRICT_SKIP_SILENCE_THRESHOLD_LEVEL)
    }

    @Test
    fun `volume balance processor stays out of default playback path`() {
        val stereo16Bit = AudioProcessor.AudioFormat(48000, 2, C.ENCODING_PCM_16BIT)

        val defaultProcessor = VolumeBalanceAudioProcessor()
        assertEquals(AudioProcessor.AudioFormat.NOT_SET, defaultProcessor.configure(stereo16Bit))
        assertEquals(false, shouldProcessVolumeBalance(0f))
        assertEquals(false, shouldProcessVolumeBalance(0.0005f))
        assertEquals(true, shouldProcessVolumeBalance(0.5f))
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

        publishNativePlaybackSessionState(
            session,
            listOf { snapshot: Map<String, Any?> ->
                events += "listener:${snapshot["sessionId"]}"
            }
        )

        assertEquals(listOf("sync:42", "snapshot", "listener:session"), events)
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
}
