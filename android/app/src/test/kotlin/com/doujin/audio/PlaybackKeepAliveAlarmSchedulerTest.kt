package com.doujin.audio

import android.app.AlarmManager
import android.content.Context
import android.os.SystemClock
import com.doujin.audio.player.notification.PlaybackKeepAliveAlarmScheduler
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowAlarmManager
import org.robolectric.shadows.ShadowSystemClock
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class PlaybackKeepAliveAlarmDeliveryTest {
    @Test
    fun `repeated playback updates preserve the pending future heartbeat deadline`() {
        val context = RuntimeEnvironment.getApplication()
        val alarms = shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
        ShadowAlarmManager.setCanScheduleExactAlarms(true)

        try {
            PlaybackKeepAliveAlarmScheduler.ensureScheduled(context)
            val firstDeadline = alarms.scheduledAlarms.single().triggerAtMs

            repeat(3) {
                ShadowSystemClock.advanceBy(Duration.ofMinutes(1))
                PlaybackKeepAliveAlarmScheduler.ensureScheduled(context)
                assertEquals(firstDeadline, alarms.scheduledAlarms.single().triggerAtMs)
            }
        } finally {
            PlaybackKeepAliveAlarmScheduler.cancel(context)
        }
    }

    @Test
    fun `overdue missed alarm deadline does not block future scheduling`() {
        val context = RuntimeEnvironment.getApplication()
        val alarms = shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
        ShadowAlarmManager.setCanScheduleExactAlarms(true)

        try {
            PlaybackKeepAliveAlarmScheduler.ensureScheduled(context)
            val firstDeadline = alarms.scheduledAlarms.single().triggerAtMs

            // Simulate the system missing/delaying delivery past the deadline.
            ShadowSystemClock.advanceBy(Duration.ofMinutes(5))
            val now = SystemClock.elapsedRealtime()
            assertTrue(now > firstDeadline)

            PlaybackKeepAliveAlarmScheduler.ensureScheduled(context)
            assertEquals(
                now + PlaybackKeepAliveAlarmScheduler.activeIntervalMs,
                alarms.scheduledAlarms.single().triggerAtMs
            )
        } finally {
            PlaybackKeepAliveAlarmScheduler.cancel(context)
        }
    }

    @Test
    fun `delivered heartbeats can rearm across twelve hours of playback`() {
        val context = RuntimeEnvironment.getApplication()
        val alarms = shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
        ShadowAlarmManager.setCanScheduleExactAlarms(true)
        val interval = PlaybackKeepAliveAlarmScheduler.activeIntervalMs

        try {
            PlaybackKeepAliveAlarmScheduler.ensureScheduled(context)
            val end = SystemClock.elapsedRealtime() + Duration.ofHours(12).toMillis()
            while (SystemClock.elapsedRealtime() < end) {
                val deadline = alarms.scheduledAlarms.single().triggerAtMs
                ShadowSystemClock.advanceBy(Duration.ofMillis(deadline - SystemClock.elapsedRealtime()))
                assertEquals(deadline, alarms.scheduledAlarms.firstOrNull()?.triggerAtMs)
                PlaybackKeepAliveAlarmScheduler.onAlarmDelivered()
                PlaybackKeepAliveAlarmScheduler.ensureScheduled(context)
                assertEquals(deadline + interval, alarms.scheduledAlarms.single().triggerAtMs)
            }
        } finally {
            PlaybackKeepAliveAlarmScheduler.cancel(context)
        }
        assertTrue(alarms.scheduledAlarms.isEmpty())
    }

    @Test
    fun `active playback can advance an idle heartbeat deadline and rearm after delivery`() {
        val context = RuntimeEnvironment.getApplication()
        val alarms = shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
        ShadowAlarmManager.setCanScheduleExactAlarms(true)

        try {
            PlaybackKeepAliveAlarmScheduler.ensureScheduled(context, activePlayback = false)
            val idleDeadline = alarms.scheduledAlarms.single().triggerAtMs
            PlaybackKeepAliveAlarmScheduler.ensureScheduled(context)
            val activeDeadline = alarms.scheduledAlarms.single().triggerAtMs
            assertTrue(activeDeadline < idleDeadline)

            PlaybackKeepAliveAlarmScheduler.onAlarmDelivered()
            ShadowSystemClock.advanceBy(Duration.ofMinutes(1))
            PlaybackKeepAliveAlarmScheduler.ensureScheduled(context)
            assertEquals(
                SystemClock.elapsedRealtime() + PlaybackKeepAliveAlarmScheduler.activeIntervalMs,
                alarms.scheduledAlarms.single().triggerAtMs
            )
        } finally {
            PlaybackKeepAliveAlarmScheduler.cancel(context)
        }
    }

    @Test
    fun `inexact keep alive still uses allow while idle delivery under Doze`() {
        val context = RuntimeEnvironment.getApplication()
        val alarms = shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
        ShadowAlarmManager.setCanScheduleExactAlarms(false)

        try {
            val before = SystemClock.elapsedRealtime()
            PlaybackKeepAliveAlarmScheduler.ensureScheduled(context)

            val scheduled = alarms.scheduledAlarms.single()
            assertTrue(scheduled.isAllowWhileIdle)
            assertEquals(before + PlaybackKeepAliveAlarmScheduler.intervalMs, scheduled.triggerAtMs)
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
