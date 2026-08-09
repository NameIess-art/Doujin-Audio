package com.doujin.audio

import com.doujin.audio.player.notification.*

import android.app.AlarmManager
import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackIntentBoundaryTest {
    @Test
    fun `timer receiver accepts only scheduled timer actions`() {
        assertTrue(isPlaybackTimerAlarmAction(PlaybackTimerAlarmScheduler.actionTimerExpired))
        assertTrue(isPlaybackTimerAlarmAction(PlaybackTimerAlarmScheduler.actionAutoResume))
        assertFalse(isPlaybackTimerAlarmAction("external.action"))
        assertFalse(isPlaybackTimerAlarmAction(null))
    }

    @Test
    fun `timer state restore accepts only declared system actions`() {
        assertTrue(isPlaybackTimerStateRestoreAction(Intent.ACTION_BOOT_COMPLETED))
        assertTrue(isPlaybackTimerStateRestoreAction(Intent.ACTION_MY_PACKAGE_REPLACED))
        assertTrue(isPlaybackTimerStateRestoreAction(Intent.ACTION_TIME_CHANGED))
        assertTrue(isPlaybackTimerStateRestoreAction(Intent.ACTION_TIMEZONE_CHANGED))
        assertTrue(
            isPlaybackTimerStateRestoreAction(
                AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED
            )
        )
        assertFalse(isPlaybackTimerStateRestoreAction("external.action"))
        assertFalse(isPlaybackTimerStateRestoreAction(null))
    }

    @Test
    fun `notification session id requires the notification action`() {
        assertEquals(
            "session-1",
            notificationSessionIdFromIntent(
                action = MainActivity.openSessionFromNotificationAction,
                sessionId = "session-1"
            )
        )
        assertNull(notificationSessionIdFromIntent(action = Intent.ACTION_MAIN, sessionId = "session-1"))
        assertNull(
            notificationSessionIdFromIntent(
                action = MainActivity.openSessionFromNotificationAction,
                sessionId = " "
            )
        )
    }
}
