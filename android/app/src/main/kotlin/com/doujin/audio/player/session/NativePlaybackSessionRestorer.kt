package com.doujin.audio.player.session

import java.util.Collections
import java.util.IdentityHashMap
import java.io.File
import java.net.URI

private fun restoredPlaybackUri(path: String, uri: String, cacheDirectory: File?): String {
    if (cacheDirectory == null) return uri
    try {
        val original = URI(path)
        if (original.scheme?.lowercase() !in setOf("http", "https") || original.host.isNullOrEmpty()) return uri
        val stored = URI(uri)
        val file = when (stored.scheme) {
            "file" -> File(stored)
            null -> File(uri)
            else -> return uri
        }.canonicalFile
        // Legacy cache files predate complete-response validation. Only retire our own files.
        if (file.parentFile == cacheDirectory.canonicalFile &&
            Regex("^[0-9a-f]{40}(\\.[A-Za-z0-9]{1,9})?$").matches(file.name)) return path
    } catch (_: Exception) {
        // A malformed stored URI cannot establish ownership of a local cache file.
    }
    return uri
}

internal fun StoredNativePlaybackSession.restoredQueue(cacheDirectory: File? = null): List<NativeMediaItemDescriptor> {
    return queue.map { queueItem ->
        NativeMediaItemDescriptor(
            path = queueItem.path,
            uri = restoredPlaybackUri(queueItem.path, queueItem.uri, cacheDirectory),
            title = queueItem.title,
            subtitle = queueItem.subtitle,
            artUri = queueItem.artUri
        ).withPlaybackCandidateUris(queueItem.candidateUris.map { candidate ->
            restoredPlaybackUri(queueItem.path, candidate, cacheDirectory)
        })
    }.ifEmpty {
        listOf(
            NativeMediaItemDescriptor(
                path = path,
                uri = restoredPlaybackUri(path, uri, cacheDirectory),
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
    private val isStoredSessionCurrent: (StoredNativePlaybackSession) -> Boolean = { true },
    private val playbackCacheDirectory: File? = null
) {
    private val preparedQueues = Collections.synchronizedMap(
        IdentityHashMap<StoredNativePlaybackSession, NativePlaybackQueue>()
    )

    fun prepareQueues(storedSessions: List<StoredNativePlaybackSession>) {
        storedSessions.forEach { stored ->
            preparedQueues[stored] = NativePlaybackQueue(stored.restoredQueue(playbackCacheDirectory)).also(NativePlaybackQueue::prepare)
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
                val queue = prepared?.descriptors ?: stored.restoredQueue(playbackCacheDirectory)
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
