package com.doujin.audio

import androidx.media3.common.Player
import com.doujin.audio.player.session.MediaSessionPlayer
import java.lang.reflect.Proxy
import org.junit.Assert.assertEquals
import org.junit.Test

class NativeMediaSessionCommandPolicyTest {
    @Test
    fun `repeated play forwards play intent even while already playing`() {
        val requests = mutableListOf<Boolean>()
        val player = mediaSessionPlayer(initiallyPlaying = true) {
            requests += it
            true
        }

        player.play()

        assertEquals(listOf(true), requests)
        assertEquals(true, player.playWhenReady)
    }

    @Test
    fun `repeated pause forwards pause intent even while already paused`() {
        val requests = mutableListOf<Boolean>()
        val player = mediaSessionPlayer(initiallyPlaying = false) {
            requests += it
            true
        }

        player.pause()

        assertEquals(listOf(false), requests)
        assertEquals(false, player.playWhenReady)
    }

    @Test
    fun `denied play cannot change the underlying player state`() {
        val player = mediaSessionPlayer(initiallyPlaying = false) { false }

        player.play()
        player.playWhenReady = true

        assertEquals(false, player.playWhenReady)
    }

    @Test
    fun `confirmed pause is reported once for an active session`() {
        var confirmedPauses = 0
        val player = mediaSessionPlayer(
            initiallyPlaying = true,
            onPaused = { confirmedPauses++ }
        ) { true }

        player.pause()
        player.pause()

        assertEquals(1, confirmedPauses)
        assertEquals(false, player.playWhenReady)
    }

    private fun mediaSessionPlayer(
        initiallyPlaying: Boolean,
        onPaused: () -> Unit = {},
        onSetPlayWhenReady: (Boolean) -> Boolean
    ): MediaSessionPlayer {
        var playing = initiallyPlaying
        val delegate = Proxy.newProxyInstance(
            Player::class.java.classLoader,
            arrayOf(Player::class.java)
        ) { _, method, args ->
            when (method.name) {
                "getPlayWhenReady" -> playing
                "setPlayWhenReady" -> {
                    playing = args[0] as Boolean
                    null
                }
                else -> error("Unexpected player call: ${method.name}")
            }
        } as Player
        return MediaSessionPlayer(delegate, onSetPlayWhenReady, onPaused)
    }
}
