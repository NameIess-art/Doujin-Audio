package com.nameless.audio

import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.audio.AudioProcessor
import org.junit.Assert.assertEquals
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
    fun `volume balance processor stays out of default playback path`() {
        val stereo16Bit = AudioProcessor.AudioFormat(48000, 2, C.ENCODING_PCM_16BIT)

        val defaultProcessor = VolumeBalanceAudioProcessor()
        assertEquals(AudioProcessor.AudioFormat.NOT_SET, defaultProcessor.configure(stereo16Bit))
        assertEquals(false, shouldProcessVolumeBalance(0f))
        assertEquals(false, shouldProcessVolumeBalance(0.0005f))
        assertEquals(true, shouldProcessVolumeBalance(0.5f))
    }
}
