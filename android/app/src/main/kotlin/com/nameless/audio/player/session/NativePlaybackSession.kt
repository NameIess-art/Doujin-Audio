@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.nameless.audio.player.session

import com.nameless.audio.player.effects.*

import android.net.Uri
import android.os.SystemClock
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import kotlin.math.roundToLong

internal data class NativeMediaItemDescriptor(
    val path: String,
    val uri: String,
    val title: String,
    val subtitle: String?,
    val artUri: String?,
    val candidateUris: List<String> = emptyList()
) {
    fun withPlaybackCandidateUris(candidates: List<String>): NativeMediaItemDescriptor {
        val ordered = LinkedHashSet<String>()
        ordered += uri
        ordered += candidates
        return copy(candidateUris = ordered.toList())
    }
}

internal data class NativeAudioEffects(
    val skipSilenceEnabled: Boolean = false,
    val noiseReductionEnabled: Boolean = false,
    val eqEnabled: Boolean = false,
    val eqPresetId: String? = null,
    val eqBandLevels: Map<Int, Float> = emptyMap(),
    val channelSwapEnabled: Boolean = false,
    val volumeNormalizationEnabled: Boolean = false,
    val panning: Float = 0f
)

internal const val NOISE_REDUCTION_LOW_RUMBLE_CUTOFF_HZ = 90
internal const val NOISE_REDUCTION_HIGH_HISS_CUTOFF_HZ = 10000
internal const val NOISE_REDUCTION_LOW_GAIN_DB = -1.5f
internal const val NOISE_REDUCTION_HIGH_GAIN_DB = -1.25f
internal const val VOLUME_NORMALIZATION_MBC_RATIO = 2.0f
internal const val VOLUME_NORMALIZATION_MBC_THRESHOLD_DB = -12f
internal const val VOLUME_NORMALIZATION_LIMITER_THRESHOLD_DB = -2f
internal const val VOLUME_NORMALIZATION_OUTPUT_GAIN_DB = 0f
internal const val STRICT_SKIP_SILENCE_MIN_DURATION_US = 250_000L
internal const val STRICT_SKIP_SILENCE_THRESHOLD_LEVEL: Short = 32

internal fun shouldSyncAudioSessionState(
    lastSyncedAudioSessionId: Int,
    audioSessionId: Int
): Boolean =
    audioSessionId != C.AUDIO_SESSION_ID_UNSET &&
        audioSessionId != lastSyncedAudioSessionId

internal fun shouldIncludeInProgressHeartbeat(
    isPlaying: Boolean,
    playWhenReady: Boolean
): Boolean = isPlaying || playWhenReady

internal data class NativePlaybackProgressUpdate(
    val sessionId: String,
    val positionMs: Long,
    val bufferedPositionMs: Long,
    val durationMs: Long?,
    val nativeElapsedRealtimeMs: Long
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "sessionId" to sessionId,
        "positionMs" to positionMs,
        "bufferedPositionMs" to bufferedPositionMs,
        "durationMs" to durationMs,
        "nativeElapsedRealtimeMs" to nativeElapsedRealtimeMs
    )
}

internal data class NativePlaybackProgressAnchor(
    val sessionId: String,
    val positionMs: Long,
    val bufferedPositionMs: Long,
    val durationMs: Long?,
    val capturedElapsedRealtimeMs: Long,
    val speed: Float,
    val isPlaying: Boolean,
    val playWhenReady: Boolean
) {
    fun updateAt(nowElapsedRealtimeMs: Long): NativePlaybackProgressUpdate? {
        if (!shouldIncludeInProgressHeartbeat(isPlaying, playWhenReady)) return null
        val elapsedMs = (nowElapsedRealtimeMs - capturedElapsedRealtimeMs).coerceAtLeast(0L)
        val advancedPositionMs = if (isPlaying) {
            positionMs + (elapsedMs * speed.coerceAtLeast(0f)).roundToLong()
        } else {
            positionMs
        }
        val clampedPositionMs = durationMs?.let { duration ->
            advancedPositionMs.coerceIn(0L, duration.coerceAtLeast(0L))
        } ?: advancedPositionMs.coerceAtLeast(0L)
        val clampedBufferedPositionMs = durationMs?.let { duration ->
            bufferedPositionMs.coerceIn(0L, duration.coerceAtLeast(0L))
        } ?: bufferedPositionMs.coerceAtLeast(0L)
        return NativePlaybackProgressUpdate(
            sessionId = sessionId,
            positionMs = clampedPositionMs,
            bufferedPositionMs = clampedBufferedPositionMs,
            durationMs = durationMs,
            nativeElapsedRealtimeMs = nowElapsedRealtimeMs
        )
    }
}

