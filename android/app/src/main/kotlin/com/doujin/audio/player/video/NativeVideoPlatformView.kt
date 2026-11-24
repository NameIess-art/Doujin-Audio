@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.doujin.audio.player.video

import com.doujin.audio.R
import com.doujin.audio.player.service.NativePlaybackService

import android.content.Context
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.media3.common.Player
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class NativeVideoPlatformViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    companion object {
        const val viewType = "com.doujin.audio/native_video_surface"
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

private class VideoSurfaceContainer(
    context: Context,
    private val onVisibilityChanged: () -> Unit
) : FrameLayout(context) {
    val isWindowVisible: Boolean
        get() = isAttachedToWindow && windowVisibility == View.VISIBLE

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        onVisibilityChanged()
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        onVisibilityChanged()
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        onVisibilityChanged()
    }
}

private class NativeVideoPlatformView(
    context: Context,
    viewId: Int,
    private val sessionId: String
) : PlatformView, NativeVideoOutputBinding<Player> {
    private val playerView = LayoutInflater.from(context)
        .inflate(R.layout.native_video_player_view, null, false) as PlayerView
    private val container = VideoSurfaceContainer(context, ::handleViewVisibilityChanged).apply {
        addView(
            playerView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )
    }
    private val ownerId = "native-video-$viewId-${System.identityHashCode(this)}"
    private val stateListenerId = "$ownerId-state"
    private var boundService: NativePlaybackService? = null
    private var disposed = false

    override val isViewVisible: Boolean
        get() = !disposed && container.isWindowVisible

    init {
        if (sessionId.isNotEmpty()) {
            NativePlaybackService.addControllerListener(ownerId) { service ->
                container.post { if (!disposed) connectToPlaybackService(service) }
            }
            connectToPlaybackService(NativePlaybackService.controller())
        }
    }

    override fun getView(): View = container

    override fun dispose() {
        if (disposed) return
        disposed = true
        NativePlaybackService.removeControllerListener(ownerId)
        boundService?.let { service ->
            service.removeStateListener(stateListenerId)
            service.unregisterVideoOutput(sessionId, ownerId)
        }
        boundService = null
        setKeepScreenOn(false)
        bindPlayer(null)
    }

    override fun bindPlayer(player: Player?) {
        playerView.player = player
    }

    override fun setKeepScreenOn(keepScreenOn: Boolean) {
        playerView.keepScreenOn = keepScreenOn
    }

    private fun connectToPlaybackService(service: NativePlaybackService?) {
        if (disposed || boundService === service) return
        boundService?.let { previous ->
            previous.removeStateListener(stateListenerId)
            previous.unregisterVideoOutput(sessionId, ownerId)
        }
        boundService = service
        if (service == null) {
            setKeepScreenOn(false)
            bindPlayer(null)
            return
        }
        service.registerVideoOutput(sessionId, ownerId, this)
        service.addStateListener(stateListenerId) { snapshot ->
            if (snapshot["sessionId"] != sessionId) return@addStateListener
            container.post {
                if (!disposed && boundService === service) {
                    service.refreshVideoOutput(sessionId, ownerId)
                }
            }
        }
    }

    private fun handleViewVisibilityChanged() {
        if (disposed) return
        boundService?.refreshVideoOutput(sessionId, ownerId)
    }
}
