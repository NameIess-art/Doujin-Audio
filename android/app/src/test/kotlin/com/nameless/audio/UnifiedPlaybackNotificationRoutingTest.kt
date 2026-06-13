package com.nameless.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UnifiedPlaybackNotificationRoutingTest {
    @Test
    fun `only playback commands are routed to the playback service`() {
        assertTrue(NotificationCommand.isPlaybackControl(NotificationCommand.toggle.actionName))
        assertTrue(NotificationCommand.isPlaybackControl(NotificationCommand.previous.actionName))
        assertTrue(NotificationCommand.isPlaybackControl(NotificationCommand.next.actionName))
        assertFalse(NotificationCommand.isPlaybackControl(NotificationCommand.dismissAll.actionName))
        assertFalse(NotificationCommand.isPlaybackControl(NotificationCommand.restore.actionName))
    }

    @Test
    fun `foreground notification resolves a persisted active session after service restart`() {
        val sessionId = resolveNotificationSessionId(
            requestedSessionId = "",
            focusedSessionId = null,
            activeSessionIds = emptyList(),
            existingSessionIds = emptyList(),
            storedActiveSessionIds = listOf("playing"),
            storedSessionIds = listOf("paused", "playing")
        )

        assertEquals("playing", sessionId)
    }

    @Test
    fun `session notification keeps its explicit session id`() {
        val sessionId = resolveNotificationSessionId(
            requestedSessionId = "requested",
            focusedSessionId = "focused",
            activeSessionIds = listOf("playing"),
            existingSessionIds = listOf("existing"),
            storedActiveSessionIds = emptyList(),
            storedSessionIds = emptyList()
        )

        assertEquals("requested", sessionId)
    }

    @Test
    fun `foreground services share the unified summary notification id`() {
        assertEquals(
            UnifiedPlaybackNotificationController.summaryNotificationId,
            UnifiedPlaybackNotificationController.foregroundServiceNotificationId
        )
    }

    @Test
    fun `foreground notification removal is ignored while unified notifications are active`() {
        UnifiedPlaybackNotificationController.clearForTest()
        assertTrue(
            UnifiedPlaybackNotificationController.shouldRemoveForegroundNotification(
                removeNotification = true
            )
        )

        UnifiedPlaybackNotificationController.markActiveForTest(
            UnifiedPlaybackNotificationController.summaryNotificationId
        )
        assertFalse(
            UnifiedPlaybackNotificationController.shouldRemoveForegroundNotification(
                removeNotification = true
            )
        )
        assertFalse(
            UnifiedPlaybackNotificationController.shouldRemoveForegroundNotification(
                removeNotification = false
            )
        )
        UnifiedPlaybackNotificationController.clearForTest()
    }
}
