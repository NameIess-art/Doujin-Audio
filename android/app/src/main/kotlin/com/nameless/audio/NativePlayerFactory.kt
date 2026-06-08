package com.nameless.audio

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.exoplayer.audio.DefaultAudioSink
internal fun nativePlaybackWakeMode(): Int = C.WAKE_MODE_NETWORK

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
        val renderersFactory = object : DefaultRenderersFactory(context) {
            override fun buildAudioSink(
                context: Context,
                enableFloatOutput: Boolean,
                enableAudioTrackPlaybackParams: Boolean
            ) = DefaultAudioSink.Builder(context)
                .setAudioProcessors(audioProcessors)
                .setEnableFloatOutput(enableFloatOutput)
                .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
                .build()
        }

        return ExoPlayer.Builder(context, renderersFactory)
            .setWakeMode(nativePlaybackWakeMode())
            .build()
            .also { player ->
                player.setAudioAttributes(
                    androidx.media3.common.AudioAttributes.Builder()
                        .setUsage(C.USAGE_MEDIA)
                        .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                        .build(),
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
