package com.doujin.audio

import com.doujin.audio.player.notification.*
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

    @Test
    fun `idle restore stops only for current start without sessions or playback`() {
        assertEquals(
            IdlePlaybackServiceStopAction.STOP,
            decideIdlePlaybackServiceStopAfterRestore(
                hasSessions = false,
                hasPlaybackToKeepAlive = false,
                restoreGeneration = 4,
                currentRestoreGeneration = 4,
                latestStartId = 12,
                hasPendingCommandDelivery = false
            ).action
        )
        assertEquals(
            IdlePlaybackServiceStopAction.SKIP,
            decideIdlePlaybackServiceStopAfterRestore(
                hasSessions = true,
                hasPlaybackToKeepAlive = false,
                restoreGeneration = 4,
                currentRestoreGeneration = 4,
                latestStartId = 12,
                hasPendingCommandDelivery = false
            ).action
        )
        assertEquals(
            IdlePlaybackServiceStopAction.SKIP,
            decideIdlePlaybackServiceStopAfterRestore(
                hasSessions = false,
                hasPlaybackToKeepAlive = true,
                restoreGeneration = 4,
                currentRestoreGeneration = 4,
                latestStartId = 12,
                hasPendingCommandDelivery = false
            ).action
        )
    }

    @Test
    fun `pending command delivery defers otherwise eligible idle exit`() {
        assertEquals(
            IdlePlaybackServiceStopAction.DEFER,
            decideIdlePlaybackServiceStopAfterRestore(
                hasSessions = false,
                hasPlaybackToKeepAlive = false,
                restoreGeneration = 4,
                currentRestoreGeneration = 4,
                latestStartId = 13,
                hasPendingCommandDelivery = true
            ).action
        )
    }

    @Test
    fun `settled concurrent cold starts stop with the latest start id`() {
        val decision = decideIdlePlaybackServiceStopAfterRestore(
            hasSessions = false,
            hasPlaybackToKeepAlive = false,
            restoreGeneration = 4,
            currentRestoreGeneration = 4,
            latestStartId = 13,
            hasPendingCommandDelivery = false
        )

        assertEquals(IdlePlaybackServiceStopAction.STOP, decision.action)
        assertEquals(13, decision.startId)
    }

    @Test
    fun `command delivery guard remains active until every delivery settles`() {
        assertFalse(NativePlaybackService.hasPendingCommandDelivery())
        try {
            NativePlaybackService.beginCommandDelivery()
            NativePlaybackService.beginCommandDelivery()
            NativePlaybackService.endCommandDelivery()

            assertTrue(NativePlaybackService.hasPendingCommandDelivery())
        } finally {
            NativePlaybackService.endCommandDelivery()
        }
        assertFalse(NativePlaybackService.hasPendingCommandDelivery())
    }

    @Test
    fun `controller listeners are notified passively without starting service`() {
        var callbacks = 0
        NativePlaybackService.addControllerListener("test-listener") {
            callbacks += 1
        }
        try {
            NativePlaybackService.publishController(null)
            assertEquals(1, callbacks)
            assertEquals(null, NativePlaybackService.controller())
        } finally {
            NativePlaybackService.removeControllerListener("test-listener")
        }
    }

    @Test
    fun `notification delivery times out within broadcast budget and ignores late service`() {
        var completions = 0
        var executedActions = 0
        val completion = PlaybackControlDeliveryCompletion { completions += 1 }

        assertTrue(completion.finish())
        assertFalse(completion.finish { executedActions += 1 })
        assertEquals(8_000L, PLAYBACK_CONTROL_DELIVERY_TIMEOUT_MS)
        assertEquals(1, completions)
        assertEquals(0, executedActions)
    }

    @Test
    fun `stopping service instance is not exposed as an available controller`() {
        assertTrue(
            isPlaybackServiceControllerAvailable(
                instancePresent = true,
                stoppingForIdleExit = false
            )
        )
        assertFalse(
            isPlaybackServiceControllerAvailable(
                instancePresent = true,
                stoppingForIdleExit = true
            )
        )
    }

    private fun assertRejected(decision: NativePlaybackStartDecision) {
        assertEquals(NativePlaybackStartSource.REJECTED, decision.source)
        assertFalse(decision.accepted)
        assertFalse(decision.shouldAttemptRestore)
        assertFalse(decision.requireForegroundBootstrap)
    }
}
