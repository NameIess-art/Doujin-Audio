package com.doujin.audio.player.effects

import android.os.Handler
import android.os.SystemClock

internal class NativePlaybackResumeFade(
    private val handler: Handler,
    private val applyMultiplier: (String, Float) -> Unit
) {
    private var pending: Runnable? = null
    private var fadingSessionIds: List<String> = emptyList()

    fun cancel() {
        pending?.let(handler::removeCallbacks)
        pending = null
        val interruptedSessionIds = fadingSessionIds
        fadingSessionIds = emptyList()
        interruptedSessionIds.forEach { applyMultiplier(it, 1f) }
    }

    fun start(sessionIds: List<String>) {
        cancel()
        if (sessionIds.isEmpty()) return
        fadingSessionIds = sessionIds.toList()
        val durationMs = 10000L
        val intervalMs = 50L
        val startTime = SystemClock.uptimeMillis()
        sessionIds.forEach { applyMultiplier(it, 0f) }
        val runnable = object : Runnable {
            override fun run() {
                val elapsed = SystemClock.uptimeMillis() - startTime
                if (elapsed >= durationMs) {
                    cancel()
                } else {
                    val fraction = (elapsed.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f)
                    sessionIds.forEach { applyMultiplier(it, fraction) }
                    handler.postDelayed(this, intervalMs)
                }
            }
        }
        pending = runnable
        handler.postDelayed(runnable, intervalMs)
    }
}
