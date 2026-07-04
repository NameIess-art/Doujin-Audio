package com.nameless.audio

import androidx.media3.common.audio.AudioProcessor
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.ChannelMappingAudioProcessor
import androidx.media3.exoplayer.audio.SilenceSkippingAudioProcessor
import kotlin.math.abs

internal data class NativeAudioEffectsChange(
    val panningActiveChanged: Boolean,
    val skipSilenceChanged: Boolean
)

internal class NativeAudioEffectsController {
    private val channelMappingAudioProcessor = ChannelMappingAudioProcessor()
    private val volumeBalanceAudioProcessor = VolumeBalanceAudioProcessor()

    var channelSwapEnabled: Boolean = false
    var skipSilenceEnabled: Boolean = false
    var noiseReductionEnabled: Boolean = false
    var eqEnabled: Boolean = false
    var eqPresetId: String? = null
    var eqBandLevels: Map<Int, Float> = emptyMap()
    var volumeNormalizationEnabled: Boolean = false
    var panning: Float = 0f

    fun audioProcessors(): Array<AudioProcessor> {
        syncProcessors()
        return arrayOf(
            channelMappingAudioProcessor,
            volumeBalanceAudioProcessor
        )
    }

    fun applyChannelMap() {
        channelMappingAudioProcessor.setChannelMap(
            if (channelSwapEnabled) {
                intArrayOf(1, 0)
            } else {
                intArrayOf(0, 1)
            }
        )
    }

    fun apply(effects: NativeAudioEffects): NativeAudioEffectsChange {
        val previousPanningActive = isPanningActive()
        val previousSkipSilenceEnabled = skipSilenceEnabled
        channelSwapEnabled = effects.channelSwapEnabled
        skipSilenceEnabled = effects.skipSilenceEnabled
        noiseReductionEnabled = effects.noiseReductionEnabled
        eqEnabled = effects.eqEnabled
        eqPresetId = effects.eqPresetId
        eqBandLevels = effects.eqBandLevels
        volumeNormalizationEnabled = effects.volumeNormalizationEnabled
        panning = effects.panning
        syncProcessors()
        return NativeAudioEffectsChange(
            panningActiveChanged = previousPanningActive != isPanningActive(),
            skipSilenceChanged = previousSkipSilenceEnabled != skipSilenceEnabled
        )
    }

    fun applyToPlayer(
        player: ExoPlayer,
        syncEqualizer: (Int) -> Unit,
        syncDynamicsProcessing: (Int) -> Unit
    ) {
        player.setSkipSilenceEnabled(skipSilenceEnabled)
        syncProcessors()
        syncEqualizer(player.audioSessionId)
        syncDynamicsProcessing(player.audioSessionId)
    }

    fun snapshot(): Map<String, Any?> {
        return mapOf(
            "skipSilenceEnabled" to skipSilenceEnabled,
            "noiseReductionEnabled" to noiseReductionEnabled,
            "eqEnabled" to eqEnabled,
            "eqPresetId" to eqPresetId,
            "eqBandLevels" to eqBandLevels.map { (frequencyHz, gainDb) ->
                mapOf("frequencyHz" to frequencyHz, "gainDb" to gainDb.toDouble())
            },
            "volumeNormalizationEnabled" to volumeNormalizationEnabled,
            "panning" to panning.toDouble()
        )
    }

    private fun syncProcessors() {
        volumeBalanceAudioProcessor.panning = panning
        applyChannelMap()
    }

    private fun isPanningActive(): Boolean = abs(panning) >= 0.001f
}
