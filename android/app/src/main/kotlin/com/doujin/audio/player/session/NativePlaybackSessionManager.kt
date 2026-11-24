package com.doujin.audio.player.session

import androidx.media3.common.Player

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

    fun reusableSessionFor(
        sessionId: String,
        queueStartIndex: Int,
        uri: String,
        explicitPath: String?
    ): NativePlaybackSession? = sessions[sessionId]?.takeIf {
        it.matchesReusableQueueItem(queueStartIndex, uri, explicitPath)
    }

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

    fun focus(sessionId: String?): Boolean {
        if (sessionId != null && !sessions.containsKey(sessionId)) return false
        focusedSessionId = sessionId
        return true
    }

    private fun NativePlaybackSession.isPlaybackActive(): Boolean =
        playerOrNull()?.let { player ->
            (player.playbackState == Player.STATE_READY || player.playbackState == Player.STATE_BUFFERING) &&
                player.playWhenReady
        } == true

    fun activePlaybackSessionIds(): List<String> = sessions.values
        .filter { it.isPlaybackActive() }
        .map(NativePlaybackSession::sessionId)

    fun hasActivePlayback(): Boolean = sessions.values.any { it.isPlaybackActive() }

    fun hasNetworkPlaybackToKeepAlive(isIntended: (String) -> Boolean): Boolean =
        sessions.values.any { session ->
            (session.isPlaybackActive() || isIntended(session.sessionId)) &&
                session.requiresNetworkWakeLock
        }

    fun playbackIntentBySessionId(isIntended: (String) -> Boolean): Map<String, Boolean> =
        sessions.values.associate { candidate ->
            val player = candidate.playerOrNull()
            candidate.sessionId to (
                isIntended(candidate.sessionId) ||
                    player?.isPlaying == true ||
                    player?.playWhenReady == true
                )
        }

    fun usageItems(): List<Map<String, Any?>> = sessions.values.mapNotNull(NativePlaybackSession::usageItem)

    fun storedSnapshots(intendedSessionIds: Set<String>): List<StoredNativePlaybackSession> =
        sessions.values.filterNot { it.isTemporary }.map { session ->
            val stored = session.storedSnapshot()
            when {
                session.sessionId in intendedSessionIds -> stored.copy(playWhenReady = true)
                session.playerOrNull()?.playerError != null -> stored.copy(playing = false, playWhenReady = false)
                else -> stored
            }
        }

    fun snapshot(): Map<String, Any?> = mapOf(
        "sessions" to sessions.values.map { it.snapshot(includeRetainedUris = true) },
        "focusedSessionId" to focusedSessionId
    )

    fun playbackLogState(session: NativePlaybackSession? = null): String {
        val target = session ?: foregroundSessionCandidate()
        val player = target?.playerOrNull()
        return "sessionId=${target?.sessionId ?: "<none>"} " +
            "playWhenReady=${player?.playWhenReady ?: target?.lastPlayWhenReady} " +
            "isPlaying=${player?.isPlaying ?: target?.lastIsPlaying} " +
            "playbackState=${player?.playbackStateName() ?: target?.lastPlaybackState} "
    }

    fun mediaSessionCandidate(): NativePlaybackSession? {
        val focused = focusedSessionId?.let { sessions[it] }?.takeIf { it.playerOrNull() != null }
        if (focused != null && focused.isPlaybackActive()) {
            return focused
        }
        return sessions.values.firstOrNull { it.playerOrNull() != null && it.isPlaybackActive() }
            ?: focused
            ?: sessions.values.firstOrNull { it.playerOrNull() != null }
    }

    fun foregroundSessionCandidate(): NativePlaybackSession? {
        val focused = focusedSessionId?.let { sessions[it] }
        if (focused != null && focused.isPlaybackActive()) {
            return focused
        }
        return sessions.values.firstOrNull { it.isPlaybackActive() }
            ?: focused
            ?: sessions.values.firstOrNull()
    }

    val hasProgressSessions: Boolean get() = activeProgressSessions.isNotEmpty()

    fun updateProgressSession(sessionId: String) {
        val session = sessions[sessionId] ?: return
        val anchor = session.progressAnchorSnapshot()
        if (session.lastPlaybackState != "completed" &&
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
        isRecoveryPending: (String) -> Boolean,
        shouldRetainPlayer: (NativePlaybackSession) -> Boolean = { false },
        beforeRelease: (NativePlaybackSession) -> Unit = {}
    ): List<NativePlaybackSession> {
        val idleSessions = sessions.values
            .filter { session ->
                val player = session.playerOrNull() ?: return@filter false
                !player.isPlaying &&
                    !player.playWhenReady &&
                    !shouldRetainPlayer(session) &&
                    !isIntended(session.sessionId) &&
                    !isFocusPending(session.sessionId) &&
                    !isRecoveryPending(session.sessionId)
            }
        idleSessions
            .forEach { session ->
                beforeRelease(session)
                session.releasePlayer()
            }
        return idleSessions
    }

    fun releaseIdleSession(
        session: NativePlaybackSession,
        persistence: NativePlaybackStatePersistenceCoordinator,
        processingState: String = "idle",
        publish: (NativePlaybackSession) -> Unit
    ): Map<String, Any?> {
        session.playerOrNull()?.pause()
        session.releasePlayer()
        session.lastIsPlaying = false
        session.lastPlayWhenReady = false
        session.lastPlaybackState = processingState
        val snapshot = session.snapshot()
        persistence.persistSession(session.storedSnapshot(), session.definitionRevision)
        publish(session)
        remove(session.sessionId)
        return snapshot
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
