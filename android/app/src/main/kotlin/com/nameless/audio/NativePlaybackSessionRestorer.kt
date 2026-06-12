package com.nameless.audio

internal fun StoredNativePlaybackSession.restoredQueue(): List<NativeMediaItemDescriptor> {
    return queue.map { queueItem ->
        NativeMediaItemDescriptor(
            path = queueItem.path,
            uri = queueItem.uri,
            title = queueItem.title,
            subtitle = queueItem.subtitle,
            artUri = queueItem.artUri
        )
    }.ifEmpty {
        listOf(
            NativeMediaItemDescriptor(
                path = path,
                uri = uri,
                title = title,
                subtitle = subtitle,
                artUri = artUri
            )
        )
    }
}

internal fun StoredNativePlaybackSession.restoredAudioEffects(): NativeAudioEffects {
    return NativeAudioEffects(
        skipSilenceEnabled = skipSilenceEnabled,
        noiseReductionEnabled = noiseReductionEnabled,
        eqEnabled = eqEnabled,
        eqPresetId = eqPresetId,
        eqBandLevels = eqBandLevels,
        channelSwapEnabled = channelSwapEnabled,
        volumeNormalizationEnabled = volumeNormalizationEnabled,
        panning = panning
    )
}

internal class NativePlaybackSessionRestorer(
    private val getOrCreateSession: (String) -> NativePlaybackSession,
    private val removeSession: (String) -> Unit,
    private val focusSession: (String) -> Unit,
    private val logRestoreFailure: (String, Exception) -> Unit
) {
    fun restore(
        storedSessions: List<StoredNativePlaybackSession>,
        autoPlay: (StoredNativePlaybackSession) -> Boolean,
        onRestored: (String) -> Unit = {}
    ): List<String> {
        val restoredSessionIds = mutableListOf<String>()
        storedSessions.forEach { stored ->
            val nativeSession = getOrCreateSession(stored.sessionId)
            try {
                nativeSession.applyAudioEffects(stored.restoredAudioEffects())
                val queue = stored.restoredQueue()
                val queueStartIndex = stored.queueStartIndex.coerceIn(0, queue.lastIndex)
                nativeSession.configure(
                    descriptor = queue[queueStartIndex],
                    queue = queue,
                    queueStartIndex = queueStartIndex,
                    startPositionMs = stored.positionMs,
                    volume = stored.volume,
                    speed = stored.speed,
                    repeatOne = stored.repeatOne,
                    repeatAll = stored.repeatAll,
                    shuffleModeEnabled = stored.shuffleModeEnabled,
                    autoPlay = autoPlay(stored)
                )
                focusSession(stored.sessionId)
                restoredSessionIds += stored.sessionId
                onRestored(stored.sessionId)
            } catch (error: Exception) {
                removeSession(stored.sessionId)
                nativeSession.release()
                logRestoreFailure(stored.sessionId, error)
            }
        }
        return restoredSessionIds
    }
}
