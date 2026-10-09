@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.doujin.audio.player.common

import com.doujin.audio.player.session.*

import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.DefaultLoadControl
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

/**
 * Network audio keeps its forward buffer through Doze/network throttling.
 * Local playback uses the smaller byte-bounded policy, including video; retaining
 * a back buffer for every player would multiply high-bitrate video memory.
 */
internal fun nativePlaybackLoadControl(): DefaultLoadControl =
    DefaultLoadControl.Builder()
        .setBufferDurationsMsForStreaming(
            /* minBufferMs = */ 60_000,
            /* maxBufferMs = */ 120_000,
            /* bufferForPlaybackMs = */ 2_500,
            /* bufferForPlaybackAfterRebufferMs = */ 5_000
        )
        .setBufferDurationsMsForLocalPlayback(
            DefaultLoadControl.DEFAULT_MIN_BUFFER_FOR_LOCAL_PLAYBACK_MS,
            DefaultLoadControl.DEFAULT_MAX_BUFFER_FOR_LOCAL_PLAYBACK_MS,
            DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_FOR_LOCAL_PLAYBACK_MS,
            DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_FOR_LOCAL_PLAYBACK_MS
        )
        .setPrioritizeTimeOverSizeThresholdsForStreaming(true)
        .setPrioritizeTimeOverSizeThresholdsForLocalPlayback(false)
        .setBackBuffer(0, false)
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
}

internal class NativePlayerFactory(
    private val context: Context,
    private val resolveUriToPath: (String) -> String? = { null },
    private val isCurrentPlayer: (String, Player) -> Boolean,
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
            // ResolvingDataSource runs on the loader thread, never on the player's
            // application Looper. SAF filesystem checks belong here.
            val resolved = if (dataSpec.uri.scheme == "content") {
                resolveUriToPath(dataSpec.uri.toString())?.let { path ->
                    java.io.File(path).takeIf { it.exists() && it.canRead() }
                }?.let { dataSpec.withUri(Uri.fromFile(it)) } ?: dataSpec
            } else dataSpec
            val headers = nativePlaybackRequestHeadersForHost(resolved.uri.host)
            if (headers.isEmpty()) resolved else resolved.withAdditionalHeaders(headers)
        }
        val mediaSourceFactory = DefaultMediaSourceFactory(resolvingDataSourceFactory)

        return ExoPlayer.Builder(context, renderersFactory)
            .setMediaSourceFactory(mediaSourceFactory)
            .setLoadControl(nativePlaybackLoadControl())
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
                        if (!isCurrentPlayer(sessionId, player) || player.playbackState != playbackState) return
                        callbacks.onPlaybackStateChanged(sessionId, playbackState)
                    }

                    override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                        if (!isCurrentPlayer(sessionId, player)) return
                        callbacks.onMediaItemTransition(sessionId, reason)
                    }

                    override fun onEvents(player: Player, events: Player.Events) {
                        if (!isCurrentPlayer(sessionId, player)) return
                        callbacks.onPlayerEvents(sessionId)
                    }

                    override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                        if (!isCurrentPlayer(sessionId, player) || player.playWhenReady != playWhenReady) return
                        callbacks.onPlayWhenReadyChanged(sessionId, playWhenReady, reason)
                    }

                    override fun onIsPlayingChanged(isPlaying: Boolean) {
                        if (!isCurrentPlayer(sessionId, player)) return
                        callbacks.onIsPlayingChanged(sessionId, isPlaying)
                    }

                    override fun onPlayerError(error: PlaybackException) {
                        if (!isCurrentPlayer(sessionId, player)) return
                        callbacks.onPlayerError(sessionId, error)
                    }
                })
            }
    }
}
