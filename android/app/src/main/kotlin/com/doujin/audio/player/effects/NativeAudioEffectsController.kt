@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.doujin.audio.player.effects

import com.doujin.audio.player.session.*

import androidx.media3.common.audio.AudioProcessor
import androidx.media3.exoplayer.ExoPlayer

internal class NativeAudioEffectsController(
    private val loadSpatialResponses: (() -> StereoSpatialResponses)? = null
) {
    private val volumeBalanceAudioProcessor = VolumeBalanceAudioProcessor()
    private var spatialResponses: StereoSpatialResponses? = null

    var channelSwapEnabled: Boolean = false
    var skipSilenceEnabled: Boolean = false
    var noiseReductionEnabled: Boolean = false
    var eqEnabled: Boolean = false
    var eqPresetId: String? = null
    var eqBandLevels: Map<Int, Float> = emptyMap()
    var volumeNormalizationEnabled: Boolean = false
    var panning: Float = 0f
    var frontBack: Float = 0f
        private set

    fun audioProcessors(): Array<AudioProcessor> {
        syncProcessors()
        return arrayOf(volumeBalanceAudioProcessor)
    }

    fun applyChannelMap() {
        syncProcessors()
    }

    fun apply(effects: NativeAudioEffects): Boolean {
        val previouslyProcessingStereo = volumeBalanceAudioProcessor.controls.isActive
        if (shouldProcessFrontBack(effects.frontBack) && spatialResponses == null) {
            spatialResponses = loadSpatialResponses?.invoke()
        }
        channelSwapEnabled = effects.channelSwapEnabled
        skipSilenceEnabled = effects.skipSilenceEnabled
        noiseReductionEnabled = effects.noiseReductionEnabled
        eqEnabled = effects.eqEnabled
        eqPresetId = effects.eqPresetId
        eqBandLevels = effects.eqBandLevels
        volumeNormalizationEnabled = effects.volumeNormalizationEnabled
        panning = effects.panning
        frontBack = effects.frontBack
        syncProcessors()
        // Live parameters are read per buffer; only changing pipeline membership
        // requires the player to configure its audio processors again.
        return previouslyProcessingStereo != volumeBalanceAudioProcessor.controls.isActive
    }

    fun release() {
        if (!shouldProcessFrontBack(frontBack)) {
            spatialResponses = null
            syncProcessors()
        }
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
            "panning" to panning.toDouble(),
            "frontBack" to frontBack.toDouble()
        )
    }

    private fun syncProcessors() {
        volumeBalanceAudioProcessor.controls = VolumeBalanceAudioProcessor.Controls(
            panning = panning,
            channelSwapEnabled = channelSwapEnabled,
            frontBack = frontBack,
            spatialResponses = spatialResponses
        )
    }
}
