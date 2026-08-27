package com.doujin.audio

import com.doujin.audio.player.notification.*
import com.doujin.audio.player.service.*

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
    fun `transport actions keep previous toggle next order`() {
        val actions = notificationTransportActionSpecs(
            playing = false,
            hasPrevious = true,
            hasNext = true
        )

        assertEquals(
            listOf(
                NotificationCommand.previous,
                NotificationCommand.toggle,
                NotificationCommand.next
            ),
            actions.map { it.command }
        )
        assertEquals(R.drawable.ic_notification_play, actions[1].iconResource)
        assertEquals(R.string.playback_action_play, actions[1].labelResource)
    }

    @Test
    fun `notification icon stays fixed to the warm headphones`() {
        val icon = notificationIconSpec()

        assertEquals(R.drawable.ic_launcher_foreground, icon.resourceId)
        assertEquals(0xFFFF5F5C.toInt(), icon.color)
    }

    @Test
    fun `transport toggle follows real playing state and omits unavailable skips`() {
        val actions = notificationTransportActionSpecs(
            playing = true,
            hasPrevious = false,
            hasNext = false
        )

        assertEquals(listOf(NotificationCommand.toggle), actions.map { it.command })
        assertEquals(R.drawable.ic_notification_pause, actions.single().iconResource)
        assertEquals(R.string.playback_action_pause, actions.single().labelResource)
    }

    @Test
    fun `compact actions only reference actions that were added`() {
        assertEquals(
            listOf(0),
            notificationCompactActionIndices(hasPrevious = false, hasNext = false)
        )
        assertEquals(
            listOf(0, 1),
            notificationCompactActionIndices(hasPrevious = true, hasNext = false)
        )
        assertEquals(
            listOf(0, 1),
            notificationCompactActionIndices(hasPrevious = false, hasNext = true)
        )
        assertEquals(
            listOf(0, 1, 2),
            notificationCompactActionIndices(hasPrevious = true, hasNext = true)
        )
    }

    @Test
    fun `live foreground update preserves every multi session notification`() {
        val first = UnifiedPlaybackNotificationItem(
            id = "first",
            title = "First",
            subtitle = "Album",
            artPath = "/covers/first.jpg",
            playing = false,
            hasPrevious = false,
            hasNext = true
        )
        val second = UnifiedPlaybackNotificationItem(
            id = "second",
            title = "Second",
            subtitle = null,
            artPath = "/covers/second.jpg",
            playing = true,
            hasPrevious = true,
            hasNext = false
        )

        val updated = mergeLiveMultiSessionNotificationItems(
            items = listOf(first, second),
            liveItem = first.copy(
                title = "First (Playing)",
                subtitle = null,
                artPath = null,
                playing = true
            )
        )

        assertEquals(listOf("first", "second"), updated.map { it.id })
        assertEquals("First (Playing)", updated.first().title)
        assertEquals("Album", updated.first().subtitle)
        assertEquals("/covers/first.jpg", updated.first().artPath)
        assertTrue(updated.first().playing)
        assertEquals(second, updated.last())
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
