package com.doujin.audio.player.session

import android.os.Handler
import android.os.Looper

internal class NativePlaybackProgressPublisher(
    private val mainHandler: Handler,
    private val anchors: () -> List<NativePlaybackProgressAnchor>,
    private val listeners: () -> Collection<(Map<String, Any?>) -> Unit>
) {
    @Volatile
    private var closed = false

    fun publishAsync(nowElapsedRealtimeMs: Long) {
        if (closed) return
        if (Looper.myLooper() == mainHandler.looper) {
            publishOnMain(nowElapsedRealtimeMs)
        } else {
            mainHandler.post {
                if (!closed) publishOnMain(nowElapsedRealtimeMs)
            }
        }
    }

    fun shutdown() {
        closed = true
    }

    private fun publishOnMain(nowElapsedRealtimeMs: Long) {
        val activeListeners = listeners()
        if (activeListeners.isEmpty()) return
        val capturedAnchors = anchors()
        if (capturedAnchors.isEmpty()) return
        val event = buildNativePlaybackProgressEvent(capturedAnchors, nowElapsedRealtimeMs) ?: return
        activeListeners.forEach { listener ->
            try {
                listener(event)
            } catch (_: RuntimeException) {
            }
        }
    }
}
