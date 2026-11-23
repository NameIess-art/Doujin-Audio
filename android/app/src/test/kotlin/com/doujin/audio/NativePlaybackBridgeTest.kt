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
import com.doujin.audio.player.session.NativeMediaItemDescriptor
import com.doujin.audio.player.session.NativePlaybackSessionManager
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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

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

    @Test
    fun `inactive clearAll and live clearAll both cancel scheduled timer alarms`() {
        val alarmManager = context.getSystemService(AlarmManager::class.java)

        fun seedTimerAlarm() {
            val endsAt = System.currentTimeMillis() + 120_000L
            NativePlaybackStateStore.saveTimerRuntimeState(
                context,
                StoredPlaybackTimerRuntimeState(
                    timerModeIndex = 0,
                    durationMs = 120_000L,
                    waitingForPlayback = false,
                    timerEndsAtWallClockMs = endsAt,
                    timerEndsElapsedRealtimeMs = null,
                    autoResumeEnabled = false,
                    autoResumeHour = 7,
                    autoResumeMinute = 0,
                    autoResumeAtMs = null,
                    pausedSessionIds = emptyList(),
                    generation = 7
                )
            )
            PlaybackTimerAlarmScheduler.rescheduleFromStoredState(context)
            assertEquals(1, shadowOf(alarmManager).scheduledAlarms.size)
        }

        // 1) Inactive bridge clearAll
        seedTimerAlarm()
        val command = parsePlaybackCommand(MethodCall(NativePlaybackMethods.CLEAR_ALL, null))
        val inactiveResponse = checkNotNull(command.dispatchInactive).invoke(context)
        assertEquals(true, inactiveResponse["ok"])
        assertTrue(shadowOf(alarmManager).scheduledAlarms.isEmpty())

        // 2) Live service clearAll
        seedTimerAlarm()
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        try {
            val liveResponse = service.clearAll()
            assertEquals(true, liveResponse["ok"])
            assertTrue(PlaybackTimerAlarmScheduler.awaitPendingForTest())
            assertTrue(shadowOf(alarmManager).scheduledAlarms.isEmpty())
        } finally {
            val persistence = ReflectionHelpers.callInstanceMethod<NativePlaybackStatePersistenceCoordinator>(
                service, "getStatePersistence"
            )
            persistence.shutdown()
            assertTrue(persistence.awaitTermination())
        }
    }

    @Test
    fun `inactive dispatch does not double execute when service attaches before main runs`() {
        val offMainRuns = mutableListOf<Runnable>()
        val bridge = NativePlaybackBridge(context, Executor { offMainRuns += it })
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val responses = mutableListOf<Any?>()
        val result = object : MethodChannel.Result {
            override fun success(value: Any?) { responses += value }
            override fun error(code: String, message: String?, details: Any?) = error("Envelope expected")
            override fun notImplemented() = error("Known method expected")
        }
        try {
            // Service is NOT attached when onMethodCall starts on background queue.
            ReflectionHelpers.setStaticField(NativePlaybackService::class.java, "instance", null)
            bridge.onMethodCall(MethodCall(NativePlaybackMethods.SNAPSHOT, null), result)

            // Service becomes available BEFORE mainHandler runs the queued bridge decision.
            ReflectionHelpers.setStaticField(NativePlaybackService::class.java, "instance", service)
            shadowOf(Looper.getMainLooper()).idle()

            // Must route exclusively to live service (zero off-main inactive executions, single reply).
            assertTrue(offMainRuns.isEmpty())
            assertEquals(1, responses.size)
            assertEquals(true, (responses.single() as Map<*, *>)["ok"])
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
    fun `deferred prepare routes to live service when active or cold store`() {
        val offMainRuns = mutableListOf<Runnable>()
        val bridge = NativePlaybackBridge(context, Executor { offMainRuns += it })
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        ReflectionHelpers.setStaticField(NativePlaybackService::class.java, "instance", service)
        val sessions = ReflectionHelpers.callInstanceMethod<NativePlaybackSessionManager>(
            service, "getSessionManager"
        )
        val existing = sessions.getOrCreate("active-session")
        val initialTrack = NativeMediaItemDescriptor("/old.mp3", "file:///old.mp3", "Old", null, null)
        existing.configure(
            descriptor = initialTrack,
            queue = listOf(initialTrack),
            queueStartIndex = 0,
            startPositionMs = 1_000L,
            volume = 1f,
            speed = 1f,
            repeatOne = false,
            repeatAll = false,
            shuffleModeEnabled = false,
            autoPlay = false,
            deferPlayerCreation = true
        )

        fun preparePayload(sessionId: String, title: String) = mapOf(
            "sessionId" to sessionId,
            "uri" to "file:///new.mp3",
            "path" to "/new.mp3",
            "title" to title,
            "startPositionMs" to 5_000L,
            "volume" to 1.0,
            "speed" to 1.0,
            "audioEffects" to mapOf(
                "skipSilenceEnabled" to false,
                "noiseReductionEnabled" to false,
                "volumeNormalizationEnabled" to false,
                "eqEnabled" to false,
                "eqPresetId" to null,
                "eqBandLevels" to emptyList<Map<String, Number>>(),
                "channelSwapEnabled" to false,
                "panning" to 0.0,
                "frontBack" to 0.0
            ),
            "repeatOne" to false,
            "repeatAll" to false,
            "shuffle" to false,
            "autoPlay" to false,
            "deferPlayerCreation" to true,
            "queueStartIndex" to 0,
            "queue" to listOf(mapOf("path" to "/new.mp3", "uri" to "file:///new.mp3", "title" to title))
        )

        try {
            // 1) Same sessionId held by live service -> routes to live service, NOT cold-only offMainRuns.
            var liveResp: Any? = null
            val liveLatch = CountDownLatch(1)
            bridge.onMethodCall(
                MethodCall(NativePlaybackMethods.PREPARE_SESSION, preparePayload("active-session", "Updated Live")),
                object : MethodChannel.Result {
                    override fun success(value: Any?) { liveResp = value; liveLatch.countDown() }
                    override fun error(code: String, message: String?, details: Any?) = error("Envelope expected")
                    override fun notImplemented() = error("Known method expected")
                }
            )
            shadowOf(Looper.getMainLooper()).idle()
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
            while (liveLatch.count > 0 && System.nanoTime() < deadline) {
                shadowOf(Looper.getMainLooper()).idle()
                Thread.sleep(10)
            }
            assertTrue(offMainRuns.isEmpty())
            val liveEnvelope = liveResp as Map<*, *>
            assertEquals(true, liveEnvelope["ok"])
            val liveSnapshot = liveEnvelope["value"] as Map<*, *>
            assertEquals("active-session", liveSnapshot["sessionId"])
            assertEquals(5_000L, (liveSnapshot["positionMs"] as Number).toLong())
            assertEquals("/new.mp3", liveSnapshot["path"])

            // 2) Different sessionId NOT held by live service -> uses cold storage path without touching live service.
            var coldResp: Any? = null
            bridge.onMethodCall(
                MethodCall(NativePlaybackMethods.PREPARE_SESSION, preparePayload("cold-session", "Cold Only")),
                object : MethodChannel.Result {
                    override fun success(value: Any?) { coldResp = value }
                    override fun error(code: String, message: String?, details: Any?) = error("Envelope expected")
                    override fun notImplemented() = error("Known method expected")
                }
            )
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals(1, offMainRuns.size)
            offMainRuns.removeAt(0).run()
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals(true, (coldResp as? Map<*, *>)?.get("ok"))
            assertNull(sessions.get("cold-session"))
            assertEquals(
                "Cold Only",
                NativePlaybackStateStore.loadSessions(context, setOf("cold-session")).single().title
            )
        } finally {
            bridge.dispose()
            ReflectionHelpers.setStaticField(NativePlaybackService::class.java, "instance", null)
            sessions.allSessions.forEach { it.release() }
            NativePlaybackStateStore.clearSessions(context)
            val persistence = ReflectionHelpers.callInstanceMethod<NativePlaybackStatePersistenceCoordinator>(
                service, "getStatePersistence"
            )
            persistence.shutdown()
            assertTrue(persistence.awaitTermination())
        }
    }

    @Test
    fun `controller change from background thread marshals safely onto main thread`() {
        val bridge = NativePlaybackBridge(context, Executor { it.run() })
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        try {
            val done = CountDownLatch(1)
            var failure: Throwable? = null
            thread {
                try {
                    ReflectionHelpers.callInstanceMethod<Unit>(
                        bridge,
                        "handleControllerChanged",
                        ReflectionHelpers.ClassParameter.from(NativePlaybackService::class.java, service)
                    )
                } catch (t: Throwable) {
                    failure = t
                } finally {
                    done.countDown()
                }
            }
            assertTrue(done.await(2, TimeUnit.SECONDS))
            assertNull(failure)
            shadowOf(Looper.getMainLooper()).idle()

            ReflectionHelpers.setField(bridge, "commandService", service)
            ReflectionHelpers.setField(bridge, "attachedService", service)
            ReflectionHelpers.callInstanceMethod<Unit>(
                bridge,
                "handleControllerChangedOnMain",
                ReflectionHelpers.ClassParameter.from(NativePlaybackService::class.java, null)
            )
            assertNull(ReflectionHelpers.getField<Any?>(bridge, "commandService"))
            assertNull(ReflectionHelpers.getField<Any?>(bridge, "attachedService"))
        } finally {
            bridge.dispose()
            val persistence = ReflectionHelpers.callInstanceMethod<NativePlaybackStatePersistenceCoordinator>(
                service, "getStatePersistence"
            )
            persistence.shutdown()
            assertTrue(persistence.awaitTermination())
        }
    }

    @Test
    fun `reuseExistingQueue without a live service fails with queue_resync_required without starting service`() {
        val command = parsePlaybackCommand(
            MethodCall(
                NativePlaybackMethods.PREPARE_SESSION,
                mapOf(
                    "sessionId" to "s1",
                    "uri" to "file:///track2.mp3",
                    "path" to "/track2.mp3",
                    "title" to "Track 2",
                    "startPositionMs" to 0L,
                    "volume" to 1.0,
                    "speed" to 1.0,
                    "audioEffects" to mapOf(
                        "skipSilenceEnabled" to false,
                        "noiseReductionEnabled" to false,
                        "volumeNormalizationEnabled" to false,
                        "eqEnabled" to false,
                        "eqPresetId" to null,
                        "eqBandLevels" to emptyList<Map<String, Number>>(),
                        "channelSwapEnabled" to false,
                        "panning" to 0.0,
                        "frontBack" to 0.0
                    ),
                    "repeatOne" to false,
                    "repeatAll" to false,
                    "shuffle" to false,
                    "autoPlay" to true,
                    "deferPlayerCreation" to false,
                    "queueStartIndex" to 3,
                    "reuseExistingQueue" to true
                )
            )
        )
        assertFalse(command.canStartService)
        assertNull(command.dispatchAsync)
        val response = checkNotNull(command.dispatchInactive).invoke(context)
        assertEquals(false, response["ok"])
        assertEquals(ChannelErrorCodes.QUEUE_RESYNC_REQUIRED, response["errorCode"])
    }

    @Test
    fun `dispatchStoredPlayback catches non SQLite exceptions and returns platform error`() {
        val response = com.doujin.audio.player.common.dispatchStoredPlayback("snapshot") {
            throw IllegalStateException("corrupt preferences")
        }
        assertEquals(false, response["ok"])
        assertEquals(ChannelErrorCodes.PLATFORM_ERROR, response["errorCode"])
        assertEquals(mapOf("method" to "snapshot"), response["details"])
    }
}
