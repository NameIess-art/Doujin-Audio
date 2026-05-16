package com.nameless.audio

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackVolumeMapperTest {
    @Test
    fun `player volume stays capped at unity while boost gain carries amplified range`() {
        assertEquals(0.75f, PlaybackVolumeMapper.playerVolume(0.75f))
        assertEquals(1.0f, PlaybackVolumeMapper.boostGain(0.75f))
        assertEquals(0, PlaybackVolumeMapper.boostGainMillibels(0.75f))

        assertEquals(1.0f, PlaybackVolumeMapper.playerVolume(1.2f))
        assertEquals(1.2f, PlaybackVolumeMapper.boostGain(1.2f))
        assertEquals(158, PlaybackVolumeMapper.boostGainMillibels(1.2f))

        assertEquals(1.0f, PlaybackVolumeMapper.playerVolume(2.0f))
        assertEquals(2.0f, PlaybackVolumeMapper.boostGain(2.0f))
        assertEquals(602, PlaybackVolumeMapper.boostGainMillibels(2.0f))

        // Values above maxVolume are clamped to maxVolume (2.0).
        assertEquals(1.0f, PlaybackVolumeMapper.playerVolume(2.4f))
        assertEquals(2.0f, PlaybackVolumeMapper.boostGain(2.4f))
        assertEquals(602, PlaybackVolumeMapper.boostGainMillibels(2.4f))
    }
}
