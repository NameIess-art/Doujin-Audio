package com.doujin.audio.player.session

import androidx.media3.common.Player
import com.doujin.audio.player.common.isNativePlaybackNetworkUri
import com.doujin.audio.player.service.resolveNotificationSessionId
import com.doujin.audio.player.service.idlePlaybackSessionIdsToRelease

internal class NativePlaybackSessionManager(
    private val sessionFactory: (sessionId: String) -> NativePlaybackSession
) {
    private val sessions = linkedMapOf<String, NativePlaybackSession>()
    private val activeProgressSessions = linkedMapOf<String, NativePlaybackSession>()

    @Volatile
    var focusedSessionId: String? = null

    val size: Int get() = sessions.size
    val isEmpty: Boolean get() = sessions.isEmpty()
    val isNotEmpty: Boolean get() = sessions.isNotEmpty()
    val sessionIds: Set<String> get() = sessions.keys
    val allSessions: List<NativePlaybackSession> get() = sessions.values.toList()

    fun get(sessionId: String): NativePlaybackSession? = sessions[sessionId]

    fun contains(sessionId: String): Boolean = sessions.containsKey(sessionId)

    fun getOrCreate(sessionId: String): NativePlaybackSession {
        return sessions.getOrPut(sessionId) {
            sessionFactory(sessionId)
        }
    }

    fun remove(sessionId: String): NativePlaybackSession? {
        val removed = sessions.remove(sessionId)
        activeProgressSessions.remove(sessionId)
        if (focusedSessionId == sessionId) {
            focusedSessionId = sessions.keys.firstOrNull()
        }
        return removed
    }

    fun focusedSession(): NativePlaybackSession? {
        return focusedSessionId?.let { sessions[it] } ?: sessions.values.firstOrNull()
    }

    fun notificationSessionId(
        requestedSessionId: String,
        storedSessions: List<StoredNativePlaybackSession>
    ): String = resolveNotificationSessionId(
        requestedSessionId = requestedSessionId,
        focusedSessionId = focusedSessionId,
        activeSessionIds = sessions.values.filter { it.isPlaying() }.map { it.sessionId },
        existingSessionIds = sessionIds,
        storedActiveSessionIds = storedSessions.filter { it.playing || it.playWhenReady }.map { it.sessionId },
        storedSessionIds = storedSessions.map { it.sessionId }
    )

    fun focus(sessionId: String?): Boolean {
        if (sessionId != null && !sessions.containsKey(sessionId)) return false
        focusedSessionId = sessionId
        return true
    }

    fun ensureFallbackFocus(): String? {
        if (focusedSessionId == null || !sessions.containsKey(focusedSessionId)) {
            focusedSessionId = sessions.keys.firstOrNull()
        }
        return focusedSessionId
    }

    fun activePlaybackSessionIds(): List<String> = sessions.values
        .filter { session ->
            session.playerOrNull()?.let { player ->
                player.isPlaying || player.playWhenReady
            } == true
        }
        .map(NativePlaybackSession::sessionId)

    fun hasActivePlayback(): Boolean = sessions.values.any {
        val p = it.playerOrNull()
        p != null && (p.isPlaying || p.playWhenReady)
    }

    fun hasNetworkPlayback(isIntended: (String) -> Boolean): Boolean = sessions.values.any { session ->
        val player = session.playerOrNull()
        (player?.isPlaying == true || player?.playWhenReady == true || isIntended(session.sessionId)) &&
            isNativePlaybackNetworkUri(session.uri)
    }

    fun storedSnapshots(intendedSessionIds: Set<String>): List<StoredNativePlaybackSession> =
        sessions.values.filterNot { it.isTemporary }.map { session ->
            session.storedSnapshot().let { stored ->
                if (session.sessionId in intendedSessionIds) stored.copy(playWhenReady = true) else stored
            }
        }

    fun snapshot(): Map<String, Any?> = mapOf(
        "sessions" to sessions.values.map { it.snapshot(includeRetainedUris = true) },
        "focusedSessionId" to focusedSessionId
    )

    fun playbackLogState(session: NativePlaybackSession? = null): String {
        val target = session ?: foregroundSessionCandidate()
        val player = target?.playerOrNull()
        val title = target?.title?.replace('\n', ' ')?.replace('\r', ' ')?.take(80) ?: "<none>"
        return "sessionId=${target?.sessionId ?: "<none>"} title=\"$title\" " +
            "playWhenReady=${player?.playWhenReady ?: target?.lastPlayWhenReady} " +
            "isPlaying=${player?.isPlaying ?: target?.lastIsPlaying} " +
            "playbackState=${player?.playbackStateName() ?: target?.lastPlaybackState} "
    }

    fun mediaSessionCandidate(): NativePlaybackSession? {
        focusedSessionId?.let { sessions[it] }?.takeIf { it.playerOrNull() != null }?.let {
            return it
        }
        return sessions.values.firstOrNull { it.playerOrNull() != null }
    }

    fun foregroundSessionCandidate(): NativePlaybackSession? {
        return focusedSessionId?.let { sessions[it] }
            ?: sessions.values.firstOrNull { session ->
                val player = session.playerOrNull()
                player != null && (player.isPlaying || player.playWhenReady)
            }
            ?: sessions.values.firstOrNull()
    }

    val hasProgressSessions: Boolean get() = activeProgressSessions.isNotEmpty()

    fun updateProgressSession(sessionId: String) {
        val session = sessions[sessionId] ?: return
        val anchor = session.progressAnchorSnapshot()
        if (session.lastPlaybackState != "ended" &&
            shouldIncludeInProgressHeartbeat(anchor.isPlaying, anchor.playWhenReady)
        ) {
            activeProgressSessions[sessionId] = session
        } else {
            activeProgressSessions.remove(sessionId)
        }
    }

    fun progressAnchors(): List<NativePlaybackProgressAnchor> =
        activeProgressSessions.values.map(NativePlaybackSession::progressAnchorSnapshot)

    fun progressAnchorsMap(): Map<String, NativePlaybackProgressAnchor> =
        activeProgressSessions.mapValues { (_, session) -> session.progressAnchorSnapshot() }

    fun applyFocusDuckMultiplier(multiplier: Float) {
        sessions.values.forEach { it.applyFocusDuckMultiplier(multiplier) }
    }

    fun evictIdlePlayers(
        isIntended: (String) -> Boolean,
        isFocusPending: (String) -> Boolean,
        isRecoveryPending: (String) -> Boolean
    ) {
        val idleSessions = sessions.values
            .filter { session ->
                val player = session.playerOrNull() ?: return@filter false
                !player.isPlaying &&
                    !player.playWhenReady &&
                    !isIntended(session.sessionId) &&
                    !isFocusPending(session.sessionId) &&
                    !isRecoveryPending(session.sessionId)
            }
        val releaseIds = idlePlaybackSessionIdsToRelease(
            focusedSessionId = focusedSessionId,
            idleSessionIds = idleSessions.map { it.sessionId }
        )
        idleSessions
            .filter { it.sessionId in releaseIds }
            .sortedBy { it.lastUsedMs }
            .forEach(NativePlaybackSession::releasePlayer)
    }

    fun releaseAll(): List<() -> Unit> {
        val actions = sessions.values.map { session -> { session.release() } }
        return actions
    }

    fun clear() {
        sessions.clear()
        activeProgressSessions.clear()
        focusedSessionId = null
    }

    fun forEach(action: (NativePlaybackSession) -> Unit) {
        sessions.values.forEach(action)
    }

    fun playerForSession(sessionId: String): Player? = sessions[sessionId]?.playerOrNull()
}
