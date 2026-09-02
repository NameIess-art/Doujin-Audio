@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.doujin.audio.player.common

import com.doujin.audio.player.session.*

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.audio.SilenceSkippingAudioProcessor
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory

/**
 * Wake mode for a specific playback URI.
 *
 * [C.WAKE_MODE_NETWORK] additionally makes ExoPlayer hold a Wi-Fi lock, which
 * disables Wi-Fi power save. That is required for streamed items but pure
 * overhead for local files, so only network schemes opt into it.
 */
internal fun isNativePlaybackNetworkUri(uri: String?): Boolean {
    val scheme = uri
        ?.substringBefore("://", missingDelimiterValue = "")
        ?.trim()
        ?.lowercase()
        .orEmpty()
    return scheme == "http" || scheme == "https" || scheme == "rtsp" || scheme == "rtmp"
}

/**
 * Decided over the whole queue rather than the current item so the mode stays
 * stable across media-item transitions and a Wi-Fi lock is already held while
 * ExoPlayer prefetches an upcoming network item.
 */
internal fun nativePlaybackWakeModeForUris(uris: Iterable<String?>): Int {
    return if (uris.any(::isNativePlaybackNetworkUri)) {
        C.WAKE_MODE_NETWORK
    } else {
        C.WAKE_MODE_LOCAL
    }
}

/**
 * Keep the player's channel layout untouched by Android's optional spatializer.
 *
 * The library is responsible for the explicit audio effects below. Letting the
 * platform spatializer pick a layout can turn a separated stereo source into a
 * device-dependent center/mono image on some Android audio routes.
 */
internal fun nativePlaybackAudioAttributes(): androidx.media3.common.AudioAttributes =
    androidx.media3.common.AudioAttributes.Builder()
        .setUsage(C.USAGE_MEDIA)
        .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
        .setSpatializationBehavior(C.SPATIALIZATION_BEHAVIOR_NEVER)
        .build()

private const val ASMR_ACCEPT_LANGUAGE = "zh-CN,zh;q=0.9,en;q=0.8"

internal fun nativePlaybackRequestHeadersForHost(host: String?): Map<String, String> {
    val normalized = host?.trim()?.lowercase().orEmpty()
    val isAsmrMediaHost = normalized == "asmr.one" ||
        normalized.endsWith(".asmr.one") ||
        normalized == "asmr-100.com" ||
        normalized.endsWith(".asmr-100.com") ||
        normalized == "asmr-200.com" ||
        normalized.endsWith(".asmr-200.com") ||
        normalized == "asmr-300.com" ||
        normalized.endsWith(".asmr-300.com") ||
        normalized == "kiko-play-niptan.one" ||
        normalized.endsWith(".kiko-play-niptan.one")
    if (!isAsmrMediaHost) return emptyMap()
    return mapOf(
        "Accept-Language" to ASMR_ACCEPT_LANGUAGE
    )
}

internal interface NativePlayerEventCallbacks {
    fun onPlaybackStateChanged(sessionId: String, playbackState: Int)
    fun onMediaItemTransition(sessionId: String, reason: Int)
    fun onPlayerEvents(sessionId: String)
    fun onPlayWhenReadyChanged(sessionId: String, playWhenReady: Boolean, reason: Int)
    fun onIsPlayingChanged(sessionId: String, isPlaying: Boolean)
    fun onPlayerError(sessionId: String, error: PlaybackException)
    fun onAudioSessionIdChanged(sessionId: String, audioSessionId: Int)
}

internal class NativePlayerFactory(
    private val context: Context,
    private val callbacks: NativePlayerEventCallbacks
) {
    fun create(
        sessionId: String,
        audioProcessors: Array<AudioProcessor>
    ): ExoPlayer {
        val chain = DefaultAudioSink.DefaultAudioProcessorChain(
            audioProcessors,
            SilenceSkippingAudioProcessor(
                STRICT_SKIP_SILENCE_MIN_DURATION_US,
                20_000L,
                STRICT_SKIP_SILENCE_THRESHOLD_LEVEL
            ),
            SonicAudioProcessor()
        )
        val renderersFactory = object : DefaultRenderersFactory(context) {
            override fun buildAudioSink(
                context: Context,
                enableFloatOutput: Boolean,
                enableAudioTrackPlaybackParams: Boolean
            ) = DefaultAudioSink.Builder(context)
                .setAudioProcessorChain(chain)
                .setEnableFloatOutput(enableFloatOutput)
                .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
                .build()
        }
        val httpDataSourceFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(15_000)
            .setReadTimeoutMs(20_000)
        val defaultDataSourceFactory = DefaultDataSource.Factory(context, httpDataSourceFactory)
        val resolvingDataSourceFactory = ResolvingDataSource.Factory(defaultDataSourceFactory) { dataSpec ->
            val headers = nativePlaybackRequestHeadersForHost(dataSpec.uri.host)
            if (headers.isEmpty()) dataSpec else dataSpec.withAdditionalHeaders(headers)
        }
        val mediaSourceFactory = DefaultMediaSourceFactory(resolvingDataSourceFactory)

        return ExoPlayer.Builder(context, renderersFactory)
            .setMediaSourceFactory(mediaSourceFactory)
            // The session applies the URI-specific mode before prepare().
            .setWakeMode(C.WAKE_MODE_LOCAL)
            .setHandleAudioBecomingNoisy(false)
            .build()
            .also { player ->
                player.setAudioAttributes(
                    nativePlaybackAudioAttributes(),
                    /* handleAudioFocus = */ false,
                )
                player.addListener(object : Player.Listener {
                    override fun onPlaybackStateChanged(playbackState: Int) {
                        callbacks.onPlaybackStateChanged(sessionId, playbackState)
                    }

                    override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                        callbacks.onMediaItemTransition(sessionId, reason)
                    }

                    override fun onEvents(player: Player, events: Player.Events) {
                        callbacks.onPlayerEvents(sessionId)
                    }

                    override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                        callbacks.onPlayWhenReadyChanged(sessionId, playWhenReady, reason)
                    }

                    override fun onIsPlayingChanged(isPlaying: Boolean) {
                        callbacks.onIsPlayingChanged(sessionId, isPlaying)
                    }

                    override fun onPlayerError(error: PlaybackException) {
                        callbacks.onPlayerError(sessionId, error)
                    }

                    override fun onAudioSessionIdChanged(audioSessionId: Int) {
                        callbacks.onAudioSessionIdChanged(sessionId, audioSessionId)
                    }
                })
            }
    }
}
