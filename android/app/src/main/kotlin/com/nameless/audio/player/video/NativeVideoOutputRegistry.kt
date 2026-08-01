package com.nameless.audio.player.video

internal interface NativeVideoOutputBinding<P : Any> {
    fun bindPlayer(player: P?)
    fun setKeepScreenOn(keepScreenOn: Boolean)
}

internal class NativeVideoOutputRegistry<P : Any>(
    private val playerForSession: (String) -> P?,
    private val shouldKeepScreenOn: (P) -> Boolean
) {
    private data class Entry<P : Any>(
        val ownerId: String,
        val output: NativeVideoOutputBinding<P>,
        var player: P? = null
    )

    private val entries = mutableMapOf<String, Entry<P>>()

    fun register(
        sessionId: String,
        ownerId: String,
        output: NativeVideoOutputBinding<P>
    ) {
        val previous = entries.put(sessionId, Entry(ownerId, output))
        if (previous != null && previous.output !== output) {
            previous.output.setKeepScreenOn(false)
            previous.output.bindPlayer(null)
        }
        refresh(sessionId, ownerId)
    }

    fun refresh(sessionId: String, ownerId: String): Boolean {
        val entry = entries[sessionId]?.takeIf { it.ownerId == ownerId } ?: return false
        val player = playerForSession(sessionId)
        if (entry.player !== player) {
            entry.output.bindPlayer(player)
            entry.player = player
        }
        entry.output.setKeepScreenOn(player?.let(shouldKeepScreenOn) == true)
        return true
    }

    fun unregister(sessionId: String, ownerId: String) {
        val entry = entries[sessionId]?.takeIf { it.ownerId == ownerId } ?: return
        entries.remove(sessionId)
        entry.output.setKeepScreenOn(false)
        entry.output.bindPlayer(null)
    }

    fun clear() {
        entries.values.forEach { entry ->
            entry.output.setKeepScreenOn(false)
            entry.output.bindPlayer(null)
        }
        entries.clear()
    }
}
