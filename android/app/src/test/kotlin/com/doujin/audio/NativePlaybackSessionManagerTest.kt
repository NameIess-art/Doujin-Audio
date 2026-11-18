package com.doujin.audio

import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import com.doujin.audio.player.session.*
import java.lang.reflect.Proxy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackSessionManagerTest {
    @Test
    fun `progress observes active sessions without retaining idle entries`() {
        val manager = NativePlaybackSessionManager(::createTestSession)
        repeat(100) { manager.getOrCreate("idle-$it").snapshot() }
        assertFalse(manager.hasProgressSessions)
        assertTrue(manager.progressAnchors().isEmpty())
        val active = manager.getOrCreate("active")
        active.lastPlayWhenReady = true
        active.snapshot()
        manager.updateProgressSession("active")
        assertEquals(listOf("active"), manager.progressAnchors().map { it.sessionId })
        active.lastPlayWhenReady = false
        active.snapshot()
        manager.updateProgressSession("active")
        assertFalse(manager.hasProgressSessions)
        assertTrue(manager.progressAnchorsMap().isEmpty())
    }


    private fun createTestSession(sessionId: String): NativePlaybackSession {
        return NativePlaybackSession(
            sessionId = sessionId,
            createPlayer = { _, _ -> error("Test player creation not required") },
            logWarn = { _, _, _ -> },
            elapsedRealtimeMs = { 1_000L }
        )
    }

    @Test
    fun `getOrCreate creates new session when not present and reuses existing`() {
        var createCount = 0
        val manager = NativePlaybackSessionManager { id ->
            createCount++
            createTestSession(id)
        }

        assertTrue(manager.isEmpty)
        assertEquals(0, manager.size)

        val s1 = manager.getOrCreate("session-1")
        assertEquals("session-1", s1.sessionId)
        assertEquals(1, createCount)
        assertEquals(1, manager.size)
        assertTrue(manager.isNotEmpty)

        val s1Again = manager.getOrCreate("session-1")
        assertEquals(s1, s1Again)
        assertEquals(1, createCount)
    }

    @Test
    fun `remove updates focus when focused session is removed`() {
        val manager = NativePlaybackSessionManager(::createTestSession)
        manager.getOrCreate("session-1")
        manager.getOrCreate("session-2")
        manager.getOrCreate("session-3")

        manager.focus("session-2")
        assertEquals("session-2", manager.focusedSessionId)

        val removed = manager.remove("session-2")
        assertEquals("session-2", removed?.sessionId)
        assertEquals(2, manager.size)
        // Focus should fallback to first remaining session ("session-1")
        assertEquals("session-1", manager.focusedSessionId)

        val removedFirst = manager.remove("session-1")
        assertEquals("session-1", removedFirst?.sessionId)
        assertEquals("session-3", manager.focusedSessionId)

        manager.remove("session-3")
        assertNull(manager.focusedSessionId)
        assertTrue(manager.isEmpty)
    }

    @Test
    fun `focus validates session existence before updating focus`() {
        val manager = NativePlaybackSessionManager(::createTestSession)
        manager.getOrCreate("session-1")

        assertFalse(manager.focus("non-existent"))
        assertNull(manager.focusedSessionId)

        assertTrue(manager.focus("session-1"))
        assertEquals("session-1", manager.focusedSessionId)
    }

    @Test
    fun `clear resets sessions and focus state`() {
        val manager = NativePlaybackSessionManager(::createTestSession)
        manager.getOrCreate("session-1")
        manager.getOrCreate("session-2")
        manager.focus("session-2")

        manager.clear()
        assertTrue(manager.isEmpty)
        assertEquals(0, manager.size)
        assertNull(manager.focusedSessionId)
        assertEquals(emptySet<String>(), manager.sessionIds)
    }

    @Test
    fun `mediaSessionCandidate and foregroundSessionCandidate prioritize actively playing sessions`() {
        val manager = NativePlaybackSessionManager(::createTestSession)
        val focusedPaused = manager.getOrCreate("paused")
        val playing = manager.getOrCreate("playing")
        var focusedPlayingState = false
        var focusedPlayWhenReady = false
        attachFakePlayer(focusedPaused) { method ->
            when (method) {
                "getPlaybackState" -> Player.STATE_READY
                "isPlaying" -> focusedPlayingState
                "getPlayWhenReady" -> focusedPlayWhenReady
                else -> error("Unexpected player call: $method")
            }
        }
        attachFakePlayer(playing) { method ->
            when (method) {
                "getPlaybackState" -> Player.STATE_READY
                "isPlaying", "getPlayWhenReady" -> true
                else -> error("Unexpected player call: $method")
            }
        }

        manager.focus("paused")
        assertSame(playing, manager.mediaSessionCandidate())
        assertSame(playing, manager.foregroundSessionCandidate())

        focusedPlayingState = true
        focusedPlayWhenReady = true
        assertSame(focusedPaused, manager.mediaSessionCandidate())
        assertSame(focusedPaused, manager.foregroundSessionCandidate())
    }

    private fun attachFakePlayer(
        session: NativePlaybackSession,
        handler: (String) -> Any?
    ) {
        val fakePlayer = Proxy.newProxyInstance(
            ExoPlayer::class.java.classLoader,
            arrayOf(ExoPlayer::class.java)
        ) { _, method, _ -> handler(method.name) } as ExoPlayer
        val field = NativePlaybackSession::class.java.getDeclaredField("_player")
        field.isAccessible = true
        field.set(session, fakePlayer)
    }
}
