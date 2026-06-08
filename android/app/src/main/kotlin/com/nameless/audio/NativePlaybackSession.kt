package com.nameless.audio

import android.media.audiofx.Equalizer
import android.media.audiofx.LoudnessEnhancer
import android.net.Uri
import android.media.audiofx.DynamicsProcessing
import android.os.Build
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.ChannelMappingAudioProcessor
import kotlin.math.abs
import kotlin.math.roundToInt

internal data class NativeMediaItemDescriptor(
    val path: String,
    val uri: String,
    val title: String,
    val subtitle: String?,
    val artUri: String?
)

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

internal class NativePlaybackSession(
    val sessionId: String,
    private val createPlayer: (String, Array<AudioProcessor>) -> ExoPlayer,
    private val evictPlayersIfNeeded: () -> Unit,
    private val logWarn: (String, NativePlaybackSession, RuntimeException) -> Unit
) {
    private val channelMappingAudioProcessor = ChannelMappingAudioProcessor()
    private val volumeBalanceAudioProcessor = VolumeBalanceAudioProcessor()
    private var loudnessEnhancer: LoudnessEnhancer? = null
    private var loudnessEnhancerSessionId: Int = C.AUDIO_SESSION_ID_UNSET
    private var equalizer: Equalizer? = null
    private var equalizerSessionId: Int = C.AUDIO_SESSION_ID_UNSET
    private var equalizerCreateFailed = false
    private var dynamicsProcessing: android.media.audiofx.DynamicsProcessing? = null
    private var dynamicsProcessingSessionId: Int = C.AUDIO_SESSION_ID_UNSET
    private var _player: ExoPlayer? = null
    var lastUsedMs: Long = System.currentTimeMillis()
    var path: String? = null
    var uri: String? = null
    var title: String = "Audio"
    var subtitle: String? = null
    var artUri: String? = null
    var volume: Float = 1f
    var fadeMultiplier: Float = 1f
    var speed: Float = 1f
    var repeatOne: Boolean = false
    var repeatAll: Boolean = false
    var shuffleModeEnabled: Boolean = false
    private var queue: List<NativeMediaItemDescriptor> = emptyList()
    var channelSwapEnabled: Boolean = false
    var skipSilenceEnabled: Boolean = false
    var noiseReductionEnabled: Boolean = false
    var eqEnabled: Boolean = false
    var eqPresetId: String? = null
    var eqBandLevels: Map<Int, Float> = emptyMap()
    var volumeNormalizationEnabled: Boolean = false
    var panning: Float = 0f
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
        releaseLoudnessEnhancer()
        releaseEqualizer()
        releaseDynamicsProcessing()
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
        this.speed = normalizeSpeed(speed)
        this.repeatOne = repeatOne
        this.repeatAll = repeatAll
        this.shuffleModeEnabled = shuffleModeEnabled
        this.lastPlayWhenReady = autoPlay
        applyChannelMap()

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

    fun applyFadeMultiplier(multiplier: Float) {
        this.fadeMultiplier = multiplier.coerceIn(0f, 1f)
        playerOrNull()?.let(::applyVolumeToPlayer)
    }

    fun applySpeed(speed: Float) {
        this.speed = normalizeSpeed(speed)
        playerOrNull()?.let(::applySpeedToPlayer)
    }

    fun applyAudioEffects(effects: NativeAudioEffects) {
        val previousPanningActive = isPanningActive()
        channelSwapEnabled = effects.channelSwapEnabled
        skipSilenceEnabled = effects.skipSilenceEnabled
        noiseReductionEnabled = effects.noiseReductionEnabled
        eqEnabled = effects.eqEnabled
        eqPresetId = effects.eqPresetId
        eqBandLevels = effects.eqBandLevels
        volumeNormalizationEnabled = effects.volumeNormalizationEnabled
        panning = effects.panning
        volumeBalanceAudioProcessor.panning = panning
        applyChannelMap()
        playerOrNull()?.let { player ->
            applyAudioEffectsToPlayer(player)
            if (previousPanningActive != isPanningActive()) {
                reprepareCurrentMediaItem()
            }
        }
    }

    private fun applyVolumeToPlayer(player: ExoPlayer) {
        val normalizedVolume = PlaybackVolumeMapper.normalize(volume)
        this.volume = normalizedVolume
        player.volume = PlaybackVolumeMapper.playerVolume(normalizedVolume) * fadeMultiplier
        syncLoudnessEnhancer(player.audioSessionId)
    }

    private fun applySpeedToPlayer(player: ExoPlayer) {
        player.playbackParameters = PlaybackParameters(normalizeSpeed(speed))
    }

    private fun applyAudioEffectsToPlayer(player: ExoPlayer) {
        player.setSkipSilenceEnabled(skipSilenceEnabled)
        syncEqualizer(player.audioSessionId)
        syncDynamicsProcessing(player.audioSessionId)
    }

    private fun audioProcessors(): Array<AudioProcessor> {
        volumeBalanceAudioProcessor.panning = panning
        return arrayOf(channelMappingAudioProcessor, volumeBalanceAudioProcessor)
    }

    private fun isPanningActive(): Boolean = kotlin.math.abs(panning) >= 0.001f

    fun onAudioSessionIdChanged(audioSessionId: Int) {
        syncLoudnessEnhancer(audioSessionId)
        syncEqualizer(audioSessionId)
        syncDynamicsProcessing(audioSessionId)
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
                logWarn("equalizer_create_failed audioSessionId=$audioSessionId", this, e)
                null
            }
        } ?: return

        try {
            applyEqualizerBandLevels(nextEqualizer)
            nextEqualizer.enabled = true
        } catch (e: RuntimeException) {
            logWarn("equalizer_apply_failed", this, e)
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
            "speed" to speed.toDouble(),
            "boostGain" to PlaybackVolumeMapper.boostGain(volume).toDouble(),
            "channelSwap" to channelSwapEnabled,
            "audioEffects" to audioEffectsSnapshot(),
            "eqCapabilities" to eqCapabilitiesSnapshot(),
            "queueIndex" to (p?.currentMediaItemIndex ?: currentQueueIndexFor(queue)).coerceAtLeast(0),
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
        releaseLoudnessEnhancer()
        releaseEqualizer()
        releaseDynamicsProcessing()
    }

    private fun audioEffectsSnapshot(): Map<String, Any?> {
        return mapOf(
            "skipSilenceEnabled" to skipSilenceEnabled,
            "noiseReductionEnabled" to noiseReductionEnabled,
            "eqEnabled" to eqEnabled,
            "eqPresetId" to eqPresetId,
            "eqBandLevels" to eqBandLevels.map { (frequencyHz, gainDb) ->
                mapOf("frequencyHz" to frequencyHz, "gainDb" to gainDb.toDouble())
            },
            "volumeNormalizationEnabled" to volumeNormalizationEnabled,
            "panning" to panning.toDouble()
        )
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
                logWarn("dynamics_processing_create_failed audioSessionId=$audioSessionId", this, e)
                null
            }
        } ?: return

        try {
            dp.enabled = true
        } catch (e: RuntimeException) {
            logWarn("dynamics_processing_apply_failed", this, e)
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

    private fun eqCapabilitiesSnapshot(): Map<String, Any?> {
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

private fun normalizeSpeed(speed: Float): Float = speed.coerceIn(0.5f, 2.0f)

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