internal fun buildNativePlaybackProgressEvent(
    anchors: List<NativePlaybackProgressAnchor>,
    nowElapsedRealtimeMs: Long
): Map<String, Any?>? {
    val updates = anchors.mapNotNull { it.updateAt(nowElapsedRealtimeMs)?.toMap() }
    if (updates.isEmpty()) return null
    return mapOf(
        "eventType" to "progress",
        "nativeElapsedRealtimeMs" to nowElapsedRealtimeMs,
        "updates" to updates
    )
}

internal class NativePlaybackSession(
    val sessionId: String,
    private val createPlayer: (String, Array<AudioProcessor>) -> ExoPlayer,
    private val logWarn: (String, NativePlaybackSession, RuntimeException) -> Unit,
    private val resolveUriToPath: ((String) -> String?)? = null,
    private val elapsedRealtimeMs: () -> Long = SystemClock::elapsedRealtime
) : NativePlaybackSessionSnapshotSource {
    private val audioEffects = NativeSessionAudioEffectsRuntime { message, error ->
        logWarn(message, this, error)
    }
    private var lastSyncedAudioSessionId: Int = C.AUDIO_SESSION_ID_UNSET
    private var _player: ExoPlayer? = null
    var lastUsedMs: Long = System.currentTimeMillis()
    var path: String? = null
    var uri: String? = null
    var title: String = "Audio"
    var subtitle: String? = null
    var artUri: String? = null
    var volume: Float = 1f
    var fadeMultiplier: Float = 1f
    var focusDuckMultiplier: Float = 1f
        private set
    var speed: Float = 1f
    var repeatOne: Boolean = false
    var repeatAll: Boolean = false
    var shuffleModeEnabled: Boolean = false
    private var queue: List<NativeMediaItemDescriptor> = emptyList()
    var channelSwapEnabled: Boolean
        get() = audioEffects.channelSwapEnabled
        set(value) {
            audioEffects.channelSwapEnabled = value
        }
    var skipSilenceEnabled: Boolean
        get() = audioEffects.skipSilenceEnabled
        set(value) {
            audioEffects.skipSilenceEnabled = value
        }
    var noiseReductionEnabled: Boolean
        get() = audioEffects.noiseReductionEnabled
        set(value) {
            audioEffects.noiseReductionEnabled = value
        }
    var eqEnabled: Boolean
        get() = audioEffects.eqEnabled
        set(value) {
            audioEffects.eqEnabled = value
        }
    var eqPresetId: String?
        get() = audioEffects.eqPresetId
        set(value) {
            audioEffects.eqPresetId = value
        }
    var eqBandLevels: Map<Int, Float>
        get() = audioEffects.eqBandLevels
        set(value) {
            audioEffects.eqBandLevels = value
        }
    var volumeNormalizationEnabled: Boolean
        get() = audioEffects.volumeNormalizationEnabled
        set(value) {
            audioEffects.volumeNormalizationEnabled = value
        }
    var panning: Float
        get() = audioEffects.panning
        set(value) {
            audioEffects.panning = value
        }
    var lastPositionMs: Long = 0L
    var lastDurationMs: Long? = null
    var lastBufferedPositionMs: Long = 0L
    var lastIsPlaying: Boolean = false
    var lastPlayWhenReady: Boolean = false
    var lastPlaybackState: String = "idle"
    var transportCommandId: Long = 0L
    @Volatile
    private var progressAnchor = NativePlaybackProgressAnchor(
        sessionId = sessionId,
        positionMs = 0L,
        bufferedPositionMs = 0L,
        durationMs = null,
        capturedElapsedRealtimeMs = elapsedRealtimeMs(),
        speed = 1f,
        isPlaying = false,
        playWhenReady = false
    )

    fun hasPlayer(): Boolean = _player != null

    fun playerOrNull(): ExoPlayer? = _player

    fun ensurePlayer(): ExoPlayer {
        _player?.let { return it }
        val p = createPlayer(
            sessionId,
            audioProcessors()
        )
        _player = p

        val descriptors = queue.takeIf { it.isNotEmpty() }
            ?: uri?.let {
                listOf(
                    NativeMediaItemDescriptor(
                        path = path ?: it,
                        uri = it,
                        title = title,
                        subtitle = subtitle,
                        artUri = artUri
                    )
                )
            }
        if (!descriptors.isNullOrEmpty()) {
            p.setMediaItems(
                descriptors.map(::buildMediaItem),
                currentQueueIndexFor(descriptors),
                lastPositionMs
            )
            applyVolumeToPlayer(p)
            applySpeedToPlayer(p)
            applyAudioEffectsToPlayer(p)
            p.repeatMode = repeatModeFor(descriptors.size)
            p.shuffleModeEnabled = shuffleModeEnabled && descriptors.size > 1
            p.playWhenReady = lastPlayWhenReady
            p.prepare()
        }

        return p
    }

    fun isPlaying(): Boolean = _player?.isPlaying ?: lastIsPlaying

    fun releasePlayer() {
        _player?.let { p ->
            lastPositionMs = p.currentPosition.coerceAtLeast(0L)
            lastDurationMs = durationOrNull(p.duration)
            lastBufferedPositionMs = p.bufferedPosition.coerceAtLeast(0L)
            lastIsPlaying = p.isPlaying
            lastPlayWhenReady = p.playWhenReady
            lastPlaybackState = p.playbackStateName()
            syncCurrentMediaItemFromPlayer()
            p.release()
        }
        audioEffects.release()
        lastSyncedAudioSessionId = C.AUDIO_SESSION_ID_UNSET
        _player = null
    }

    fun configure(
        descriptor: NativeMediaItemDescriptor,
        queue: List<NativeMediaItemDescriptor>,
        queueStartIndex: Int,
        startPositionMs: Long,
        volume: Float,
        speed: Float,
        repeatOne: Boolean,
        repeatAll: Boolean,
        shuffleModeEnabled: Boolean,
        autoPlay: Boolean,
        deferPlayerCreation: Boolean = false
    ) {
        this.queue = queue.ifEmpty { listOf(descriptor) }
        this.path = descriptor.path
        this.uri = descriptor.uri
        this.title = descriptor.title
        this.subtitle = descriptor.subtitle
        this.artUri = descriptor.artUri
        this.lastPositionMs = startPositionMs
        this.volume = PlaybackVolumeMapper.normalize(volume)
        this.speed = normalizeSpeed(speed)
        this.repeatOne = repeatOne
        this.repeatAll = repeatAll
        this.shuffleModeEnabled = shuffleModeEnabled
        this.lastPlayWhenReady = autoPlay
        applyChannelMap()

        if (!shouldCreatePlayerForConfiguration(deferPlayerCreation, hasPlayer())) {
            lastIsPlaying = false
            lastPlaybackState = "idle"
            return
        }

        val p = playerOrNull() ?: createPlayer(
            sessionId,
            audioProcessors()
        ).also { _player = it }
        p.setMediaItems(
            this.queue.map(::buildMediaItem),
            queueStartIndex.coerceIn(0, this.queue.lastIndex),
            startPositionMs.coerceAtLeast(0L)
        )
        applyVolumeToPlayer(p)
        applySpeedToPlayer(p)
        applyAudioEffectsToPlayer(p)
        p.repeatMode = repeatModeFor(this.queue.size)
        p.shuffleModeEnabled = shuffleModeEnabled && this.queue.size > 1
        p.playWhenReady = autoPlay
        p.prepare()
        syncCurrentMediaItemFromPlayer()
    }

    fun applyChannelMap() {
        audioEffects.applyChannelMap()
    }

    fun applyVolume(volume: Float) {
        this.volume = PlaybackVolumeMapper.normalize(volume)
        playerOrNull()?.let(::applyVolumeToPlayer)
    }

    fun applyFadeMultiplier(multiplier: Float) {
        this.fadeMultiplier = multiplier.coerceIn(0f, 1f)
        playerOrNull()?.let(::applyVolumeToPlayer)
    }

    fun applyFocusDuckMultiplier(multiplier: Float) {
        focusDuckMultiplier = multiplier.coerceIn(0f, 1f)
        playerOrNull()?.let(::applyVolumeToPlayer)
    }

    fun applySpeed(speed: Float) {
        this.speed = normalizeSpeed(speed)
        playerOrNull()?.let(::applySpeedToPlayer)
    }

    fun applyAudioEffects(effects: NativeAudioEffects) {
        val change = audioEffects.apply(effects)
        playerOrNull()?.let { player ->
            applyAudioEffectsToPlayer(player)
            if (change.panningActiveChanged) {
                reprepareCurrentMediaItem()
            }
        }
    }

    private fun applyVolumeToPlayer(player: ExoPlayer) {
        val normalizedVolume = PlaybackVolumeMapper.normalize(volume)
        this.volume = normalizedVolume
        player.volume = effectiveNativePlaybackVolume(
            playerVolume = PlaybackVolumeMapper.playerVolume(normalizedVolume),
            fadeMultiplier = fadeMultiplier,
            focusDuckMultiplier = focusDuckMultiplier
        )
        audioEffects.syncLoudnessEnhancer(player.audioSessionId, volume)
    }

    private fun applySpeedToPlayer(player: ExoPlayer) {
        player.playbackParameters = PlaybackParameters(normalizeSpeed(speed))
    }

    private fun applyAudioEffectsToPlayer(player: ExoPlayer) {
        audioEffects.applyToPlayer(player)
    }

    private fun audioProcessors(): Array<AudioProcessor> {
        return audioEffects.audioProcessors()
    }

    fun onAudioSessionIdChanged(audioSessionId: Int) {
        if (!shouldSyncAudioSessionState(lastSyncedAudioSessionId, audioSessionId)) return
        lastSyncedAudioSessionId = audioSessionId
        audioEffects.syncAudioSession(audioSessionId, volume)
    }

    fun updateQueue(
        queue: List<NativeMediaItemDescriptor>,
        queueStartIndex: Int,
        repeatOne: Boolean,
        repeatAll: Boolean,
        shuffleModeEnabled: Boolean
    ) {
        if (queue.isEmpty()) return
        val p = _player
        val currentPositionMs = p?.currentPosition?.coerceAtLeast(0L) ?: lastPositionMs
        val shouldResume = p?.let { it.playWhenReady || it.isPlaying } ?: lastPlayWhenReady
        configure(
            descriptor = queue[queueStartIndex.coerceIn(0, queue.lastIndex)],
            queue = queue,
            queueStartIndex = queueStartIndex,
            startPositionMs = currentPositionMs,
            volume = volume,
            speed = speed,
            repeatOne = repeatOne,
            repeatAll = repeatAll,
            shuffleModeEnabled = shuffleModeEnabled,
            autoPlay = shouldResume
        )
    }

    fun reprepareCurrentMediaItem() {
        val currentUri = uri ?: return
        val p = _player
        val currentPositionMs = p?.currentPosition?.coerceAtLeast(0L) ?: lastPositionMs
        val shouldResume = p?.let { it.playWhenReady || it.isPlaying } ?: lastPlayWhenReady
        val isRepeatOne = (p?.repeatMode == Player.REPEAT_MODE_ONE) || (p == null && repeatOne)
        val descriptors = queue.takeIf { it.isNotEmpty() } ?: listOf(
            NativeMediaItemDescriptor(
                path = path ?: currentUri,
                uri = currentUri,
                title = title,
                subtitle = subtitle,
                artUri = artUri
            )
        )
        val currentIndex = p?.currentMediaItemIndex ?: currentQueueIndexFor(descriptors)

        configure(
            descriptor = descriptors[currentIndex.coerceIn(0, descriptors.lastIndex)],
            queue = descriptors,
            queueStartIndex = currentIndex,
            startPositionMs = currentPositionMs,
            volume = volume,
            speed = speed,
            repeatOne = isRepeatOne,
            repeatAll = repeatAll,
            shuffleModeEnabled = shuffleModeEnabled,
            autoPlay = shouldResume,
        )
    }

    fun hasAlternatePlaybackUri(): Boolean {
        val descriptor = currentQueueDescriptor() ?: return false
        return descriptor.candidateUris.distinct().size > 1
    }

    fun advanceToNextPlaybackUri(): Boolean {
        val descriptors = queue.takeIf { it.isNotEmpty() } ?: return false
        val currentIndex = (playerOrNull()?.currentMediaItemIndex
            ?: currentQueueIndexFor(descriptors)).coerceIn(0, descriptors.lastIndex)
        val descriptor = descriptors[currentIndex]
        val ordered = descriptor.candidateUris.distinct()
        if (ordered.size < 2) return false
        val currentUri = uri ?: descriptor.uri
        val candidateIndex = ordered.indexOf(currentUri).takeIf { it >= 0 } ?: 0
        val nextUri = ordered[(candidateIndex + 1) % ordered.size]
        if (nextUri == currentUri) return false

        val updated = descriptor.copy(uri = nextUri)
        queue = descriptors.toMutableList().also { it[currentIndex] = updated }
        uri = nextUri
        path = descriptor.path
        title = descriptor.title
        subtitle = descriptor.subtitle
        artUri = descriptor.artUri
        return true
    }

    private fun currentQueueDescriptor(): NativeMediaItemDescriptor? {
        val descriptors = queue.takeIf { it.isNotEmpty() } ?: return null
        val currentIndex = (playerOrNull()?.currentMediaItemIndex
            ?: currentQueueIndexFor(descriptors)).coerceIn(0, descriptors.lastIndex)
        return descriptors[currentIndex]
    }

    override fun snapshot(): Map<String, Any?> {
        val p = _player
        if (p != null) {
            lastPositionMs = p.currentPosition.coerceAtLeast(0L)
            lastDurationMs = durationOrNull(p.duration)
            lastBufferedPositionMs = p.bufferedPosition.coerceAtLeast(0L)
            lastIsPlaying = p.isPlaying
            lastPlayWhenReady = p.playWhenReady
            lastPlaybackState = p.playbackStateName()
            syncCurrentMediaItemFromPlayer()
        }
        progressAnchor = NativePlaybackProgressAnchor(
            sessionId = sessionId,
            positionMs = lastPositionMs,
            bufferedPositionMs = lastBufferedPositionMs,
            durationMs = lastDurationMs,
            capturedElapsedRealtimeMs = elapsedRealtimeMs(),
            speed = speed,
            isPlaying = lastIsPlaying,
            playWhenReady = lastPlayWhenReady
        )

        return mapOf(
            "sessionId" to sessionId,
            "path" to path,
            "uri" to uri,
            "title" to title,
            "subtitle" to subtitle,
            "artUri" to artUri,
            "playing" to lastIsPlaying,
            "playWhenReady" to lastPlayWhenReady,
            "processingState" to lastPlaybackState,
            "positionMs" to lastPositionMs,
            "durationMs" to lastDurationMs,
            "bufferedPositionMs" to lastBufferedPositionMs,
            "volume" to volume.toDouble(),
            "speed" to speed.toDouble(),
            "boostGain" to PlaybackVolumeMapper.boostGain(volume).toDouble(),
            "channelSwap" to channelSwapEnabled,
            "audioEffects" to audioEffectsSnapshot(),
            "eqCapabilities" to eqCapabilitiesSnapshot(),
            "queueIndex" to (p?.currentMediaItemIndex ?: currentQueueIndexFor(queue)).coerceAtLeast(0),
            "transportCommandId" to transportCommandId,
            "error" to p?.playerError?.message
        )
    }

    fun progressAnchorSnapshot(): NativePlaybackProgressAnchor = progressAnchor

    override fun currentAudioSessionId(): Int {
        return playerOrNull()?.audioSessionId ?: C.AUDIO_SESSION_ID_UNSET
    }

    override fun syncAudioSessionState(audioSessionId: Int) {
        onAudioSessionIdChanged(audioSessionId)
    }

    fun storedSnapshot(): StoredNativePlaybackSession {
        val p = _player
        val currentPos = p?.currentPosition?.coerceAtLeast(0L) ?: lastPositionMs
        val isP = p?.isPlaying ?: lastIsPlaying
        val isPWR = p?.playWhenReady ?: lastPlayWhenReady
        if (p != null) {
            syncCurrentMediaItemFromPlayer()
        }

        return StoredNativePlaybackSession(
            sessionId = sessionId,
            uri = uri.orEmpty(),
            path = path ?: uri.orEmpty(),
            title = title,
            subtitle = subtitle,
            artUri = artUri,
            positionMs = currentPos,
            volume = volume,
            speed = speed,
            skipSilenceEnabled = skipSilenceEnabled,
            noiseReductionEnabled = noiseReductionEnabled,
            eqEnabled = eqEnabled,
            eqPresetId = eqPresetId,
            eqBandLevels = eqBandLevels,
            volumeNormalizationEnabled = volumeNormalizationEnabled,
            panning = panning,
            repeatOne = repeatOne,
            repeatAll = repeatAll,
            shuffleModeEnabled = shuffleModeEnabled,
            queueStartIndex = (p?.currentMediaItemIndex ?: currentQueueIndexFor(queue))
                .coerceAtLeast(0),
            queue = queue.map { descriptor ->
                StoredNativePlaybackQueueItem(
                    path = descriptor.path,
                    uri = descriptor.uri,
                    title = descriptor.title,
                    subtitle = descriptor.subtitle,
                    artUri = descriptor.artUri
                )
            },
            channelSwapEnabled = channelSwapEnabled,
            playing = isP,
            playWhenReady = isPWR
        )
    }

    fun foregroundNotificationSignature(): String {
        val p = _player
        val playing = p?.isPlaying ?: lastIsPlaying
        val playWhenReady = p?.playWhenReady ?: lastPlayWhenReady
        return listOf(
            sessionId,
            title,
            subtitle.orEmpty(),
            playing,
            playWhenReady,
            repeatOne,
            hasPreviousMediaItem(),
            hasNextMediaItem()
        ).joinToString("|")
    }

    fun hasPreviousMediaItem(): Boolean {
        val player = _player
        if (player != null) return player.hasPreviousMediaItem()
        return currentQueueIndexFor(queue) > 0
    }

    fun hasNextMediaItem(): Boolean {
        val player = _player
        if (player != null) return player.hasNextMediaItem()
        val currentIndex = currentQueueIndexFor(queue)
        return queue.isNotEmpty() && currentIndex < queue.lastIndex
    }

    fun syncCurrentMediaItemFromPlayer() {
        val mediaItem = _player?.currentMediaItem ?: return
        val metadata = mediaItem.mediaMetadata
        path = mediaItem.mediaId.takeIf { it.isNotBlank() }
        uri = mediaItem.localConfiguration?.uri?.toString() ?: uri
        title = metadata.title?.toString()?.takeIf { it.isNotBlank() } ?: title
        subtitle = metadata.artist?.toString()?.takeIf { it.isNotBlank() }
        artUri = metadata.artworkUri?.toString()
    }

    private fun buildMediaItem(descriptor: NativeMediaItemDescriptor): MediaItem {
        val metadataBuilder = MediaMetadata.Builder()
            .setTitle(descriptor.title)
            .setArtist(descriptor.subtitle)
        if (!descriptor.artUri.isNullOrBlank()) {
            metadataBuilder.setArtworkUri(Uri.parse(descriptor.artUri))
        }
        var finalUri = descriptor.uri
        if (finalUri.startsWith("content://")) {
            val path = resolveUriToPath?.invoke(finalUri)
            if (path != null) {
                val file = java.io.File(path)
                if (file.exists() && file.canRead()) {
                    finalUri = Uri.fromFile(file).toString()
                }
            }
        }
        return MediaItem.Builder()
            .setMediaId(descriptor.path)
            .setUri(Uri.parse(finalUri))
            .setMediaMetadata(metadataBuilder.build())
            .build()
    }

    private fun repeatModeFor(queueSize: Int): Int {
        return when {
            repeatOne -> Player.REPEAT_MODE_ONE
            repeatAll && queueSize > 1 -> Player.REPEAT_MODE_ALL
            else -> Player.REPEAT_MODE_OFF
        }
    }

    fun currentRepeatMode(): Int = repeatModeFor(queue.size)

    fun currentShuffleModeEnabled(): Boolean = shuffleModeEnabled && queue.size > 1

    private fun currentQueueIndexFor(descriptors: List<NativeMediaItemDescriptor>): Int {
        val currentPath = path
        val index = descriptors.indexOfFirst { it.path == currentPath }
        return if (index >= 0) index else 0
    }

    fun release() {
        _player?.release()
        _player = null
        audioEffects.release()
        lastSyncedAudioSessionId = C.AUDIO_SESSION_ID_UNSET
    }

    private fun audioEffectsSnapshot(): Map<String, Any?> = audioEffects.snapshot()

    private fun eqCapabilitiesSnapshot(): Map<String, Any?> =
        audioEffects.eqCapabilitiesSnapshot()
}

