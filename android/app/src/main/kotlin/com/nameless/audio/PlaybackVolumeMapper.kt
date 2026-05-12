package com.nameless.audio

object PlaybackVolumeMapper {
    private const val minVolume = 0f
    private const val unityVolume = 1f
    private const val maxVolume = 1.2f

    fun normalize(volume: Float): Float {
        return volume.coerceIn(minVolume, maxVolume)
    }

    fun playerVolume(volume: Float): Float {
        return normalize(volume).coerceAtMost(unityVolume)
    }

    fun boostGain(volume: Float): Float {
        return normalize(volume).coerceAtLeast(unityVolume)
    }
}
