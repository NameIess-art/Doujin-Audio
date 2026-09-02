package com.doujin.audio

import com.doujin.audio.player.notification.*
import com.doujin.audio.player.session.StoredPlaybackTimerRuntimeState

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
    fun `timer delivery requires a matching persisted deadline`() {
        val timerState = StoredPlaybackTimerRuntimeState(
            timerModeIndex = 0,
            durationMs = 60_000L,
            waitingForPlayback = false,
            timerEndsAtWallClockMs = 1_700_000_000_000L,
            timerEndsElapsedRealtimeMs = null,
            autoResumeEnabled = false,
            autoResumeHour = 7,
            autoResumeMinute = 0,
            autoResumeAtMs = null,
            pausedSessionIds = emptyList(),
            generation = 3
        )
        assertTrue(
            hasScheduledPlaybackTimerRuntime(
                PlaybackTimerAlarmScheduler.actionTimerExpired,
                timerState
            )
        )
        assertFalse(
            hasScheduledPlaybackTimerRuntime(
                PlaybackTimerAlarmScheduler.actionTimerExpired,
                null
            )
        )
        assertFalse(
            hasScheduledPlaybackTimerRuntime(
                PlaybackTimerAlarmScheduler.actionAutoResume,
                timerState
            )
        )
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
