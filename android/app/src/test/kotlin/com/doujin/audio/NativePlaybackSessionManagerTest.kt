package com.doujin.audio

import com.doujin.audio.player.session.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackSessionManagerTest {

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
    fun `ensureFallbackFocus recovers focus when null or invalid`() {
        val manager = NativePlaybackSessionManager(::createTestSession)
        assertNull(manager.ensureFallbackFocus())

        manager.getOrCreate("session-1")
        manager.getOrCreate("session-2")
        assertEquals("session-1", manager.ensureFallbackFocus())

        manager.focusedSessionId = "invalid"
        assertEquals("session-1", manager.ensureFallbackFocus())
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
}
