package com.doujin.audio.player.session

/** Owns armed track-end targets; playback state remains in each session. */
internal class NativePlaybackTimerExecution(
    private val setPauseAtEnd: (String, Boolean) -> Unit,
    private val restoreFade: (String) -> Unit,
    private val onAllTracksFinished: (Int?) -> Unit
) {
    private val sessionIds = mutableSetOf<String>()
    private var generation: Int? = null

    fun arm(targets: List<String>, generation: Int) {
        sessionIds.clear()
        sessionIds.addAll(targets)
        this.generation = generation
        targets.forEach {
            setPauseAtEnd(it, true)
            restoreFade(it)
        }
    }

    fun onTrackEnded(sessionId: String) {
        if (!sessionIds.remove(sessionId)) return
        setPauseAtEnd(sessionId, false)
        if (sessionIds.isEmpty()) {
            onAllTracksFinished(generation)
            generation = null
        }
    }

    fun cancel() {
        sessionIds.forEach { setPauseAtEnd(it, false) }
        sessionIds.clear()
        generation = null
    }
}
