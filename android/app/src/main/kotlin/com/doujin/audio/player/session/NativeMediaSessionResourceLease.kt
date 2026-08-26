package com.doujin.audio.player.session

internal class NativeMediaSessionResourceLease<Session : Any, Player : Any> {
    var currentSession: Session? = null
        private set
    private var bootstrapPlayer: Player? = null
    val hasResources: Boolean
        get() = currentSession != null || bootstrapPlayer != null

    fun installBootstrap(
        createPlayer: () -> Player,
        createSession: (Player) -> Session,
        releasePlayer: (Player) -> Unit
    ): Session {
        currentSession?.let { return it }
        val player = createPlayer()
        return try {
            createSession(player).also { session ->
                bootstrapPlayer = player
                currentSession = session
            }
        } catch (error: Throwable) {
            runCatching { releasePlayer(player) }
            throw error
        }
    }

    fun installSession(createSession: () -> Session): Session =
        currentSession ?: createSession().also { currentSession = it }

    fun onPlayerAttached(releasePlayer: (Player) -> Unit) {
        val player = bootstrapPlayer ?: return
        bootstrapPlayer = null
        releasePlayer(player)
    }

    fun release(
        releaseSession: (Session) -> Unit,
        releasePlayer: (Player) -> Unit
    ) {
        val session = currentSession
        val player = bootstrapPlayer
        currentSession = null
        bootstrapPlayer = null
        var firstFailure: Throwable? = null
        if (session != null) {
            try {
                releaseSession(session)
            } catch (error: Throwable) {
                firstFailure = error
            }
        }
        if (player != null) {
            try {
                releasePlayer(player)
            } catch (error: Throwable) {
                if (firstFailure == null) firstFailure = error
            }
        }
        firstFailure?.let { throw it }
    }
}
