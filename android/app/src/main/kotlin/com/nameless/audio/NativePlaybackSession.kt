package com.nameless.audio

import android.media.audiofx.LoudnessEnhancer
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.ChannelMappingAudioProcessor

internal data class NativeMediaItemDescriptor(
    val path: String,
    val uri: String,
    val title: String,
    val subtitle: String?,
    val artUri: String?
)

internal class NativePlaybackSession(
    val sessionId: String,
    private val createPlayer: (String, ChannelMappingAudioProcessor) -> ExoPlayer,
    private val evictPlayersIfNeeded: () -> Unit,
    private val logWarn: (String, NativePlaybackSession, RuntimeException) -> Unit
) {
    private val channelMappingAudioProcessor = ChannelMappingAudioProcessor()
    private var loudnessEnhancer: LoudnessEnhancer? = null
    private var loudnessEnhancerSessionId: Int = C.AUDIO_SESSION_ID_UNSET
    private var _player: ExoPlayer? = null
    var lastUsedMs: Long = System.currentTimeMillis()
    var path: String? = null
    var uri: String? = null
    var title: String = "Audio"
    var subtitle: String? = null
    var artUri: String? = null
    var volume: Float = 1f
    var repeatOne: Boolean = false
    var repeatAll: Boolean = false
    var shuffleModeEnabled: Boolean = false
    private var queue: List<NativeMediaItemDescriptor> = emptyList()
    var channelSwapEnabled: Boolean = false
    var lastPositionMs: Long = 0L
    var lastDurationMs: Long? = null
    var lastBufferedPositionMs: Long = 0L
    var lastIsPlaying: Boolean = false
    var lastPlayWhenReady: Boolean = false
    var lastPlaybackState: String = "idle"

    fun hasPlayer(): Boolean = _player != null

    fun playerOrNull(): ExoPlayer? = _player

    fun ensurePlayer(): ExoPlayer {
        _player?.let { return it }
        val p = createPlayer(
            sessionId,
            channelMappingAudioProcessor
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
        releaseLoudnessEnhancer()
        _player = null
    }

    fun configure(
        descriptor: NativeMediaItemDescriptor,
        queue: List<NativeMediaItemDescriptor>,
        queueStartIndex: Int,
        startPositionMs: Long,
        volume: Float,
        repeatOne: Boolean,
        repeatAll: Boolean,
        shuffleModeEnabled: Boolean,
        autoPlay: Boolean
    ) {
        this.queue = queue.ifEmpty { listOf(descriptor) }
        this.path = descriptor.path
        this.uri = descriptor.uri
        this.title = descriptor.title
        this.subtitle = descriptor.subtitle
        this.artUri = descriptor.artUri
        this.lastPositionMs = startPositionMs
        this.volume = PlaybackVolumeMapper.normalize(volume)
        this.repeatOne = repeatOne
        this.repeatAll = repeatAll
        this.shuffleModeEnabled = shuffleModeEnabled
        this.lastPlayWhenReady = autoPlay
        applyChannelMap()

        val p = playerOrNull() ?: createPlayer(
            sessionId,
            channelMappingAudioProcessor
        ).also { _player = it }
        p.setMediaItems(
            this.queue.map(::buildMediaItem),
            queueStartIndex.coerceIn(0, this.queue.lastIndex),
            startPositionMs.coerceAtLeast(0L)
        )
        applyVolumeToPlayer(p)
        p.repeatMode = repeatModeFor(this.queue.size)
        p.shuffleModeEnabled = shuffleModeEnabled && this.queue.size > 1
        p.playWhenReady = autoPlay
        p.prepare()
        syncCurrentMediaItemFromPlayer()

        evictPlayersIfNeeded()
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

    fun applyVolume(volume: Float) {
        this.volume = PlaybackVolumeMapper.normalize(volume)
        playerOrNull()?.let(::applyVolumeToPlayer)
    }

    private fun applyVolumeToPlayer(player: ExoPlayer) {
        val normalizedVolume = PlaybackVolumeMapper.normalize(volume)
        this.volume = normalizedVolume
        player.volume = PlaybackVolumeMapper.playerVolume(normalizedVolume)
        syncLoudnessEnhancer(player.audioSessionId)
    }

    fun onAudioSessionIdChanged(audioSessionId: Int) {
        syncLoudnessEnhancer(audioSessionId)
    }

    private fun syncLoudnessEnhancer(audioSessionId: Int) {
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
                logWarn(
                    "loudness_enhancer_create_failed audioSessionId=$audioSessionId",
                    this,
                    e
                )
                null
            }
        } ?: return

        try {
            enhancer.setTargetGain(targetGain)
            enhancer.setEnabled(true)
        } catch (e: RuntimeException) {
            logWarn("loudness_enhancer_apply_failed gain=$targetGain", this, e)
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
            repeatOne = isRepeatOne,
            repeatAll = repeatAll,
            shuffleModeEnabled = shuffleModeEnabled,
            autoPlay = shouldResume,
        )
    }

    fun snapshot(): Map<String, Any?> {
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
            "boostGain" to PlaybackVolumeMapper.boostGain(volume).toDouble(),
            "channelSwap" to channelSwapEnabled,
            "error" to p?.playerError?.message
        )
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
            repeatOne
        ).joinToString("|")
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
        return MediaItem.Builder()
            .setMediaId(descriptor.path)
            .setUri(Uri.parse(descriptor.uri))
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
