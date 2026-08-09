package com.doujin.audio

import com.doujin.audio.player.video.NativeVideoOutputBinding
import com.doujin.audio.player.video.NativeVideoOutputRegistry
import com.doujin.audio.player.video.shouldRecoverPausedVideoFrame

import androidx.media3.common.Player
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeVideoOutputRegistryTest {
    @Test
    fun `paused video frame recovery only runs for an attached current surface awaiting its first frame`() {
        fun shouldRecover(
            attached: Boolean = true,
            awaiting: Boolean = true,
            current: Boolean = true,
            playWhenReady: Boolean = false,
            state: Int = Player.STATE_READY,
            hasItem: Boolean = true,
            canSeek: Boolean = true
        ): Boolean = shouldRecoverPausedVideoFrame(
            isAttachedToWindow = attached,
            isAwaitingFirstFrame = awaiting,
            isCurrentPlayer = current,
            playWhenReady = playWhenReady,
            playbackState = state,
            hasCurrentMediaItem = hasItem,
            canSeekCurrentMediaItem = canSeek
        )

        assertTrue(shouldRecover())
        assertTrue(
            shouldRecover(state = Player.STATE_BUFFERING)
        )
        assertFalse(shouldRecover(attached = false))
        assertFalse(shouldRecover(awaiting = false))
        assertFalse(shouldRecover(current = false))
        assertFalse(shouldRecover(playWhenReady = true))
        assertFalse(shouldRecover(hasItem = false))
        assertFalse(shouldRecover(canSeek = false))
        assertFalse(shouldRecover(state = Player.STATE_IDLE))
        assertFalse(shouldRecover(state = Player.STATE_ENDED))
    }

    @Test
    fun `register binds the current player and refresh follows replacement`() {
        val firstPlayer = FakePlayer(playing = true)
        val secondPlayer = FakePlayer(playing = false)
        var player: FakePlayer? = firstPlayer
        val output = FakeOutput()
        val registry = NativeVideoOutputRegistry<FakePlayer>(
            playerForSession = { player },
            shouldKeepScreenOn = FakePlayer::playing
        )

        registry.register("session", "owner", output)

        assertSame(firstPlayer, output.player)
        assertTrue(output.screenKeptOn)

        player = secondPlayer
        assertTrue(registry.refresh("session", "owner"))
        assertSame(secondPlayer, output.player)
        assertFalse(output.screenKeptOn)
    }

    @Test
    fun `new owner detaches old output and stale refresh cannot reclaim it`() {
        val player = FakePlayer(playing = true)
        val oldOutput = FakeOutput()
        val newOutput = FakeOutput()
        val registry = NativeVideoOutputRegistry<FakePlayer>(
            playerForSession = { player },
            shouldKeepScreenOn = FakePlayer::playing
        )

        registry.register("session", "inline", oldOutput)
        registry.register("session", "fullscreen", newOutput)

        assertNull(oldOutput.player)
        assertFalse(oldOutput.screenKeptOn)
        assertSame(player, newOutput.player)
        assertFalse(registry.refresh("session", "inline"))
        assertFalse(registry.refresh("session", "inline", forceRebind = true))
        assertSame(player, newOutput.player)
    }

    @Test
    fun `stale unregister leaves active output attached`() {
        val player = FakePlayer(playing = true)
        val oldOutput = FakeOutput()
        val newOutput = FakeOutput()
        val registry = NativeVideoOutputRegistry<FakePlayer>(
            playerForSession = { player },
            shouldKeepScreenOn = FakePlayer::playing
        )

        registry.register("session", "inline", oldOutput)
        registry.register("session", "fullscreen", newOutput)
        registry.unregister("session", "inline")

        assertSame(player, newOutput.player)
        assertEquals(1, newOutput.boundPlayers.size)

        registry.unregister("session", "fullscreen")
        assertNull(newOutput.player)
        assertFalse(newOutput.screenKeptOn)
    }

    @Test
    fun `forced refresh rebinds the same player after surface recreation`() {
        val player = FakePlayer(playing = true)
        val output = FakeOutput()
        val registry = NativeVideoOutputRegistry<FakePlayer>(
            playerForSession = { player },
            shouldKeepScreenOn = FakePlayer::playing
        )

        registry.register("session", "owner", output)

        assertTrue(registry.refresh("session", "owner", forceRebind = true))
        assertEquals(listOf(player, null, player), output.boundPlayers)
        assertSame(player, output.player)
        assertTrue(output.screenKeptOn)
    }
}

private data class FakePlayer(val playing: Boolean)

private class FakeOutput : NativeVideoOutputBinding<FakePlayer> {
    var player: FakePlayer? = null
    var screenKeptOn: Boolean = false
    val boundPlayers = mutableListOf<FakePlayer?>()

    override fun bindPlayer(player: FakePlayer?) {
        this.player = player
        boundPlayers += player
    }

    override fun setKeepScreenOn(keepScreenOn: Boolean) {
        screenKeptOn = keepScreenOn
    }
}
