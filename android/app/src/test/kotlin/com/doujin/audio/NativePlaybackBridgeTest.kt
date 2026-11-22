package com.doujin.audio

import android.app.AlarmManager
import android.content.Context
import android.os.Looper
import com.doujin.audio.channel.ChannelErrorCodes
import com.doujin.audio.channel.NativePlaybackMethods
import com.doujin.audio.player.common.NativePlaybackBridge
import com.doujin.audio.player.common.parsePlaybackCommand
import com.doujin.audio.player.notification.PlaybackTimerAlarmScheduler
import com.doujin.audio.player.service.NativePlaybackService
import com.doujin.audio.player.session.NativePlaybackStatePersistenceCoordinator
import com.doujin.audio.player.session.NativePlaybackStateStore
import com.doujin.audio.player.session.StoredPlaybackTimerRuntimeState
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class NativePlaybackBridgeTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()

    @Before
    fun reset() {
        NativePlaybackStateStore.clearTimerRuntimeState(context)
        NativePlaybackStateStore.clearPausedSessionIds(context)
        NativePlaybackStateStore.clearTimerCandidateSessionIds(context)
    }

    @After
    fun tearDown() {
        NativePlaybackStateStore.clearTimerRuntimeState(context)
        NativePlaybackStateStore.clearPausedSessionIds(context)
        NativePlaybackStateStore.clearTimerCandidateSessionIds(context)
    }

    @Test
    fun `pending service call catches unexpected exceptions and balances command delivery`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        ReflectionHelpers.setStaticField(NativePlaybackService::class.java, "instance", service)
        val bridge = NativePlaybackBridge(context)
        try {
            fun runPendingCall(
                dispatchAsync: ((NativePlaybackService, (Map<String, Any?>) -> Unit) -> Unit)? = null,
                dispatch: (NativePlaybackService) -> Map<String, Any?> = { emptyMap() }
            ): Map<*, *> {
                var response: Any? = null
                val result = object : MethodChannel.Result {
                    override fun success(value: Any?) { response = value }
                    override fun error(code: String, message: String?, details: Any?) = error("Envelope expected")
                    override fun notImplemented() = error("Known method expected")
                }
                val ctor = Class.forName(
                    "com.doujin.audio.player.common.NativePlaybackBridge\$PendingServiceCall"
                ).declaredConstructors.single().apply { isAccessible = true }
                val pending = ctor.newInstance(
                    bridge,
                    "seek",
                    result,
                    "s1",
                    false,
                    false,
                    dispatchAsync,
                    dispatch
                ) as Runnable
                assertTrue(NativePlaybackService.hasPendingCommandDelivery())
                pending.run()
                assertFalse(NativePlaybackService.hasPendingCommandDelivery())
                return response as Map<*, *>
            }

            val syncError = runPendingCall(dispatch = { throw IllegalStateException("player crashed") })
            assertEquals(false, syncError["ok"])
            assertEquals(ChannelErrorCodes.PLAYER_ERROR, syncError["errorCode"])

            val asyncError = runPendingCall(dispatchAsync = { _, _ -> throw RuntimeException("async boom") })
            assertEquals(false, asyncError["ok"])
            assertEquals(ChannelErrorCodes.PLAYER_ERROR, asyncError["errorCode"])

            val argError = runPendingCall(dispatchAsync = { _, _ -> throw IllegalArgumentException("bad arg") })
            assertEquals(false, argError["ok"])
            assertEquals(ChannelErrorCodes.INVALID_ARGUMENT, argError["errorCode"])
        } finally {
            bridge.dispose()
            ReflectionHelpers.setStaticField(NativePlaybackService::class.java, "instance", null)
            val persistence = ReflectionHelpers.callInstanceMethod<NativePlaybackStatePersistenceCoordinator>(
                service, "getStatePersistence"
            )
            persistence.shutdown()
            assertTrue(persistence.awaitTermination())
        }
    }

    @Test
    fun `inactive removeSession clears autoResumeAtMs and cancels scheduled alarm`() {
        val resumeAtMs = System.currentTimeMillis() + 120_000L
        NativePlaybackStateStore.saveTimerRuntimeState(
            context,
            StoredPlaybackTimerRuntimeState(
                timerModeIndex = null,
                durationMs = null,
                waitingForPlayback = false,
                timerEndsAtWallClockMs = null,
                timerEndsElapsedRealtimeMs = null,
                autoResumeEnabled = true,
                autoResumeHour = 7,
                autoResumeMinute = 0,
                autoResumeAtMs = resumeAtMs,
                pausedSessionIds = listOf("solo"),
                generation = 5
            )
        )
        NativePlaybackStateStore.storePausedSessionIds(context, listOf("solo"))
        PlaybackTimerAlarmScheduler.rescheduleFromStoredState(context)

        val alarmManager = context.getSystemService(AlarmManager::class.java)
        assertEquals(1, shadowOf(alarmManager).scheduledAlarms.size)

        val command = parsePlaybackCommand(
            MethodCall(NativePlaybackMethods.REMOVE_SESSION, mapOf("sessionId" to "solo"))
        )
        val response = checkNotNull(command.dispatchInactive).invoke(context)
        assertEquals(true, response["ok"])
        assertNull(NativePlaybackStateStore.loadTimerRuntimeState(context))
        assertTrue(NativePlaybackStateStore.loadPausedSessionIds(context).isEmpty())
        assertTrue(shadowOf(alarmManager).scheduledAlarms.isEmpty())
        shadowOf(Looper.getMainLooper()).idle()
    }
}
