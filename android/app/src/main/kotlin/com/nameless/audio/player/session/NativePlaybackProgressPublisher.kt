package com.nameless.audio.player.session

import android.os.Handler
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

internal class NativePlaybackProgressPublisher(
    private val mainHandler: Handler,
    private val anchors: () -> List<NativePlaybackProgressAnchor>,
    private val currentAnchors: () -> Map<String, NativePlaybackProgressAnchor>,
    private val listeners: () -> Collection<(Map<String, Any?>) -> Unit>
) {
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "NativePlaybackProgress").apply { isDaemon = true }
    }
    private val inFlight = AtomicBoolean(false)

    fun publishAsync(nowElapsedRealtimeMs: Long) {
        if (!inFlight.compareAndSet(false, true)) return
        val capturedAnchors = anchors()
        executor.execute {
            val event = buildNativePlaybackProgressEvent(capturedAnchors, nowElapsedRealtimeMs)
            mainHandler.post {
                try {
                    publishValidUpdates(capturedAnchors, event)
                } finally {
                    inFlight.set(false)
                }
            }
        }
    }

    fun shutdown() {
        executor.shutdownNow()
    }

    private fun publishValidUpdates(
        capturedAnchors: List<NativePlaybackProgressAnchor>,
        event: Map<String, Any?>?
    ) {
        val activeListeners = listeners()
        if (event == null || activeListeners.isEmpty()) return

        val latestAnchors = currentAnchors()
        val validSessionIds = capturedAnchors
            .filter { anchor -> latestAnchors[anchor.sessionId] === anchor }
            .mapTo(hashSetOf()) { it.sessionId }
        val validUpdates = (event["updates"] as? List<*>)
            ?.filter { rawUpdate ->
                val update = rawUpdate as? Map<*, *> ?: return@filter false
                update["sessionId"] in validSessionIds
            }
            .orEmpty()
        if (validUpdates.isEmpty()) return

        val validEvent = event.toMutableMap().apply {
            this["updates"] = validUpdates
        }
        activeListeners.forEach { listener ->
            try {
                listener(validEvent)
            } catch (_: RuntimeException) {
            }
        }
    }
}
