package com.nameless.audio.player.common

import com.nameless.audio.player.session.*
import java.net.URI

internal data class NativePrepareSessionArguments(
    val sessionId: String,
    val uri: String,
    val path: String,
    val title: String,
    val subtitle: String?,
    val artUri: String?,
    val startPositionMs: Long,
    val autoPlay: Boolean,
    val volume: Float,
    val speed: Float,
    val audioEffects: NativeAudioEffects,
    val repeatOne: Boolean,
    val queue: List<NativeMediaItemDescriptor>,
    val queueStartIndex: Int,
    val repeatAll: Boolean,
    val shuffle: Boolean,
    val deferPlayerCreation: Boolean
)

internal data class NativeRepeatOneArguments(
    val sessionId: String,
    val repeatOne: Boolean,
    val queue: List<NativeMediaItemDescriptor>,
    val queueStartIndex: Int,
    val repeatAll: Boolean,
    val shuffle: Boolean
)

internal object NativePlaybackCommandPayloads {
    fun parseRepeatOne(raw: Map<String, Any?>): NativeRepeatOneArguments {
        val queue = parseQueue(raw["queue"])
        val queueStartIndex = raw.optionalInt("queueStartIndex") ?: 0
        require(queue.isEmpty() && queueStartIndex == 0 || queueStartIndex in queue.indices) {
            "Invalid queueStartIndex."
        }
        return NativeRepeatOneArguments(
            sessionId = raw.requiredString("sessionId"),
            repeatOne = raw.requiredBoolean("repeatOne"),
            queue = queue,
            queueStartIndex = queueStartIndex,
            repeatAll = raw.requiredBoolean("repeatAll"),
            shuffle = raw.requiredBoolean("shuffle")
        )
    }

    fun parsePrepareSession(raw: Map<String, Any?>): NativePrepareSessionArguments {
        val sessionId = raw.requiredString("sessionId")
        val uri = raw.requiredUri("uri")
        val path = raw.optionalString("path")?.takeIf { it.isNotBlank() } ?: uri
        val title = raw.requiredString("title")
        val subtitle = raw.optionalString("subtitle")
        val artUri = raw.optionalString("artUri")?.also(::requireSupportedUri)
        val startPositionMs = raw.requiredLong("startPositionMs", minimum = 0L)
        val volume = raw.requiredFiniteDouble("volume", 0.0..2.0).toFloat()
        val speed = raw.requiredFiniteDouble("speed", 0.5..2.0).toFloat()
        val audioEffects = parseAudioEffects(raw.requiredMap("audioEffects"))
        val queue = parseQueue(raw["queue"])
        val queueStartIndex = raw.optionalInt("queueStartIndex") ?: 0
        require(queue.isEmpty() && queueStartIndex == 0 || queueStartIndex in queue.indices) {
            "Invalid queueStartIndex."
        }
        return NativePrepareSessionArguments(
            sessionId = sessionId,
            uri = uri,
            path = path,
            title = title,
            subtitle = subtitle,
            artUri = artUri,
            startPositionMs = startPositionMs,
            autoPlay = raw.requiredBoolean("autoPlay"),
            volume = volume,
            speed = speed,
            audioEffects = audioEffects,
            repeatOne = raw.requiredBoolean("repeatOne"),
            queue = queue.ifEmpty {
                listOf(NativeMediaItemDescriptor(path, uri, title, subtitle, artUri))
            },
            queueStartIndex = queueStartIndex,
            repeatAll = raw.requiredBoolean("repeatAll"),
            shuffle = raw.requiredBoolean("shuffle"),
            deferPlayerCreation = raw.requiredBoolean("deferPlayerCreation")
        )
    }

    fun parseQueue(rawQueue: Any?): List<NativeMediaItemDescriptor> {
        if (rawQueue == null) return emptyList()
        require(rawQueue is List<*>) { "Invalid queue." }
        require(rawQueue.size <= 10_000) { "Queue is too large." }
        return rawQueue.mapIndexed { index, rawItem ->
            require(rawItem is Map<*, *>) { "Invalid queue item at index $index." }
            val uri = rawItem.requiredString("uri").also(::requireSupportedUri)
            NativeMediaItemDescriptor(
                path = rawItem.optionalString("path")?.takeIf { it.isNotBlank() } ?: uri,
                uri = uri,
                title = rawItem.requiredString("title"),
                subtitle = rawItem.optionalString("subtitle"),
                artUri = rawItem.optionalString("artUri")?.also(::requireSupportedUri)
            )
        }
    }

