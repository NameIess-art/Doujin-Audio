package com.doujin.audio.player.video

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.Player
import com.doujin.audio.metadata.MediaNameMetadata

internal fun shouldRetainPausedVideoPlayer(
    player: Player?,
    hasVideoOutput: Boolean,
    mediaPath: String? = null
): Boolean {
    if (player == null || player.playerError != null) return false
    // Pausing before track discovery still needs the decoder when the detail page opens.
    return hasVideoOutput || player.currentTracks.containsType(C.TRACK_TYPE_VIDEO) ||
        (player.videoSize.width > 0 && player.videoSize.height > 0) ||
        mediaPath?.let {
            MediaNameMetadata.mediaNameInfoOrNull(Uri.parse(it).lastPathSegment ?: it)?.isVideo
        } == true
}

internal interface NativeVideoOutputBinding<P : Any> {
    val isViewVisible: Boolean get() = true
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
    private var screenInteractive: Boolean = true

    fun hasOutput(sessionId: String): Boolean = entries.containsKey(sessionId)

    fun setScreenInteractive(interactive: Boolean) {
        if (screenInteractive == interactive) return
        screenInteractive = interactive
        entries.keys.toList().forEach(::refreshSession)
    }

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

    fun refresh(
        sessionId: String,
        ownerId: String
    ): Boolean {
        val entry = entries[sessionId]?.takeIf { it.ownerId == ownerId } ?: return false
        val canRender = screenInteractive && entry.output.isViewVisible
        val player = if (canRender) playerForSession(sessionId) else null
        if (entry.player !== player) {
            entry.output.bindPlayer(player)
            entry.player = player
        }
        entry.output.setKeepScreenOn(player != null && shouldKeepScreenOn(player))
        return true
    }

    fun refreshSession(sessionId: String): Boolean {
        val entry = entries[sessionId] ?: return false
        return refresh(sessionId, entry.ownerId)
    }

    fun unregister(sessionId: String, ownerId: String) {
        val entry = entries[sessionId]?.takeIf { it.ownerId == ownerId } ?: return
        entries.remove(sessionId)
        entry.output.setKeepScreenOn(false)
        entry.output.bindPlayer(null)
    }

    fun detachPlayer(sessionId: String) {
        val entry = entries[sessionId] ?: return
        entry.output.setKeepScreenOn(false)
        entry.output.bindPlayer(null)
        entry.player = null
    }

    fun clear() {
        entries.values.forEach { entry ->
            entry.output.setKeepScreenOn(false)
            entry.output.bindPlayer(null)
        }
        entries.clear()
    }
}
