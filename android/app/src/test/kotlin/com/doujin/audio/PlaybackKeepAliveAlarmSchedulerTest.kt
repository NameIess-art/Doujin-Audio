package com.doujin.audio

import android.app.AlarmManager
import android.content.Context
import com.doujin.audio.player.notification.PlaybackKeepAliveAlarmScheduler
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowAlarmManager

class PlaybackKeepAliveAlarmSchedulerTest {
    @Test
    fun `unarmed sentinel is never throttled`() {
        assertFalse(
            PlaybackKeepAliveAlarmScheduler.shouldSkipRearm(
                nowMs = 1_000L,
                lastArmedMs = Long.MIN_VALUE,
            )
        )
    }

    @Test
    fun `recent alarm is throttled`() {
        assertTrue(
            PlaybackKeepAliveAlarmScheduler.shouldSkipRearm(
                nowMs = 61_000L,
                lastArmedMs = 2_000L,
            )
        )
    }

    @Test
    fun `alarm outside throttle window can rearm`() {
        assertFalse(
            PlaybackKeepAliveAlarmScheduler.shouldSkipRearm(
                nowMs = 62_001L,
                lastArmedMs = 2_000L,
            )
        )
    }

    @Test
    fun `active alarm throttle window allows faster rearm`() {
        assertFalse(
            PlaybackKeepAliveAlarmScheduler.shouldSkipRearm(
                nowMs = 32_000L,
                lastArmedMs = 1_000L,
                throttleMs = PlaybackKeepAliveAlarmScheduler.activeRearmThrottleMs
            )
        )
        assertTrue(
            PlaybackKeepAliveAlarmScheduler.shouldSkipRearm(
                nowMs = 26_000L,
                lastArmedMs = 1_000L,
                throttleMs = PlaybackKeepAliveAlarmScheduler.activeRearmThrottleMs
            )
        )
    }

    @Test
    fun `active interval is shorter than idle backstop interval`() {
        assertTrue(
            PlaybackKeepAliveAlarmScheduler.activeIntervalMs <
                PlaybackKeepAliveAlarmScheduler.intervalMs
        )
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class PlaybackKeepAliveAlarmDeliveryTest {
    @Test
    fun `inexact keep alive leaves allow while idle delivery to sleep timer`() {
        val context = RuntimeEnvironment.getApplication()
        val alarms = shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
        ShadowAlarmManager.setCanScheduleExactAlarms(false)

        try {
            PlaybackKeepAliveAlarmScheduler.ensureScheduled(context)

            assertFalse(alarms.scheduledAlarms.single().isAllowWhileIdle)
        } finally {
            PlaybackKeepAliveAlarmScheduler.cancel(context)
        }
    }

    @Test
    fun `exact keep alive remains eligible for idle delivery`() {
        val context = RuntimeEnvironment.getApplication()
        val alarms = shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
        ShadowAlarmManager.setCanScheduleExactAlarms(true)

        try {
            PlaybackKeepAliveAlarmScheduler.ensureScheduled(context)

            assertTrue(alarms.scheduledAlarms.single().isAllowWhileIdle)
        } finally {
            PlaybackKeepAliveAlarmScheduler.cancel(context)
        }
    }
}
