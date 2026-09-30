package com.doujin.audio.player.session

import java.util.Collections
import java.util.IdentityHashMap

internal fun StoredNativePlaybackSession.restoredQueue(): List<NativeMediaItemDescriptor> {
    return queue.map { queueItem ->
        NativeMediaItemDescriptor(
            path = queueItem.path,
            uri = queueItem.uri,
            title = queueItem.title,
            subtitle = queueItem.subtitle,
            artUri = queueItem.artUri
        ).withPlaybackCandidateUris(queueItem.candidateUris)
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
    private val logRestoreFailure: (String, Exception) -> Unit,
    private val isStoredSessionCurrent: (StoredNativePlaybackSession) -> Boolean = { true }
) {
    private val preparedQueues = Collections.synchronizedMap(
        IdentityHashMap<StoredNativePlaybackSession, NativePlaybackQueue>()
    )

    fun prepareQueues(storedSessions: List<StoredNativePlaybackSession>) {
        storedSessions.forEach { stored ->
            preparedQueues[stored] = NativePlaybackQueue(stored.restoredQueue()).also(NativePlaybackQueue::prepare)
        }
    }

    fun discardPreparedQueues(storedSessions: List<StoredNativePlaybackSession>) {
        storedSessions.forEach(preparedQueues::remove)
    }

    fun restore(
        storedSessions: List<StoredNativePlaybackSession>,
        autoPlay: (StoredNativePlaybackSession) -> Boolean,
        onRestored: (String) -> Unit = {}
    ): List<String> {
        val restoredSessionIds = mutableListOf<String>()
        storedSessions.forEach { stored ->
            if (!isStoredSessionCurrent(stored)) return@forEach
            val nativeSession = getOrCreateSession(stored.sessionId)
            nativeSession.definitionRevision = stored.definitionRevision
            nativeSession.isTemporary = stored.isTemporary
            try {
                nativeSession.applyAudioEffects(stored.restoredAudioEffects())
                val prepared = preparedQueues.remove(stored)
                val queue = prepared?.descriptors ?: stored.restoredQueue()
                val queueStartIndex = stored.queueStartIndex.coerceIn(0, queue.lastIndex)
                val shouldPlay = autoPlay(stored)
                nativeSession.configure(
                    descriptor = queue[queueStartIndex],
                    queue = queue,
                    queueStartIndex = queueStartIndex,
                    startPositionMs = if (stored.completed) 0L else stored.positionMs,
                    volume = stored.volume,
                    speed = stored.speed,
                    repeatOne = stored.repeatOne,
                    repeatAll = stored.repeatAll,
                    shuffleModeEnabled = stored.shuffleModeEnabled,
                    autoPlay = shouldPlay,
                    deferPlayerCreation = !shouldPlay,
                    preparedQueue = prepared
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
