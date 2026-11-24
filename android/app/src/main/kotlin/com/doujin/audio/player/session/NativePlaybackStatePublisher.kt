package com.doujin.audio.player.session

import android.os.Handler
import android.os.Looper
import java.util.concurrent.ConcurrentHashMap

internal class NativePlaybackStatePublisher(
    private val mainHandler: Handler,
    private val sessions: NativePlaybackSessionManager,
    private val beforeSessionState: (String) -> Unit,
    private val afterSessionState: () -> Unit
) {
    private val listeners = ConcurrentHashMap<String, (Map<String, Any?>) -> Unit>()
    private val pendingSessions = linkedSetOf<String>()
    private val pendingPositionChanges = hashSetOf<String>()
    private val publishPendingStates = Runnable {
        val pending = pendingSessions.toList()
        val positionChanged = pendingPositionChanges.toSet()
        pendingSessions.clear()
        pendingPositionChanges.clear()
        pending.forEach { sessionId ->
            publishSessionState(sessionId, includePositionChange = sessionId in positionChanged)
        }
    }

    val hasListeners: Boolean get() = listeners.isNotEmpty()

    @Volatile
    private var closed = false

    fun addListener(ownerId: String, listener: (Map<String, Any?>) -> Unit) {
        listeners[ownerId] = listener
        sessions.forEach {
            listener(it.snapshot())
            sessions.updateProgressSession(it.sessionId)
        }
    }

    fun removeListener(ownerId: String) {
        listeners.remove(ownerId)
    }

    fun scheduleSessionState(sessionId: String, positionChanged: Boolean) {
        pendingSessions.add(sessionId)
        if (positionChanged) pendingPositionChanges.add(sessionId)
        mainHandler.removeCallbacks(publishPendingStates)
        mainHandler.post(publishPendingStates)
    }

    fun cancelScheduledSessionState(sessionId: String) {
        pendingSessions.remove(sessionId)
        pendingPositionChanges.remove(sessionId)
    }

    fun publishTerminalSessionState(session: NativePlaybackSession): Map<String, Any?> =
        publishNativePlaybackSessionState(session, listeners.values, includePositionChange = true)

    fun publishSessionState(
        sessionId: String,
        includePositionChange: Boolean = false
    ): Map<String, Any?>? {
        cancelScheduledSessionState(sessionId)
        val session = sessions.get(sessionId) ?: return null
        beforeSessionState(sessionId)
        val snapshot = publishNativePlaybackSessionState(
            session,
            listeners.values,
            includePositionChange = includePositionChange
        )
        sessions.updateProgressSession(sessionId)
        afterSessionState()
        return snapshot
    }

    fun publishResumePauseBatch(sessionIds: List<String>) {
        publishResumePauseBatchSnapshots(
            sessionIds.mapNotNull { sessions.get(it)?.snapshot() }
        )
    }

    fun publishResumePauseBatchSnapshots(snapshots: List<Map<String, Any?>>) {
        if (snapshots.isEmpty()) return
        val event = mapOf("eventType" to "resumePauseBatch", "sessions" to snapshots)
        listeners.values.forEach { it(event) }
    }

    fun publishAllSessionStates() {
        sessions.sessionIds.toList().forEach { publishSessionState(it) }
    }

    fun publishProgress(nowElapsedRealtimeMs: Long) {
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
        listeners.clear()
        mainHandler.removeCallbacks(publishPendingStates)
        pendingSessions.clear()
        pendingPositionChanges.clear()
    }

    private fun publishOnMain(nowElapsedRealtimeMs: Long) {
        val activeListeners = listeners.values
        if (activeListeners.isEmpty()) return
        val capturedAnchors = sessions.progressAnchors()
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
