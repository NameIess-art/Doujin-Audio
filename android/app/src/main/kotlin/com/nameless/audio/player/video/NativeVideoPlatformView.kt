@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.nameless.audio.player.video

import com.nameless.audio.R
import com.nameless.audio.player.service.NativePlaybackService

import android.content.Context
import android.view.LayoutInflater
import android.view.View
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

private const val PAUSED_FIRST_FRAME_RECOVERY_DELAY_MS = 450L
private const val SURFACE_REFRESH_DEBOUNCE_MS = 120L

internal fun shouldRecoverPausedVideoFrame(
    isAttachedToWindow: Boolean,
    isAwaitingFirstFrame: Boolean,
    isCurrentPlayer: Boolean,
    playWhenReady: Boolean,
    playbackState: Int,
    hasCurrentMediaItem: Boolean,
    canSeekCurrentMediaItem: Boolean
): Boolean =
    isAttachedToWindow &&
        isAwaitingFirstFrame &&
        isCurrentPlayer &&
        !playWhenReady &&
        (playbackState == Player.STATE_BUFFERING || playbackState == Player.STATE_READY) &&
        hasCurrentMediaItem &&
        canSeekCurrentMediaItem

class NativeVideoPlatformViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    companion object {
        const val viewType = "com.nameless.audio/native_video_surface"
    }

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val sessionId = (args as? Map<*, *>)
            ?.get("sessionId")
            ?.toString()
            ?.trim()
            .orEmpty()
        return NativeVideoPlatformView(context, viewId, sessionId)
    }
}

private class NativeVideoPlatformView(
    context: Context,
    viewId: Int,
    private val sessionId: String
) : PlatformView, NativeVideoOutputBinding<Player> {
    private val playerView = LayoutInflater.from(context)
        .inflate(R.layout.native_video_player_view, null, false) as PlayerView
    private val ownerId = "native-video-$viewId-${System.identityHashCode(this)}"
    private val stateListenerId = "$ownerId-state"
    private var boundService: NativePlaybackService? = null
    private var boundPlayer: Player? = null
    private var firstFrameListener: Player.Listener? = null
    private var playerBindingGeneration = 0L
    private var awaitingFirstFrame = false
    private var disposed = false
    private val connectRunnable = Runnable(::connectToPlaybackService)
    private val surfaceRefreshRunnable = Runnable(::refreshVideoSurface)
    private val pausedFrameRecoveryRunnable = Runnable(::recoverPausedVideoFrame)
    private val attachStateListener = object : View.OnAttachStateChangeListener {
        override fun onViewAttachedToWindow(view: View) {
            scheduleVideoSurfaceRefresh()
            schedulePausedFrameRecovery()
        }

        override fun onViewDetachedFromWindow(view: View) {
            playerView.removeCallbacks(surfaceRefreshRunnable)
            playerView.removeCallbacks(pausedFrameRecoveryRunnable)
        }
    }
    private val layoutChangeListener = View.OnLayoutChangeListener {
            _, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom ->
        val sizeChanged = right - left != oldRight - oldLeft ||
            bottom - top != oldBottom - oldTop
        if (sizeChanged) scheduleVideoSurfaceRefresh()
    }

    init {
        playerView.addOnAttachStateChangeListener(attachStateListener)
        playerView.addOnLayoutChangeListener(layoutChangeListener)
        if (sessionId.isNotEmpty()) {
            playerView.post(connectRunnable)
        }
    }

    override fun getView(): View = playerView

    override fun dispose() {
        if (disposed) return
        disposed = true
        playerView.removeCallbacks(connectRunnable)
        playerView.removeCallbacks(surfaceRefreshRunnable)
        playerView.removeCallbacks(pausedFrameRecoveryRunnable)
        playerView.removeOnAttachStateChangeListener(attachStateListener)
        playerView.removeOnLayoutChangeListener(layoutChangeListener)
        boundService?.let { service ->
            service.removeStateListener(stateListenerId)
            service.unregisterVideoOutput(sessionId, ownerId)
        }
        boundService = null
        setKeepScreenOn(false)
        bindPlayer(null)
    }

    override fun bindPlayer(player: Player?) {
        if (boundPlayer === player && playerView.player === player) return
        playerView.removeCallbacks(pausedFrameRecoveryRunnable)
        firstFrameListener?.let { listener -> boundPlayer?.removeListener(listener) }
        firstFrameListener = null
        playerBindingGeneration += 1
        boundPlayer = player
        awaitingFirstFrame = player != null
        if (player == null) {
            playerView.player = null
            return
        }

        val bindingGeneration = playerBindingGeneration
        val listener = object : Player.Listener {
            override fun onRenderedFirstFrame() {
                if (bindingGeneration != playerBindingGeneration || boundPlayer !== player) {
                    return
                }
                awaitingFirstFrame = false
                playerView.removeCallbacks(pausedFrameRecoveryRunnable)
            }
        }
        firstFrameListener = listener
        player.addListener(listener)
        playerView.player = player
        schedulePausedFrameRecovery()
    }

    override fun setKeepScreenOn(keepScreenOn: Boolean) {
        playerView.keepScreenOn = keepScreenOn
    }

    private fun connectToPlaybackService() {
        if (disposed || boundService != null) return
        val service = NativePlaybackService.controller()
        if (service == null) {
            playerView.postDelayed(connectRunnable, 100L)
            return
        }
        boundService = service
        service.registerVideoOutput(sessionId, ownerId, this)
        service.addStateListener(stateListenerId) { snapshot ->
            if (snapshot["sessionId"] != sessionId) return@addStateListener
            playerView.post {
                if (!disposed && boundService === service) {
                    service.refreshVideoOutput(sessionId, ownerId)
                    schedulePausedFrameRecovery()
                }
            }
        }
    }

    private fun scheduleVideoSurfaceRefresh() {
        if (disposed || boundService == null) return
        playerView.removeCallbacks(surfaceRefreshRunnable)
        playerView.postDelayed(surfaceRefreshRunnable, SURFACE_REFRESH_DEBOUNCE_MS)
    }

    private fun refreshVideoSurface() {
        if (disposed || !playerView.isAttachedToWindow) return
        boundService?.refreshVideoOutput(
            sessionId,
            ownerId,
            forceRebind = true
        )
    }

    private fun schedulePausedFrameRecovery() {
        if (disposed || !awaitingFirstFrame || !playerView.isAttachedToWindow) return
        playerView.removeCallbacks(pausedFrameRecoveryRunnable)
        playerView.postDelayed(
            pausedFrameRecoveryRunnable,
            PAUSED_FIRST_FRAME_RECOVERY_DELAY_MS
        )
    }

    private fun recoverPausedVideoFrame() {
        val player = boundPlayer ?: return
        val hasCurrentMediaItem = player.mediaItemCount > 0 &&
            player.currentMediaItemIndex != C.INDEX_UNSET
        if (!shouldRecoverPausedVideoFrame(
                isAttachedToWindow = playerView.isAttachedToWindow,
                isAwaitingFirstFrame = awaitingFirstFrame,
                isCurrentPlayer = playerView.player === player,
                playWhenReady = player.playWhenReady,
                playbackState = player.playbackState,
                hasCurrentMediaItem = hasCurrentMediaItem,
                canSeekCurrentMediaItem = player.isCommandAvailable(
                    Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM
                )
            )) {
            return
        }
        awaitingFirstFrame = false
        player.seekTo(
            player.currentMediaItemIndex,
            player.currentPosition.coerceAtLeast(0L)
        )
    }
}
