package com.doujin.audio

import android.app.AlarmManager
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import com.doujin.audio.player.notification.PlaybackTimerAlarmScheduler
import com.doujin.audio.player.service.NativePlaybackService
import com.doujin.audio.player.session.NativePlaybackStatePersistenceCoordinator
import com.doujin.audio.player.session.NativePlaybackStateStore
import com.doujin.audio.player.session.NativePlaybackTimerExecution
import com.doujin.audio.player.session.StoredPlaybackTimerRuntimeState
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers
import org.robolectric.util.ReflectionHelpers.ClassParameter

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class PlaybackTimerAlarmSchedulerTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()

    @Before
    fun reset() {
        NativePlaybackStateStore.clearTimerRuntimeState(context)
        NativePlaybackStateStore.clearPausedSessionIds(context)
        NativePlaybackStateStore.clearTimerCandidateSessionIds(context)
    }

    @Test
    fun `buffering recovery preserves track-end targets until automatic resume is scheduled`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val state = timerState().copy(timerEndsAtWallClockMs = null, timerEndsElapsedRealtimeMs = null)
        NativePlaybackStateStore.saveTimerRuntimeState(context, state)
        NativePlaybackStateStore.storePausedSessionIds(context, listOf("A"))
        NativePlaybackStateStore.storeTimerCandidateSessionIds(context, listOf("A"))
        val execution = ReflectionHelpers.callInstanceMethod<NativePlaybackTimerExecution>(service, "getTimerExecution")
        execution.arm(listOf("A"), state.generation)
        try {
            ReflectionHelpers.callInstanceMethod<Unit>(service, "handleIsPlayingChanged",
                ClassParameter.from(String::class.java, "A"),
                ClassParameter.from(Boolean::class.javaPrimitiveType!!, true))
            assertEquals(listOf("A"), NativePlaybackStateStore.loadPausedSessionIds(context))
            assertEquals(listOf("A"), NativePlaybackStateStore.loadTimerRuntimeState(context)!!.pausedSessionIds)

            execution.onTrackEnded("A", state.generation)
            assertNotNull(NativePlaybackStateStore.loadTimerRuntimeState(context)!!.autoResumeAtMs)
            PlaybackTimerAlarmScheduler.onManualPlaybackStopped(context, "A")
            assertNull(NativePlaybackStateStore.loadTimerRuntimeState(context))
            assertTrue(NativePlaybackStateStore.loadPausedSessionIds(context).isEmpty())
        } finally {
            ReflectionHelpers.callInstanceMethod<NativePlaybackStatePersistenceCoordinator>(service, "getStatePersistence").shutdown()
        }
    }

    @Test
    fun `boot persists the new monotonic deadline for later system broadcasts`() {
        for (bootAction in listOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED)) {
            val state = timerState()
            NativePlaybackStateStore.saveTimerRuntimeState(context, state)
            val wallBeforeBoot = System.currentTimeMillis()
            val elapsedBeforeBoot = SystemClock.elapsedRealtime()
            PlaybackTimerAlarmScheduler.rescheduleFromStoredState(context, bootAction)
            val deadline = NativePlaybackStateStore.loadTimerRuntimeState(context)!!.timerEndsElapsedRealtimeMs!!
            assertNotEquals(state.timerEndsElapsedRealtimeMs, deadline)
            assertTrue(deadline in
                (elapsedBeforeBoot + state.timerEndsAtWallClockMs!! - System.currentTimeMillis())..
                (SystemClock.elapsedRealtime() + state.timerEndsAtWallClockMs - wallBeforeBoot))
            for (event in listOf(Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED,
                    AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED)) {
                val wallBeforeEvent = System.currentTimeMillis()
                val elapsedBeforeEvent = SystemClock.elapsedRealtime()
                PlaybackTimerAlarmScheduler.rescheduleFromStoredState(context, event)
                assertEquals(deadline, NativePlaybackStateStore.loadTimerRuntimeState(context)!!.timerEndsElapsedRealtimeMs)
                val alarm = shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).scheduledAlarms.single()
                assertTrue(alarm.triggerAtTime in
                    (wallBeforeEvent + deadline - SystemClock.elapsedRealtime())..
                    (System.currentTimeMillis() + deadline - elapsedBeforeEvent))
            }
        }
    }

    private fun timerState() = StoredPlaybackTimerRuntimeState(
        timerModeIndex = 0, durationMs = 60_000L, waitingForPlayback = false,
        timerEndsAtWallClockMs = System.currentTimeMillis() + 60_000L,
        timerEndsElapsedRealtimeMs = SystemClock.elapsedRealtime() + 9_000_000L,
        autoResumeEnabled = true, autoResumeHour = 7, autoResumeMinute = 0,
        autoResumeAtMs = null, pausedSessionIds = listOf("A"), generation = 7
    )
}
