package com.doujin.audio.player.session

import org.json.JSONArray
import org.json.JSONObject

internal fun StoredNativePlaybackSession.encodeMetadata(): JSONObject = JSONObject()
    .put("sessionId", sessionId)
    .put("uri", uri)
    .put("path", path)
    .put("title", title)
    .put("subtitle", subtitle)
    .put("artUri", artUri)
    .put("volume", volume.toDouble())
    .put("speed", speed.toDouble())
    .put("skipSilenceEnabled", skipSilenceEnabled)
    .put("noiseReductionEnabled", noiseReductionEnabled)
    .put("eqEnabled", eqEnabled)
    .put("eqPresetId", eqPresetId)
    .put("volumeNormalizationEnabled", volumeNormalizationEnabled)
    .put("panning", panning.toDouble())
    .put("frontBack", frontBack.toDouble())
    .put(
        "eqBandLevels",
        JSONArray().apply {
            eqBandLevels.forEach { (frequencyHz, gainDb) ->
                put(
                    JSONObject()
                        .put("frequencyHz", frequencyHz)
                        .put("gainDb", gainDb.toDouble())
                )
            }
        }
    )
    .put("repeatOne", repeatOne)
    .put("repeatAll", repeatAll)
    .put("shuffleModeEnabled", shuffleModeEnabled)
    .put("queueStartIndex", queueStartIndex)
    .put("channelSwapEnabled", channelSwapEnabled)
    .put("completed", completed)
    .put("discardedQueuePrefix", discardedQueuePrefix)

internal fun StoredNativePlaybackSession.encodeQueueDefinition(): JSONObject = JSONObject()
    .put("sessionId", sessionId)
    .put("queue", encodeQueueItems())

internal fun StoredNativePlaybackSession.encodeDefinition(): JSONObject = encodeMetadata()
    .put("positionMs", positionMs)
    .put("playing", playing)
    .put("playWhenReady", playWhenReady)
    .put("queue", encodeQueueItems())

private fun StoredNativePlaybackSession.encodeQueueItems(): JSONArray = JSONArray().apply {
    queue.forEach { queueItem ->
        put(
            JSONObject()
                .put("path", queueItem.path)
                .put("uri", queueItem.uri)
                .put("title", queueItem.title)
                .put("subtitle", queueItem.subtitle)
                .put("artUri", queueItem.artUri)
                .put("usageDescriptor", queueItem.usageDescriptor?.let { JSONObject(it) })
                .put("clipStartMs", queueItem.clipStartMs)
                .put("clipEndMs", queueItem.clipEndMs)
                .put("httpHeaders", JSONObject(queueItem.httpHeaders))
                .put("playOnceBeforeQueue", queueItem.playOnceBeforeQueue)
                .put(
                    "candidateUris",
                    JSONArray(queueItem.candidateUris)
                )
        )
    }
}

internal fun JSONObject.decodeDefinition(queueSource: JSONObject = this): StoredNativePlaybackSession? {
    val sessionId = optNullableString("sessionId") ?: return null
    val uri = optNullableString("uri") ?: return null
    return StoredNativePlaybackSession(
        sessionId = sessionId,
        uri = uri,
        path = optString("path").takeIf { it.isNotBlank() } ?: uri,
        title = optString("title", "Audio"),
        subtitle = optNullableString("subtitle"),
        artUri = optNullableString("artUri"),
        positionMs = optLong("positionMs", 0L).coerceAtLeast(0L),
        volume = optDouble("volume", 1.0).toFloat(),
        speed = optDouble("speed", 1.0).toFloat(),
        skipSilenceEnabled = optBoolean("skipSilenceEnabled", false),
        noiseReductionEnabled = optBoolean("noiseReductionEnabled", false),
        eqEnabled = optBoolean("eqEnabled", false),
        eqPresetId = optNullableString("eqPresetId"),
        eqBandLevels = optEqBandLevels(),
        volumeNormalizationEnabled =
            optBoolean("volumeNormalizationEnabled", false),
        panning = optDouble("panning", 0.0).toFloat(),
        repeatOne = optBoolean("repeatOne", false),
        repeatAll = optBoolean("repeatAll", false),
        shuffleModeEnabled = optBoolean("shuffleModeEnabled", false),
        queueStartIndex = optInt("queueStartIndex", 0).coerceAtLeast(0),
        queue = queueSource.optQueueItems(),
        channelSwapEnabled = optBoolean("channelSwapEnabled", false),
        playing = optBoolean("playing", false),
        playWhenReady = optBoolean("playWhenReady", false),
        completed = optBoolean("completed", false),
        frontBack = optDouble("frontBack", 0.0).takeIf { it in -1.0..1.0 }?.toFloat() ?: 0f,
        discardedQueuePrefix = optBoolean("discardedQueuePrefix", false)
    )
}

private fun JSONObject.optNullableString(key: String): String? {
    if (!has(key) || isNull(key)) return null
    return optString(key).takeIf { it.isNotBlank() }
}

private fun JSONObject.optEqBandLevels(): Map<Int, Float> {
    val array = optJSONArray("eqBandLevels") ?: return emptyMap()
    return buildMap {
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            val frequencyHz = item.optInt("frequencyHz", 0)
            if (frequencyHz <= 0) continue
            put(frequencyHz, item.optDouble("gainDb", 0.0).toFloat())
        }
    }
}

private fun JSONObject.optQueueItems(): List<StoredNativePlaybackQueueItem> {
    val array = optJSONArray("queue") ?: return emptyList()
    return buildList {
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            val uri = item.optString("uri").takeIf { it.isNotBlank() } ?: continue
            val path = item.optString("path").takeIf { it.isNotBlank() } ?: uri
            add(
                StoredNativePlaybackQueueItem(
                    path = path,
                    uri = uri,
                    title = item.optString("title", "Audio"),
                    subtitle = item.optNullableString("subtitle"),
                    artUri = item.optNullableString("artUri"),
                    candidateUris = item.optStringList("candidateUris"),
                    usageDescriptor = item.optJSONObject("usageDescriptor")?.let { NativePlaybackUsageLedger.jsonMap(it) },
                    clipStartMs = item.optLong("clipStartMs", 0L).coerceAtLeast(0L),
                    clipEndMs = if (item.has("clipEndMs") && !item.isNull("clipEndMs")) item.getLong("clipEndMs") else null,
                    httpHeaders = item.optJSONObject("httpHeaders")?.let { headers ->
                        headers.keys().asSequence().associateWith { headers.getString(it) }
                    } ?: emptyMap(),
                    playOnceBeforeQueue = item.optBoolean("playOnceBeforeQueue", false)
                )
            )
        }
    }
}

private fun JSONObject.optStringList(key: String): List<String> {
    val values = optJSONArray(key) ?: return emptyList()
    return buildList {
        for (index in 0 until values.length()) {
            val value = values.optString(index).trim()
            if (value.isNotEmpty() && value !in this) add(value)
        }
    }
}
