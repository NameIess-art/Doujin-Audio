package com.doujin.audio

import android.app.AlarmManager
import android.app.NotificationManager
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import com.doujin.audio.player.common.NativePrepareSessionArguments
import com.doujin.audio.player.recovery.NativePlaybackWakeLockController
import com.doujin.audio.player.service.NativePlaybackForegroundCoordinator
import com.doujin.audio.player.service.NativePlaybackProgressHeartbeatCoordinator
import com.doujin.audio.player.service.NativePlaybackService
import com.doujin.audio.player.session.NativeAudioEffects
import com.doujin.audio.player.session.NativeMediaItemDescriptor
import com.doujin.audio.player.session.NativeMediaSessionHost
import com.doujin.audio.player.session.NativePlaybackSessionManager
import com.doujin.audio.player.session.NativePlaybackStatePersistenceCoordinator
import com.doujin.audio.player.session.NativePlaybackStateStore
import java.time.Duration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class NativePlaybackScreenOffSoakTest {
    @Test
    fun `local queue advances through twelve screen off hours without Flutter`() =
        runSoak("file:///audio", C.WAKE_MODE_LOCAL)

    @Test
    fun `SAF queue advances through twelve screen off hours without Flutter`() =
        runSoak("content://documents/tree/audio/document", C.WAKE_MODE_LOCAL)

    @Test
    fun `online queue advances through twelve screen off hours without Flutter`() =
        runSoak("https://audio.example.test", C.WAKE_MODE_NETWORK)

    @Test
    fun `screen off recoverable error holds wake locks preserves media session and recovers without screen on`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val sessions = ReflectionHelpers.callInstanceMethod<NativePlaybackSessionManager>(service, "getSessionManager")
        val foreground = ReflectionHelpers.callInstanceMethod<NativePlaybackForegroundCoordinator>(service, "getForegroundCoordinator")
        val wakeLocks = ReflectionHelpers.callInstanceMethod<NativePlaybackWakeLockController>(service, "getWakeLocks")
        val mediaSessionHost = ReflectionHelpers.callInstanceMethod<NativeMediaSessionHost>(service, "getMediaSessionHost")
        val progress = ReflectionHelpers.callInstanceMethod<NativePlaybackProgressHeartbeatCoordinator>(service, "getProgressHeartbeat")
        val persistence = ReflectionHelpers.callInstanceMethod<NativePlaybackStatePersistenceCoordinator>(service, "getStatePersistence")
        val clock = shadowOf(Looper.getMainLooper())
        val power = shadowOf(service.getSystemService(PowerManager::class.java))
        val sessionId = "screen-off-recovery"
        val session = sessions.getOrCreate(sessionId)
        val timeline = ExoPlayer.Builder(service).setUsePlatformDiagnostics(false).build()
        val player = SimulatedAudioOutput(timeline)
        ReflectionHelpers.setField(session, "_player", player)
        ReflectionHelpers.setField(foreground, "isStarted", true)
        shadowOf(service.getSystemService(NotificationManager::class.java)).setNotificationsEnabled(false)
        val item = NativeMediaItemDescriptor(
            "https://audio.example.test/stream.mp3",
            "https://audio.example.test/stream.mp3",
            "Stream",
            null,
            null
        )
        try {
            progress.start()
            val result = service.prepareSession(
                NativePrepareSessionArguments(
                    sessionId = sessionId,
                    uri = item.uri,
                    path = item.path,
                    title = item.title,
                    subtitle = null,
                    artUri = null,
                    startPositionMs = 0L,
                    autoPlay = true,
                    volume = 1f,
                    speed = 1f,
                    audioEffects = NativeAudioEffects(),
                    repeatOne = false,
                    queue = listOf(item),
                    queueStartIndex = 0,
                    repeatAll = false,
                    shuffle = false,
                    candidateUris = emptyList(),
                    deferPlayerCreation = false,
                    definitionRevision = NativePlaybackStateStore.sessionRevision(sessionId)
                )
            )
            assertEquals(true, result["ok"])
            val initialMediaSession = checkNotNull(mediaSessionHost.current())
            assertTrue(mediaSessionHost.isAttachedTo(player))

            power.setIsInteractive(false)
            service.sendBroadcast(Intent(Intent.ACTION_SCREEN_OFF))
            clock.idle()
            assertFalse(progress.isScreenInteractive())

            // Simulate ExoPlayer dropping into STATE_IDLE on a transient network error while screen is off.
            player.simulatedState = Player.STATE_IDLE
            timeline.playWhenReady = false
            ReflectionHelpers.callInstanceMethod<Unit>(
                service,
                "handlePlayerError",
                ReflectionHelpers.ClassParameter.from(String::class.java, sessionId),
                ReflectionHelpers.ClassParameter.from(
                    PlaybackException::class.java,
                    PlaybackException(
                        "network timeout",
                        null,
                        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT
                    )
                )
            )
            // Service-level locks must stay held while ExoPlayer is IDLE soHandler backoff does not freeze.
            assertTrue(wakeLocks.isCpuWakeHeld)
            assertTrue(wakeLocks.isWifiWakeHeld)

            player.simulatedState = Player.STATE_READY
            clock.idleFor(Duration.ofSeconds(2))
            assertFalse(progress.isScreenInteractive())
            assertTrue(player.isPlaying)
            assertSame(initialMediaSession, mediaSessionHost.current())
            assertTrue(wakeLocks.isCpuWakeHeld)
            assertTrue(wakeLocks.isWifiWakeHeld)
        } finally {
            service.onDestroy()
            assertFalse(wakeLocks.isCpuWakeHeld)
            assertFalse(wakeLocks.isWifiWakeHeld)
            assertTrue(persistence.awaitTermination())
            NativePlaybackStateStore.clearSessions(service)
        }
    }

    private fun runSoak(uriPrefix: String, expectedWakeMode: Int) {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val sessions = ReflectionHelpers.callInstanceMethod<NativePlaybackSessionManager>(service, "getSessionManager")
        val foreground = ReflectionHelpers.callInstanceMethod<NativePlaybackForegroundCoordinator>(service, "getForegroundCoordinator")
        val wakeLocks = ReflectionHelpers.callInstanceMethod<NativePlaybackWakeLockController>(service, "getWakeLocks")
        val progress = ReflectionHelpers.callInstanceMethod<NativePlaybackProgressHeartbeatCoordinator>(service, "getProgressHeartbeat")
        val persistence = ReflectionHelpers.callInstanceMethod<NativePlaybackStatePersistenceCoordinator>(service, "getStatePersistence")
        val mainLooper = Looper.getMainLooper()
        val handler = Handler(mainLooper)
        val clock = shadowOf(mainLooper)
        val power = shadowOf(service.getSystemService(PowerManager::class.java))
        val alarms = shadowOf(service.getSystemService(AlarmManager::class.java))
        val sessionId = "screen-off-soak"
        val session = sessions.getOrCreate(sessionId)
        val timeline = ExoPlayer.Builder(service).setUsePlatformDiagnostics(false).build()
        val player = SimulatedAudioOutput(timeline)
        ReflectionHelpers.setField(session, "_player", player)
        // This fixture exercises an already-promoted service. Its manifest-free
        // context cannot post the app's notification resources.
        ReflectionHelpers.setField(foreground, "isStarted", true)
        shadowOf(service.getSystemService(NotificationManager::class.java)).setNotificationsEnabled(false)

        timeline.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                ReflectionHelpers.callInstanceMethod<Unit>(
                    service, "handleMediaItemTransition",
                    ReflectionHelpers.ClassParameter.from(String::class.java, sessionId),
                    ReflectionHelpers.ClassParameter.from(Int::class.javaPrimitiveType, reason)
                )
            }
        })
        val queue = List(2) { index ->
            val uri = "$uriPrefix/chapter-$index.mp3"
            NativeMediaItemDescriptor(uri, uri, "Chapter $index", null, null)
        }
        val first = queue.first()
        val boundary = Runnable { player.finishChapter() }
        try {
            progress.start()
            service.addStateListener("flutter") { }
            val result = service.prepareSession(
                NativePrepareSessionArguments(
                    sessionId = sessionId,
                    uri = first.uri,
                    path = first.path,
                    title = first.title,
                    subtitle = null,
                    artUri = null,
                    startPositionMs = 0L,
                    autoPlay = true,
                    volume = 1f,
                    speed = 1f,
                    audioEffects = NativeAudioEffects(),
                    repeatOne = false,
                    queue = queue,
                    queueStartIndex = 0,
                    repeatAll = true,
                    shuffle = false,
                    candidateUris = emptyList(),
                    deferPlayerCreation = false,
                    definitionRevision = NativePlaybackStateStore.sessionRevision(sessionId)
                )
            )
            assertEquals(result.toString(), true, result["ok"])
            assertEquals(expectedWakeMode, player.configuredWakeMode)
            power.setIsInteractive(false)
            service.sendBroadcast(Intent(Intent.ACTION_SCREEN_OFF))
            service.removeStateListener("flutter")
            service.onTaskRemoved(null)
            val start = SystemClock.elapsedRealtime()
            repeat(4) { index ->
                handler.postDelayed(boundary, CHAPTER_MS)
                clock.idleFor(Duration.ofMillis(CHAPTER_MS))
                val expectedIndex = (index + 1) % queue.size
                assertEquals(expectedIndex, session.queueIndex)
                assertEquals(queue[expectedIndex].path, session.path)
                assertEquals(0L, player.currentPosition)
                assertTrue(player.isPlaying)
                assertSame(player, session.playerOrNull())
                assertTrue(foreground.isStarted)
                assertTrue(wakeLocks.isCpuWakeHeld)
                assertEquals(expectedWakeMode == C.WAKE_MODE_NETWORK, wakeLocks.isWifiWakeHeld)
                assertFalse(progress.isScheduled)
                assertTrue(alarms.scheduledAlarms.isEmpty())
            }
            assertEquals(12 * 60 * 60 * 1000L, SystemClock.elapsedRealtime() - start)
            clock.idleFor(Duration.ofMinutes(1))
            val saved = NativePlaybackStateStore.loadSessions(service, setOf(sessionId), activeOnly = true).single()
            assertEquals(60_000L, saved.positionMs)
            assertEquals(0, saved.queueStartIndex)

            service.pause(sessionId)
            clock.idle()
            assertFalse(foreground.isStarted)
            assertFalse(wakeLocks.isCpuWakeHeld)
            assertFalse(wakeLocks.isWifiWakeHeld)
            assertTrue(NativePlaybackStateStore.loadSessions(service, setOf(sessionId), activeOnly = true).isEmpty())
        } finally {
            handler.removeCallbacks(boundary)
            service.onDestroy()
            assertTrue(persistence.awaitTermination())
            NativePlaybackStateStore.clearSessions(service)
        }
    }

    // Media3 owns the real playlist, shuffle/repeat decisions, and transition
    // events. Simulate only the decoder's clock and end-of-chapter signal.
    private class SimulatedAudioOutput(private val timeline: ExoPlayer) : ExoPlayer by timeline {
        private var chapterStartedAt = SystemClock.elapsedRealtime()
        var simulatedState: Int = Player.STATE_READY
        var configuredWakeMode = C.WAKE_MODE_NONE
            private set

        override fun prepare() = Unit
        override fun getPlaybackState(): Int = simulatedState
        override fun isPlaying(): Boolean = timeline.playWhenReady && simulatedState == Player.STATE_READY
        override fun getDuration(): Long = CHAPTER_MS
        override fun getCurrentPosition(): Long =
            (SystemClock.elapsedRealtime() - chapterStartedAt).coerceAtMost(CHAPTER_MS)
        override fun getBufferedPosition(): Long = CHAPTER_MS
        override fun setWakeMode(wakeMode: Int) {
            configuredWakeMode = wakeMode
            timeline.setWakeMode(wakeMode)
        }

        fun finishChapter() {
            val nextIndex = timeline.nextMediaItemIndex
            assertTrue(nextIndex != C.INDEX_UNSET)
            chapterStartedAt = SystemClock.elapsedRealtime()
            timeline.seekTo(nextIndex, 0L)
        }
    }

    private companion object {
        const val CHAPTER_MS = 3 * 60 * 60 * 1000L
    }
}
