package com.nameless.audio

import com.nameless.audio.player.video.NativeVideoOutputBinding
import com.nameless.audio.player.video.NativeVideoOutputRegistry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeVideoOutputRegistryTest {
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
