package com.doujin.audio

import com.doujin.audio.player.service.*

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackServiceStartPolicyTest {
    private val expectedToken = "internal-token"

    @Test
    fun `matching internal start request is accepted`() {
        val decision = evaluateNativePlaybackStart(
            intentPresent = true,
            action = nativePlaybackStartAction,
            presentedToken = expectedToken,
            expectedToken = expectedToken,
            bootstrapExtraPresent = true,
            bootstrapExtra = true
        )

        assertEquals(NativePlaybackStartSource.INTERNAL, decision.source)
        assertTrue(decision.accepted)
        assertTrue(decision.shouldAttemptRestore)
        assertTrue(decision.requireForegroundBootstrap)
    }

    @Test
    fun `null sticky restart is accepted without bootstrap`() {
        val decision = evaluateNativePlaybackStart(
            intentPresent = false,
            action = null,
            presentedToken = null,
            expectedToken = expectedToken,
            bootstrapExtraPresent = false,
            bootstrapExtra = null
        )

        assertEquals(NativePlaybackStartSource.STICKY_RESTART, decision.source)
        assertTrue(decision.accepted)
        assertFalse(decision.requireForegroundBootstrap)
    }

    @Test
    fun `unknown action and forged token are rejected before restore`() {
        val unknownAction = evaluateNativePlaybackStart(
            intentPresent = true,
            action = "external.action",
            presentedToken = expectedToken,
            expectedToken = expectedToken,
            bootstrapExtraPresent = false,
            bootstrapExtra = null
        )
        val forgedToken = evaluateNativePlaybackStart(
            intentPresent = true,
            action = nativePlaybackStartAction,
            presentedToken = "forged",
            expectedToken = expectedToken,
            bootstrapExtraPresent = false,
            bootstrapExtra = null
        )
        val missingAction = evaluateNativePlaybackStart(
            intentPresent = true,
            action = null,
            presentedToken = expectedToken,
            expectedToken = expectedToken,
            bootstrapExtraPresent = false,
            bootstrapExtra = null
        )

        assertRejected(unknownAction)
        assertRejected(forgedToken)
        assertRejected(missingAction)
    }

    @Test
    fun `missing optional bootstrap extra is false and malformed value is rejected`() {
        val missing = evaluateNativePlaybackStart(
            intentPresent = true,
            action = nativePlaybackStartAction,
            presentedToken = expectedToken,
            expectedToken = expectedToken,
            bootstrapExtraPresent = false,
            bootstrapExtra = null
        )
        val malformed = evaluateNativePlaybackStart(
            intentPresent = true,
            action = nativePlaybackStartAction,
            presentedToken = expectedToken,
            expectedToken = expectedToken,
            bootstrapExtraPresent = true,
            bootstrapExtra = "true"
        )

        assertTrue(missing.accepted)
        assertFalse(missing.requireForegroundBootstrap)
        assertRejected(malformed)
    }

    private fun assertRejected(decision: NativePlaybackStartDecision) {
        assertEquals(NativePlaybackStartSource.REJECTED, decision.source)
        assertFalse(decision.accepted)
        assertFalse(decision.shouldAttemptRestore)
        assertFalse(decision.requireForegroundBootstrap)
    }
}
