package com.nameless.audio

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackVolumeMapperTest {
    @Test
    fun `player volume stays capped at unity while boost gain carries amplified range`() {
        assertEquals(0.75f, PlaybackVolumeMapper.playerVolume(0.75f))
        assertEquals(1.0f, PlaybackVolumeMapper.boostGain(0.75f))

        assertEquals(1.0f, PlaybackVolumeMapper.playerVolume(1.6f))
        assertEquals(1.2f, PlaybackVolumeMapper.boostGain(1.6f))

        assertEquals(1.0f, PlaybackVolumeMapper.playerVolume(2.4f))
        assertEquals(1.2f, PlaybackVolumeMapper.boostGain(2.4f))
    }
}
