package com.nameless.audio

import kotlin.math.log10
import kotlin.math.roundToInt

object PlaybackVolumeMapper {
    private const val minVolume = 0f
    private const val unityVolume = 1f
    private const val maxVolume = 2f

    fun normalize(volume: Float): Float {
        return volume.coerceIn(minVolume, maxVolume)
    }

    fun playerVolume(volume: Float): Float {
        return normalize(volume).coerceAtMost(unityVolume)
    }

    fun boostGain(volume: Float): Float {
        return normalize(volume).coerceAtLeast(unityVolume)
    }

    fun boostGainMillibels(volume: Float): Int {
        val gain = boostGain(volume)
        if (gain <= unityVolume) return 0
        return (20.0 * log10(gain.toDouble()) * 100.0).roundToInt()
    }
}
