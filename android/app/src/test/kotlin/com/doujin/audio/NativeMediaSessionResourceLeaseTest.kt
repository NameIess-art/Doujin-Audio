package com.doujin.audio

import com.doujin.audio.player.session.NativeMediaSessionResourceLease
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeMediaSessionResourceLeaseTest {
    @Test
    fun `bootstrap creation failure releases candidate player and retains no resources`() {
        val released = mutableListOf<String>()
        val lease = NativeMediaSessionResourceLease<String, String>()

        val failure = runCatching {
            lease.installBootstrap(
                createPlayer = { "bootstrap" },
                createSession = { error("session failed") },
                releasePlayer = released::add
            )
        }.exceptionOrNull()

        assertEquals("session failed", failure?.message)
        assertEquals(listOf("bootstrap"), released)
        assertFalse(lease.hasResources)
    }

    @Test
    fun `first real player attachment releases bootstrap exactly once`() {
        val released = mutableListOf<String>()
        val lease = NativeMediaSessionResourceLease<String, String>()
        lease.installBootstrap({ "bootstrap" }, { "session:$it" }, released::add)

        lease.onPlayerAttached(released::add)
        lease.onPlayerAttached(released::add)

        assertEquals(listOf("bootstrap"), released)
        assertEquals("session:bootstrap", lease.currentSession)
    }

    @Test
    fun `failed bootstrap release during attachment is not retried`() {
        var bootstrapReleaseAttempts = 0
        val releasedSessions = mutableListOf<String>()
        val lease = NativeMediaSessionResourceLease<String, String>()
        lease.installBootstrap({ "bootstrap" }, { "session:$it" }, {})

        val failure = runCatching {
            lease.onPlayerAttached {
                bootstrapReleaseAttempts += 1
                error("bootstrap release failed")
            }
        }.exceptionOrNull()
        lease.release(releasedSessions::add) { bootstrapReleaseAttempts += 1 }

        assertEquals("bootstrap release failed", failure?.message)
        assertEquals(1, bootstrapReleaseAttempts)
        assertEquals(listOf("session:bootstrap"), releasedSessions)
    }

    @Test
    fun `release attempts every owned resource rethrows first failure and is idempotent`() {
        val released = mutableListOf<String>()
        val lease = NativeMediaSessionResourceLease<String, String>()
        lease.installBootstrap({ "bootstrap" }, { "session" }, {})

        val failure = runCatching {
            lease.release(
                releaseSession = { released += it; error("session release failed") },
                releasePlayer = released::add
            )
        }.exceptionOrNull()
        lease.release(released::add, released::add)

        assertEquals("session release failed", failure?.message)
        assertEquals(listOf("session", "bootstrap"), released)
        assertFalse(lease.hasResources)
        assertTrue(lease.currentSession == null)
    }
}
