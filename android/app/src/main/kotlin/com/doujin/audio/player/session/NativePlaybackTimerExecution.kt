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
        cancel()
        sessionIds.addAll(targets)
        this.generation = generation
        targets.forEach {
            setPauseAtEnd(it, true)
            restoreFade(it)
        }
    }

    fun generationFor(sessionId: String): Int? = generation.takeIf { sessionId in sessionIds }

    fun onTrackEnded(sessionId: String, expectedGeneration: Int?) {
        if (expectedGeneration == null || expectedGeneration != generation) return
        if (!sessionIds.remove(sessionId)) return
        setPauseAtEnd(sessionId, false)
        restoreFade(sessionId)
        if (sessionIds.isEmpty()) {
            onAllTracksFinished(generation)
            generation = null
        }
    }

    fun removeTarget(sessionId: String) = onTrackEnded(sessionId, generationFor(sessionId))

    fun cancel() {
        sessionIds.forEach {
            setPauseAtEnd(it, false)
            restoreFade(it)
        }
        sessionIds.clear()
        generation = null
    }
}
