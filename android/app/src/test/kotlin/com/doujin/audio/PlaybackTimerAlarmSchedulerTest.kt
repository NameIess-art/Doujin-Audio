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
    fun `system alarm details open the app for countdown and automatic resume`() {
        val countdown = timerState()
        val alarmManager = context.getSystemService(AlarmManager::class.java)
        for (state in listOf(countdown, countdown.copy(
            timerEndsAtWallClockMs = null,
            timerEndsElapsedRealtimeMs = null,
            autoResumeAtMs = System.currentTimeMillis() + 60_000L
        ))) {
            NativePlaybackStateStore.saveTimerRuntimeState(context, state)
            PlaybackTimerAlarmScheduler.rescheduleFromStoredState(context)

            val alarm = shadowOf(alarmManager).scheduledAlarms.single()
            val showIntent = checkNotNull(alarmManager.nextAlarmClock?.showIntent)
            assertTrue(showIntent.isActivity)
            assertNotEquals(alarm.operation, showIntent)
            assertEquals(MainActivity::class.java.name, shadowOf(showIntent).savedIntent.component?.className)
        }
    }

    @Test
    fun `manual pause removes only that session from recovery candidates before expiry`() {
        val countdown = timerState().copy(pausedSessionIds = emptyList())
        NativePlaybackStateStore.saveTimerRuntimeState(context, countdown)
        NativePlaybackStateStore.storeTimerCandidateSessionIds(context, listOf("A", "B"))

        PlaybackTimerAlarmScheduler.onManualPlaybackStopped(context, "A")

        assertEquals(listOf("B"), NativePlaybackStateStore.loadTimerCandidateSessionIds(context))
        assertEquals(countdown, NativePlaybackStateStore.loadTimerRuntimeState(context))
        assertTrue(NativePlaybackStateStore.loadPausedSessionIds(context).isEmpty())
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
            val persistence = ReflectionHelpers.callInstanceMethod<NativePlaybackStatePersistenceCoordinator>(
                service,
                "getStatePersistence"
            )
            persistence.shutdown()
            assertTrue(persistence.awaitTermination())
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

    @Test
    fun `sync persists pausedSessionIds and manual stop clears runtime state even if paused ids were stale`() {
        val resumeAtMs = System.currentTimeMillis() + 60_000L
        PlaybackTimerAlarmScheduler.sync(
            context = context,
            timerModeIndex = null,
            durationMs = null,
            waitingForPlayback = false,
            timerEndsAtWallClockMs = null,
            autoResumeEnabled = true,
            autoResumeHour = 7,
            autoResumeMinute = 0,
            autoResumeAtMs = resumeAtMs,
            pausedSessionIds = listOf("A"),
            generation = 11,
            timerCandidateSessionIds = emptyList(),
            stopAfterCurrentTrack = false
        )

        assertEquals(listOf("A"), NativePlaybackStateStore.loadPausedSessionIds(context))
        val alarmManager = context.getSystemService(AlarmManager::class.java)
        assertEquals(1, shadowOf(alarmManager).scheduledAlarms.size)

        // Simulate stale/empty pausedSessionIds key while runtime state still references session A.
        NativePlaybackStateStore.clearPausedSessionIds(context)
        PlaybackTimerAlarmScheduler.onManualPlaybackStopped(context, "A")

        assertNull(NativePlaybackStateStore.loadTimerRuntimeState(context))
        assertTrue(NativePlaybackStateStore.loadPausedSessionIds(context).isEmpty())
        assertTrue(shadowOf(alarmManager).scheduledAlarms.isEmpty())
    }

    @Test
    fun `timer expiry with stopAfterCurrentTrack recovers persisted candidates after service restart`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val state = timerState().copy(
            pausedSessionIds = emptyList(),
            stopAfterCurrentTrack = true
        )
        NativePlaybackStateStore.saveTimerRuntimeState(context, state)
        NativePlaybackStateStore.storeTimerCandidateSessionIds(context, listOf("A"))
        val latch = java.util.concurrent.CountDownLatch(1)
        var outcome: String? = null
        try {
            val complete: (String) -> Unit = { result ->
                outcome = result
                latch.countDown()
            }
            ReflectionHelpers.callInstanceMethod<Unit>(
                PlaybackTimerAlarmScheduler,
                "executeTimerExpired",
                ClassParameter.from(Context::class.java, context),
                ClassParameter.from(NativePlaybackService::class.java, service),
                ClassParameter.from(StoredPlaybackTimerRuntimeState::class.java, state),
                ClassParameter.from(Function1::class.java, complete)
            )
            // Wait for background candidate read to post to main looper, then idle main looper.
            val deadline = System.currentTimeMillis() + 5_000L
            while (latch.count > 0 && System.currentTimeMillis() < deadline) {
                shadowOf(android.os.Looper.getMainLooper()).idle()
                Thread.sleep(10)
            }
            assertEquals(PlaybackTimerAlarmScheduler.resultExecuted, outcome)
            val updated = checkNotNull(NativePlaybackStateStore.loadTimerRuntimeState(context))
            assertEquals(listOf("A"), updated.pausedSessionIds)
            assertNotNull(updated.autoResumeAtMs)
            assertFalse(updated.stopAfterCurrentTrack)
            assertEquals(listOf("A"), NativePlaybackStateStore.loadPausedSessionIds(context))
        } finally {
            val persistence = ReflectionHelpers.callInstanceMethod<NativePlaybackStatePersistenceCoordinator>(
                service,
                "getStatePersistence"
            )
            persistence.shutdown()
            assertTrue(persistence.awaitTermination())
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
