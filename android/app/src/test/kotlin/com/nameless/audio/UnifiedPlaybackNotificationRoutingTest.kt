package com.nameless.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UnifiedPlaybackNotificationRoutingTest {
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