internal fun effectiveNativePlaybackVolume(
    playerVolume: Float,
    fadeMultiplier: Float,
    focusDuckMultiplier: Float
): Float = playerVolume.coerceAtLeast(0f) *
    fadeMultiplier.coerceIn(0f, 1f) *
    focusDuckMultiplier.coerceIn(0f, 1f)

internal interface NativePlaybackSessionSnapshotSource {
    fun currentAudioSessionId(): Int
    fun syncAudioSessionState(audioSessionId: Int)
    fun snapshot(): Map<String, Any?>
}

internal fun publishNativePlaybackSessionState(
    session: NativePlaybackSessionSnapshotSource,
    listeners: Collection<(Map<String, Any?>) -> Unit>
): Map<String, Any?> {
    val audioSessionId = session.currentAudioSessionId()
    if (audioSessionId != C.AUDIO_SESSION_ID_UNSET) {
        session.syncAudioSessionState(audioSessionId)
    }
    val snapshot = session.snapshot()
    for (listener in listeners) {
        try {
            listener(snapshot)
        } catch (_: Exception) {
            // Prevent one broken listener from crashing the service.
        }
    }
    return snapshot
}

private fun normalizeSpeed(speed: Float): Float = speed.coerceIn(0.5f, 2.0f)

internal fun shouldCreatePlayerForConfiguration(
    deferPlayerCreation: Boolean,
    hasPlayer: Boolean
): Boolean = !deferPlayerCreation || hasPlayer

internal fun noiseReductionGainFor(frequencyHz: Int): Float {
    return when {
        frequencyHz <= NOISE_REDUCTION_LOW_RUMBLE_CUTOFF_HZ -> NOISE_REDUCTION_LOW_GAIN_DB
        frequencyHz >= NOISE_REDUCTION_HIGH_HISS_CUTOFF_HZ -> NOISE_REDUCTION_HIGH_GAIN_DB
        else -> 0f
    }
}

internal fun ExoPlayer.playbackStateName(): String {
    return playbackStateName(playbackState)
}

internal fun playbackStateName(playbackState: Int): String {
    return when (playbackState) {
        Player.STATE_IDLE -> "idle"
        Player.STATE_BUFFERING -> "buffering"
        Player.STATE_READY -> "ready"
        Player.STATE_ENDED -> "completed"
        else -> "unknown"
    }
}

internal fun durationOrNull(duration: Long): Long? {
    return if (duration == C.TIME_UNSET || duration < 0L) null else duration
}