    fun parseAudioEffects(rawEffects: Map<*, *>): NativeAudioEffects {
        return NativeAudioEffects(
            skipSilenceEnabled = rawEffects.requiredBoolean("skipSilenceEnabled"),
            noiseReductionEnabled = rawEffects.requiredBoolean("noiseReductionEnabled"),
            eqEnabled = rawEffects.requiredBoolean("eqEnabled"),
            eqPresetId = rawEffects.requiredNullableString("eqPresetId")?.takeIf { it.isNotBlank() },
            eqBandLevels = parseEqBandLevels(rawEffects.requiredList("eqBandLevels")),
            channelSwapEnabled = rawEffects.requiredBoolean("channelSwapEnabled"),
            volumeNormalizationEnabled = rawEffects.requiredBoolean("volumeNormalizationEnabled"),
            panning = rawEffects.requiredFiniteDouble("panning", -1.0..1.0).toFloat()
        )
    }

    private fun parseEqBandLevels(levels: List<*>): Map<Int, Float> {
        return buildMap {
            levels.forEachIndexed { index, rawItem ->
                require(rawItem is Map<*, *>) { "Invalid EQ band at index $index." }
                val frequencyHz = rawItem.requiredInt("frequencyHz")
                require(frequencyHz > 0) { "EQ frequency must be positive." }
                val gainDb = rawItem.requiredFiniteDouble("gainDb", -100.0..100.0)
                put(frequencyHz, gainDb.toFloat())
            }
        }
    }
}

private fun requireSupportedUri(raw: String) {
    val uri = runCatching { URI(raw) }.getOrNull()
    require(uri != null && uri.scheme?.lowercase() in setOf("file", "content", "http", "https")) {
        "Invalid or unsupported URI."
    }
    if (uri.scheme.equals("http", ignoreCase = true) || uri.scheme.equals("https", ignoreCase = true)) {
        require(!uri.host.isNullOrBlank()) { "Network URI is missing a host." }
    }
}

private fun Map<*, *>.requiredValue(key: String): Any {
    require(containsKey(key) && this[key] != null) { "Missing argument: $key" }
    return this[key]!!
}

private fun Map<*, *>.requiredString(key: String): String {
    val value = requiredValue(key)
    require(value is String && value.isNotBlank()) { "Invalid string argument: $key" }
    return value.trim()
}

private fun Map<*, *>.optionalString(key: String): String? {
    val value = this[key] ?: return null
    require(value is String) { "Invalid string argument: $key" }
    return value
}

private fun Map<*, *>.requiredNullableString(key: String): String? {
    require(containsKey(key)) { "Missing argument: $key" }
    return optionalString(key)
}

private fun Map<*, *>.requiredBoolean(key: String): Boolean {
    val value = requiredValue(key)
    require(value is Boolean) { "Invalid boolean argument: $key" }
    return value
}

private fun Map<*, *>.requiredMap(key: String): Map<*, *> {
    val value = requiredValue(key)
    require(value is Map<*, *>) { "Invalid map argument: $key" }
    return value
}

private fun Map<*, *>.requiredList(key: String): List<*> {
    val value = requiredValue(key)
    require(value is List<*>) { "Invalid list argument: $key" }
    return value
}

private fun Map<*, *>.requiredLong(key: String, minimum: Long): Long {
    val value = requiredValue(key)
    require(value is Number) { "Invalid numeric argument: $key" }
    val doubleValue = value.toDouble()
    require(doubleValue.isFinite() && doubleValue % 1.0 == 0.0) {
        "Numeric argument must be an integer: $key"
    }
    require(doubleValue >= Long.MIN_VALUE.toDouble() && doubleValue < Long.MAX_VALUE.toDouble()) {
        "Numeric argument is outside the long range: $key"
    }
    val converted = value.toLong()
    require(converted >= minimum) { "Numeric argument is outside the allowed range: $key" }
    return converted
}

private fun Map<*, *>.requiredInt(key: String): Int {
    val value = requiredLong(key, Int.MIN_VALUE.toLong())
    require(value <= Int.MAX_VALUE) { "Numeric argument is outside the integer range: $key" }
    return value.toInt()
}

private fun Map<*, *>.optionalInt(key: String): Int? {
    if (!containsKey(key) || this[key] == null) return null
    return requiredInt(key)
}

private fun Map<*, *>.requiredFiniteDouble(key: String, range: ClosedRange<Double>): Double {
    val value = requiredValue(key)
    require(value is Number) { "Invalid numeric argument: $key" }
    val converted = value.toDouble()
    require(converted.isFinite() && converted in range) {
        "Numeric argument is outside the allowed range: $key"
    }
    return converted
}

private fun Map<String, Any?>.requiredUri(key: String): String =
    requiredString(key).also(::requireSupportedUri)
