package com.nameless.audio.player.common

import com.nameless.audio.player.session.*

internal object NativePlaybackCommandPayloads {
    fun parseQueue(rawQueue: Any?): List<NativeMediaItemDescriptor> {
        val queue = rawQueue as? List<*> ?: return emptyList()
        return queue.mapNotNull { rawItem ->
            val item = rawItem as? Map<*, *> ?: return@mapNotNull null
            val uri = item["uri"] as? String ?: return@mapNotNull null
            NativeMediaItemDescriptor(
                path = item["path"] as? String ?: uri,
                uri = uri,
                title = item["title"] as? String ?: "Audio",
                subtitle = item["subtitle"] as? String,
                artUri = item["artUri"] as? String
            )
        }
    }

    fun parseAudioEffects(rawEffects: Map<*, *>): NativeAudioEffects {
        return NativeAudioEffects(
            skipSilenceEnabled = rawEffects["skipSilenceEnabled"] as? Boolean ?: false,
            noiseReductionEnabled = rawEffects["noiseReductionEnabled"] as? Boolean ?: false,
            eqEnabled = rawEffects["eqEnabled"] as? Boolean ?: false,
            eqPresetId = (rawEffects["eqPresetId"] as? String)?.takeIf { it.isNotBlank() },
            eqBandLevels = parseEqBandLevels(rawEffects["eqBandLevels"]),
            channelSwapEnabled = rawEffects["channelSwapEnabled"] as? Boolean ?: false,
            volumeNormalizationEnabled = rawEffects["volumeNormalizationEnabled"] as? Boolean
                ?: false,
            panning = (rawEffects["panning"] as? Number)?.toFloat() ?: 0f
        )
    }

    private fun parseEqBandLevels(rawLevels: Any?): Map<Int, Float> {
        val levels = rawLevels as? List<*> ?: return emptyMap()
        return buildMap {
            levels.forEach { rawItem ->
                val item = rawItem as? Map<*, *> ?: return@forEach
                val frequencyHz = (item["frequencyHz"] as? Number)?.toInt() ?: return@forEach
                val gainDb = (item["gainDb"] as? Number)?.toFloat() ?: return@forEach
                if (frequencyHz > 0) put(frequencyHz, gainDb)
            }
        }
    }
}
