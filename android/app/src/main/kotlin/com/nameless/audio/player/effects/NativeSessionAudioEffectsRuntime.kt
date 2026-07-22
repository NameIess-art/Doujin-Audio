@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.nameless.audio.player.effects

import com.nameless.audio.player.session.*

import android.media.audiofx.DynamicsProcessing
import android.media.audiofx.Equalizer
import android.media.audiofx.LoudnessEnhancer
import android.os.Build
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.exoplayer.ExoPlayer
import kotlin.math.abs
import kotlin.math.roundToInt

internal class NativeSessionAudioEffectsRuntime(
    private val logWarn: (String, RuntimeException) -> Unit
) {
    private val controller = NativeAudioEffectsController()
    private var loudnessEnhancer: LoudnessEnhancer? = null
    private var loudnessEnhancerSessionId: Int = C.AUDIO_SESSION_ID_UNSET
    private var equalizer: Equalizer? = null
    private var equalizerSessionId: Int = C.AUDIO_SESSION_ID_UNSET
    private var equalizerCreateFailed = false
    private var dynamicsProcessing: DynamicsProcessing? = null
    private var dynamicsProcessingSessionId: Int = C.AUDIO_SESSION_ID_UNSET

    var channelSwapEnabled: Boolean
        get() = controller.channelSwapEnabled
        set(value) { controller.channelSwapEnabled = value }
    var skipSilenceEnabled: Boolean
        get() = controller.skipSilenceEnabled
        set(value) { controller.skipSilenceEnabled = value }
    var noiseReductionEnabled: Boolean
        get() = controller.noiseReductionEnabled
        set(value) { controller.noiseReductionEnabled = value }
    var eqEnabled: Boolean
        get() = controller.eqEnabled
        set(value) { controller.eqEnabled = value }
    var eqPresetId: String?
        get() = controller.eqPresetId
        set(value) { controller.eqPresetId = value }
    var eqBandLevels: Map<Int, Float>
        get() = controller.eqBandLevels
        set(value) { controller.eqBandLevels = value }
    var volumeNormalizationEnabled: Boolean
        get() = controller.volumeNormalizationEnabled
        set(value) { controller.volumeNormalizationEnabled = value }
    var panning: Float
        get() = controller.panning
        set(value) { controller.panning = value }

    fun audioProcessors(): Array<AudioProcessor> = controller.audioProcessors()

    fun applyChannelMap() = controller.applyChannelMap()

    fun apply(effects: NativeAudioEffects): NativeAudioEffectsChange = controller.apply(effects)

    fun applyToPlayer(player: ExoPlayer) {
        controller.applyToPlayer(
            player,
            syncEqualizer = ::syncEqualizer,
            syncDynamicsProcessing = ::syncDynamicsProcessing
        )
    }

    fun syncAudioSession(audioSessionId: Int, volume: Float) {
        syncLoudnessEnhancer(audioSessionId, volume)
        syncEqualizer(audioSessionId)
        syncDynamicsProcessing(audioSessionId)
    }

    fun syncLoudnessEnhancer(audioSessionId: Int, volume: Float) {
        syncLoudnessEnhancerInternal(audioSessionId, volume)
    }

    fun snapshot(): Map<String, Any?> = controller.snapshot()

    fun eqCapabilitiesSnapshot(): Map<String, Any?> = buildEqCapabilitiesSnapshot()

    fun release() {
        releaseLoudnessEnhancer()
        releaseEqualizer()
        releaseDynamicsProcessing()
    }

    private fun syncLoudnessEnhancerInternal(audioSessionId: Int, volume: Float) {
        val targetGain = PlaybackVolumeMapper.boostGainMillibels(volume)
        if (targetGain <= 0 || audioSessionId == C.AUDIO_SESSION_ID_UNSET) {
            releaseLoudnessEnhancer()
            return
        }

        val enhancer = if (loudnessEnhancerSessionId == audioSessionId) {
            loudnessEnhancer
        } else {
            releaseLoudnessEnhancer()
            try {
                LoudnessEnhancer(audioSessionId).also {
                    loudnessEnhancer = it
                    loudnessEnhancerSessionId = audioSessionId
                }
            } catch (e: RuntimeException) {
                logWarn("loudness_enhancer_create_failed audioSessionId=$audioSessionId", e)
                null
            }
        } ?: return

        try {
            enhancer.setTargetGain(targetGain)
            enhancer.setEnabled(true)
        } catch (e: RuntimeException) {
            logWarn("loudness_enhancer_apply_failed gain=$targetGain", e)
            releaseLoudnessEnhancer()
        }
    }

    private fun releaseLoudnessEnhancer() {
        val enhancer = loudnessEnhancer ?: return
        loudnessEnhancer = null
        loudnessEnhancerSessionId = C.AUDIO_SESSION_ID_UNSET
        try {
            enhancer.setEnabled(false)
        } catch (_: RuntimeException) {
        }
        try {
            enhancer.release()
        } catch (_: RuntimeException) {
        }
    }

    private fun syncEqualizer(audioSessionId: Int) {
        val needsEqualizer = eqEnabled || noiseReductionEnabled
        if (!needsEqualizer || audioSessionId == C.AUDIO_SESSION_ID_UNSET) {
            releaseEqualizer()
            return
        }
        val nextEqualizer = if (equalizerSessionId == audioSessionId) {
            equalizer
        } else {
            releaseEqualizer()
            equalizerCreateFailed = false
            try {
                Equalizer(0, audioSessionId).also {
                    equalizer = it
                    equalizerSessionId = audioSessionId
                }
            } catch (e: RuntimeException) {
                equalizerCreateFailed = true
                logWarn("equalizer_create_failed audioSessionId=$audioSessionId", e)
                null
            }
        } ?: return

        try {
            applyEqualizerBandLevels(nextEqualizer)
            nextEqualizer.enabled = true
        } catch (e: RuntimeException) {
            logWarn("equalizer_apply_failed", e)
            releaseEqualizer()
            equalizerCreateFailed = true
        }
    }

    private fun applyEqualizerBandLevels(eq: Equalizer) {
        val bandCount = eq.numberOfBands.toInt()
        if (bandCount <= 0) return
        val range = eq.bandLevelRange
        val minDb = range[0] / 100f
        val maxDb = range[1] / 100f
        val levelsByBand = FloatArray(bandCount)
        if (eqEnabled) {
            eqBandLevels.forEach { (frequencyHz, gainDb) ->
                val band = nearestEqualizerBand(eq, frequencyHz)
                levelsByBand[band] = (levelsByBand[band] + gainDb).coerceIn(minDb, maxDb)
            }
        }
        if (noiseReductionEnabled) {
            for (band in 0 until bandCount) {
                val frequencyHz = eq.getCenterFreq(band.toShort()) / 1000
                val overlay = noiseReductionGainFor(frequencyHz)
                if (overlay != 0f) {
                    levelsByBand[band] = (levelsByBand[band] + overlay).coerceIn(minDb, maxDb)
                }
            }
        }
        for (band in 0 until bandCount) {
            eq.setBandLevel(
                band.toShort(),
                (levelsByBand[band].coerceIn(minDb, maxDb) * 100).roundToInt().toShort()
            )
        }
    }

    private fun nearestEqualizerBand(eq: Equalizer, frequencyHz: Int): Int {
        var bestBand = 0
        var bestDistance = Int.MAX_VALUE
        for (band in 0 until eq.numberOfBands.toInt()) {
            val centerHz = eq.getCenterFreq(band.toShort()) / 1000
            val distance = abs(centerHz - frequencyHz)
            if (distance < bestDistance) {
                bestDistance = distance
                bestBand = band
            }
        }
        return bestBand
    }

    private fun releaseEqualizer() {
        val eq = equalizer ?: return
        equalizer = null
        equalizerSessionId = C.AUDIO_SESSION_ID_UNSET
        try {
            eq.enabled = false
        } catch (_: RuntimeException) {
        }
        try {
            eq.release()
        } catch (_: RuntimeException) {
        }
    }

    private fun syncDynamicsProcessing(audioSessionId: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return

        if (!volumeNormalizationEnabled || audioSessionId == C.AUDIO_SESSION_ID_UNSET) {
            releaseDynamicsProcessing()
            return
        }

        val dp = if (dynamicsProcessingSessionId == audioSessionId) {
            dynamicsProcessing
        } else {
            releaseDynamicsProcessing()
            try {
                // Conservative volume balance: light compression plus limiter, no fixed pre-gain.
                val config = DynamicsProcessing.Config.Builder(
                    DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION,
                    2, // channel count
                    false, // preEqInUse
                    0, // preEqBandCount
                    true, // mbcInUse
                    1, // mbcBandCount
                    false, // postEqInUse
                    0, // postEqBandCount
                    true // limiterInUse
                ).build()

                DynamicsProcessing(0, audioSessionId, config).also {
                    it.setMbcAllChannelsTo(DynamicsProcessing.Mbc(true, true, 1))
                    it.setMbcBandAllChannelsTo(0, DynamicsProcessing.MbcBand(
                        true,
                        20000f,
                        8f,
                        160f,
                        VOLUME_NORMALIZATION_MBC_RATIO,
                        VOLUME_NORMALIZATION_MBC_THRESHOLD_DB,
                        2f,
                        -90f,
                        1f,
                        0f,
                        VOLUME_NORMALIZATION_OUTPUT_GAIN_DB
                    ))

                    it.setLimiterAllChannelsTo(DynamicsProcessing.Limiter(
                        true,
                        true,
                        0,
                        8f,
                        120f,
                        6f,
                        VOLUME_NORMALIZATION_LIMITER_THRESHOLD_DB,
                        VOLUME_NORMALIZATION_OUTPUT_GAIN_DB
                    ))

                    dynamicsProcessing = it
                    dynamicsProcessingSessionId = audioSessionId
                }
            } catch (e: RuntimeException) {
                logWarn("dynamics_processing_create_failed audioSessionId=$audioSessionId", e)
                null
            }
        } ?: return

        try {
            dp.enabled = true
        } catch (e: RuntimeException) {
            logWarn("dynamics_processing_apply_failed", e)
            releaseDynamicsProcessing()
        }
    }

    private fun releaseDynamicsProcessing() {
        val dp = dynamicsProcessing ?: return
        dynamicsProcessing = null
        dynamicsProcessingSessionId = C.AUDIO_SESSION_ID_UNSET
        try {
            dp.enabled = false
        } catch (_: RuntimeException) {
        }
        try {
            dp.release()
        } catch (_: RuntimeException) {
        }
    }

    private fun buildEqCapabilitiesSnapshot(): Map<String, Any?> {
        val eq = equalizer
        if (eq == null || equalizerCreateFailed) {
            return mapOf("supported" to false)
        }
        return try {
            val range = eq.bandLevelRange
            mapOf(
                "supported" to true,
                "minGainDb" to range[0] / 100.0,
                "maxGainDb" to range[1] / 100.0,
                "bands" to (0 until eq.numberOfBands.toInt()).map { band ->
                    mapOf("frequencyHz" to eq.getCenterFreq(band.toShort()) / 1000)
                }
            )
        } catch (_: RuntimeException) {
            mapOf("supported" to false)
        }
    }
}
