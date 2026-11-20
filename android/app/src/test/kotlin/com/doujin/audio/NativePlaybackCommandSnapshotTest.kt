package com.doujin.audio

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.media.audiofx.LoudnessEnhancer
import android.os.Looper
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import com.doujin.audio.player.common.NativePrepareSessionArguments
import com.doujin.audio.player.effects.NativeSessionAudioEffectsRuntime
import com.doujin.audio.player.effects.NativePlaybackResumeFade
import com.doujin.audio.player.effects.PlaybackVolumeMapper
import com.doujin.audio.player.recovery.NativeAudioFocusController
import com.doujin.audio.player.recovery.NativePlaybackFocusRecoveryCoordinator
import com.doujin.audio.player.recovery.NativePlaybackRecoveryController
import com.doujin.audio.player.service.NativePlaybackForegroundCoordinator
import com.doujin.audio.player.service.NativePlaybackRestoreCoordinator
import com.doujin.audio.player.service.NativePlaybackService
import com.doujin.audio.player.service.nativePlaybackTransportAction
import com.doujin.audio.player.session.NativeAudioEffects
import com.doujin.audio.player.session.NativeMediaSessionHost
import com.doujin.audio.player.session.NativePlaybackStateStore
import com.doujin.audio.player.session.NativePlaybackSession
import com.doujin.audio.player.session.NativeMediaItemDescriptor
import com.doujin.audio.player.session.NativePlaybackSessionManager
import com.doujin.audio.player.session.NativePlaybackStatePersistenceCoordinator
import com.doujin.audio.player.session.decodeDefinition
import com.doujin.audio.player.session.encodeDefinition
import com.doujin.audio.player.video.NativeVideoOutputBinding
import com.doujin.audio.player.video.shouldRetainPausedVideoPlayer
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.TrackGroup
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.PlaybackException
import java.lang.reflect.Proxy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull
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
class NativePlaybackCommandSnapshotTest {
    private fun shutdownPersistence(service: NativePlaybackService) {
        val persistence = ReflectionHelpers.callInstanceMethod<NativePlaybackStatePersistenceCoordinator>(
            service, "getStatePersistence"
        )
        persistence.shutdown()
        assertTrue(persistence.awaitTermination())
    }

    @Test
    fun `timer expiry prevents focus gain from restarting interrupted audio`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val sessions = ReflectionHelpers.callInstanceMethod<NativePlaybackSessionManager>(service, "getSessionManager")
        val focus = ReflectionHelpers.callInstanceMethod<NativePlaybackFocusRecoveryCoordinator>(service, "getFocusRecovery")
        val audioFocus = ReflectionHelpers.callInstanceMethod<NativeAudioFocusController>(service, "getAudioFocusController")
        val audioManager = service.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val shadowAudioManager = shadowOf(audioManager)
        shadowAudioManager.setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
        val session = sessions.getOrCreate("timer")
        val track = NativeMediaItemDescriptor("/timer.mp3", "file:///timer.mp3", "Timer", null, null)
        try {
            assertTrue(audioFocus.requestIfNeeded())
            val focusListener = checkNotNull(shadowAudioManager.lastAudioFocusRequest).listener
            session.configure(
                descriptor = track, queue = listOf(track), queueStartIndex = 0,
                startPositionMs = 0L, volume = 1f, speed = 1f,
                repeatOne = false, repeatAll = false, shuffleModeEnabled = false, autoPlay = true
            )
            val player = checkNotNull(session.playerOrNull())
            assertTrue(player.playWhenReady)
            focusListener.onAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
            assertTrue(focus.isPending("timer"))
            assertFalse(player.playWhenReady)

            val paused = service.pausePlayingSessionsForTimer(generation = 1, stopAfterCurrentTrack = true)

            assertEquals(listOf("timer"), paused.sessionIds)
            assertFalse(paused.waitingForTrackEnd)
            assertFalse(focus.isPending("timer"))
            focusListener.onAudioFocusChange(AudioManager.AUDIOFOCUS_GAIN)
            assertFalse(session.playerOrNull()?.playWhenReady == true)
        } finally {
            ReflectionHelpers.callInstanceMethod<NativeMediaSessionHost>(service, "getMediaSessionHost").release("test")
            session.release()
            shutdownPersistence(service)
        }
    }

    @Test
    fun `timer expiry clears a network retry waiting without a playing player`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val sessions = ReflectionHelpers.callInstanceMethod<NativePlaybackSessionManager>(service, "getSessionManager")
        val recovery = ReflectionHelpers.callInstanceMethod<NativePlaybackRecoveryController>(service, "getPlaybackRecovery")
        val session = sessions.getOrCreate("timer-retry")
        session.definitionRevision = NativePlaybackStateStore.sessionRevision(session.sessionId)
        val track = NativeMediaItemDescriptor("stream", "https://audio.example.test/track.mp3", "Track", null, null)
        session.configure(
            descriptor = track, queue = listOf(track), queueStartIndex = 0,
            startPositionMs = 25_000L, volume = 1f, speed = 1f,
            repeatOne = false, repeatAll = false, shuffleModeEnabled = false,
            autoPlay = false, deferPlayerCreation = true
        )
        try {
            recovery.markIntended(session.sessionId)
            recovery.onPlayerError(session.sessionId, recoverable = true, errorCodeName = "ERROR_CODE_IO_NETWORK_CONNECTION_FAILED")
            assertTrue(recovery.isPending(session.sessionId))

            val paused = service.pausePlayingSessionsForTimer(generation = 1, stopAfterCurrentTrack = true)

            assertEquals(listOf(session.sessionId), paused.sessionIds)
            assertFalse(paused.waitingForTrackEnd)
            assertFalse(recovery.isIntended(session.sessionId))
            assertFalse(recovery.isPending(session.sessionId))
            assertTrue(NativePlaybackStateStore.loadSessions(service, setOf(session.sessionId), activeOnly = true).isEmpty())
        } finally {
            shutdownPersistence(service)
            NativePlaybackStateStore.clearSessions(service)
        }
    }

    @Test
    fun `sticky playback respects a timer pause and can restart from the restored position`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val sessions = ReflectionHelpers.callInstanceMethod<NativePlaybackSessionManager>(service, "getSessionManager")
        val foreground = ReflectionHelpers.callInstanceMethod<NativePlaybackForegroundCoordinator>(service, "getForegroundCoordinator")
        val persistence = ReflectionHelpers.callInstanceMethod<NativePlaybackStatePersistenceCoordinator>(service, "getStatePersistence")
        val audioManager = service.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        shadowOf(audioManager).setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
        ReflectionHelpers.setField(foreground, "isStarted", true)
        val session = sessions.getOrCreate("restored")
        val track = NativeMediaItemDescriptor("/restored.mp3", "file:///restored.mp3", "Restored", null, null)
        session.configure(
            descriptor = track, queue = listOf(track), queueStartIndex = 0,
            startPositionMs = 25_000L, volume = 1f, speed = 1f,
            repeatOne = false, repeatAll = false, shuffleModeEnabled = false,
            autoPlay = false, deferPlayerCreation = true
        )
        fun resume() = ReflectionHelpers.callInstanceMethod<Unit>(
            service, "resumeAfterServiceRestart",
            ReflectionHelpers.ClassParameter.from(String::class.java, session.sessionId)
        )
        try {
            NativePlaybackStateStore.storePausedSessionIds(service, listOf(session.sessionId))
            resume()
            assertNull(session.playerOrNull())

            NativePlaybackStateStore.clearPausedSessionIds(service)
            resume()
            val player = checkNotNull(session.playerOrNull())
            assertTrue(player.playWhenReady)
            assertEquals(25_000L, player.currentPosition)
        } finally {
            service.onDestroy()
            assertTrue(persistence.awaitTermination())
            NativePlaybackStateStore.clearSessions(service)
        }
    }

    @Test
    fun `play during soft focus loss ducks existing and newly created sessions`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val sessions = ReflectionHelpers.callInstanceMethod<NativePlaybackSessionManager>(service, "getSessionManager")
        val focus = ReflectionHelpers.callInstanceMethod<NativePlaybackFocusRecoveryCoordinator>(service, "getFocusRecovery")
        val foreground = ReflectionHelpers.callInstanceMethod<NativePlaybackForegroundCoordinator>(service, "getForegroundCoordinator")
        ReflectionHelpers.setField(foreground, "isStarted", true)
        val existing = sessions.getOrCreate("existing")
        fun configure(session: NativePlaybackSession, autoPlay: Boolean) {
            val track = NativeMediaItemDescriptor("/duck.mp3", "file:///duck.mp3", "Ducked", null, null)
            session.configure(
                descriptor = track, queue = listOf(track), queueStartIndex = 0,
                startPositionMs = 0L, volume = 1f, speed = 1f,
                repeatOne = false, repeatAll = false, shuffleModeEnabled = false, autoPlay = autoPlay
            )
        }
        try {
            configure(existing, autoPlay = true)
            focus.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
            assertTrue(focus.isDucking)
            assertEquals(true, service.play("existing")["ok"])
            assertEquals(0.2f, checkNotNull(existing.playerOrNull()).volume, 0f)

            val created = sessions.getOrCreate("created")
            configure(created, autoPlay = false)
            assertEquals(true, service.play("created")["ok"])
            assertEquals(0.2f, checkNotNull(created.playerOrNull()).volume, 0f)

            focus.onFocusChange(AudioManager.AUDIOFOCUS_GAIN)
            assertEquals(1f, checkNotNull(created.playerOrNull()).volume, 0f)
        } finally {
            ReflectionHelpers.callInstanceMethod<NativeMediaSessionHost>(service, "getMediaSessionHost").release("test")
            sessions.allSessions.forEach(NativePlaybackSession::release)
            shutdownPersistence(service)
        }
    }

    @Test
    fun `notification transport registers its start ID without restoring playback`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val restore = ReflectionHelpers.callInstanceMethod<NativePlaybackRestoreCoordinator>(service, "getRestoreCoordinator")
        restore.acceptStart(1)
        val token = ReflectionHelpers.getStaticField<String>(NativePlaybackService::class.java, "internalStartToken")
        val transport = Intent(nativePlaybackTransportAction)
            .putExtra("internal_start_token", token)
            .putExtra("transport_command", "next")

        service.onStartCommand(transport, 0, 2)

        assertEquals(2, restore.latestStartId)
        assertFalse(restore.isRestoring)
    }

    @Test
    fun `denied media session play schedules foreground teardown without a player state change`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val sessions = ReflectionHelpers.callInstanceMethod<NativePlaybackSessionManager>(service, "getSessionManager")
        val session = sessions.getOrCreate("audio")
        val player = ExoPlayer.Builder(service).setUsePlatformDiagnostics(false).build()
        ReflectionHelpers.setField(session, "_player", player)
        val audioManager = service.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        shadowOf(audioManager).setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_FAILED)
        val foreground = ReflectionHelpers.callInstanceMethod<NativePlaybackForegroundCoordinator>(
            service, "getForegroundCoordinator"
        )
        // This manifest-free fixture models an already-promoted service.
        ReflectionHelpers.setField(foreground, "isStarted", true)
        ReflectionHelpers.setField(foreground, "signature", "playback")
        try {
            val mediaSession = ReflectionHelpers.callInstanceMethod<MediaSession>(service, "ensureMediaSession")
            mediaSession.player.play()

            assertFalse(player.playWhenReady)
            assertTrue(foreground.isStarted)
            shadowOf(Looper.getMainLooper()).idle()
            assertFalse(foreground.isStarted)
        } finally {
            session.release()
            shutdownPersistence(service)
        }
    }

    @Test
    fun `early pause retains video before tracks or a surface are available`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val sessions = ReflectionHelpers.callInstanceMethod<NativePlaybackSessionManager>(service, "getSessionManager")
        val session = sessions.getOrCreate("video")
        val descriptor = NativeMediaItemDescriptor(
            "content://media/document/primary%3AMovies%2Fclip.MP4", "file:///clip.mp4", "Clip", null, null
        )
        session.configure(
            descriptor = descriptor, queue = listOf(descriptor), queueStartIndex = 0,
            startPositionMs = 12_000L, volume = 1f, speed = 1f,
            repeatOne = false, repeatAll = false, shuffleModeEnabled = false, autoPlay = true
        )
        val player = checkNotNull(session.playerOrNull())
        service.addStateListener("ui") { }
        try {
            assertEquals(Tracks.EMPTY, player.currentTracks)
            assertEquals(VideoSize.UNKNOWN, player.videoSize)
            assertEquals(true, service.pause("video")["ok"])
            assertSame(session, sessions.get("video"))
            assertSame(player, session.playerOrNull())
            assertFalse(player.playWhenReady)
            assertEquals(12_000L, player.currentPosition)
            service.pauseAll()
            assertSame(player, session.playerOrNull())

            var boundPlayer: Player? = null
            val output = object : NativeVideoOutputBinding<Player> {
                override fun bindPlayer(player: Player?) { boundPlayer = player }
                override fun setKeepScreenOn(keepScreenOn: Boolean) = Unit
            }
            service.registerVideoOutput("video", "inline", output)
            assertSame(player, boundPlayer)
            service.unregisterVideoOutput("video", "inline")
            assertNull(boundPlayer)
            service.registerVideoOutput("video", "fullscreen", output)
            assertSame(player, boundPlayer)
            service.unregisterVideoOutput("video", "fullscreen")

            fun expireIdle() = ReflectionHelpers.callInstanceMethod<Unit>(service, "stopIdleServiceAfterRestore",
                ReflectionHelpers.ClassParameter.from(Int::class.javaPrimitiveType!!, 0),
                ReflectionHelpers.ClassParameter.from(String::class.java, "test_idle"),
                ReflectionHelpers.ClassParameter.from(Boolean::class.javaPrimitiveType!!, true)
            )
            expireIdle()
            assertSame(player, session.playerOrNull())
            service.removeStateListener("ui")
            expireIdle()
            assertNull(session.playerOrNull())
            assertNull(sessions.get("video"))
        } finally {
            session.release()
            shutdownPersistence(service)
        }
    }

    @Test
    fun `pause and pause all retain the player attached to a video output`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val sessions = ReflectionHelpers.callInstanceMethod<NativePlaybackSessionManager>(service, "getSessionManager")
        val session = sessions.getOrCreate("video")
        val player = ExoPlayer.Builder(RuntimeEnvironment.getApplication()).setUsePlatformDiagnostics(false).build()
        ReflectionHelpers.setField(session, "_player", player)
        var boundPlayer: Player? = null
        service.addStateListener("ui") { }
        service.registerVideoOutput("video", "inline", object : NativeVideoOutputBinding<Player> {
            override fun bindPlayer(player: Player?) { boundPlayer = player }
            override fun setKeepScreenOn(keepScreenOn: Boolean) = Unit
        })
        try {
            session.applyTemporarySpeed(2f)
            assertEquals(true, service.pause("video")["ok"])
            assertSame(session, sessions.get("video"))
            assertSame(player, session.playerOrNull())
            assertSame(player, boundPlayer)
            assertFalse(player.playWhenReady)
            assertEquals(1f, player.playbackParameters.speed, 0f)
            service.pauseAll()
            assertSame(player, session.playerOrNull())
            assertSame(player, boundPlayer)
            service.stop("video")
            assertNull(sessions.get("video"))
            assertNull(boundPlayer)
        } finally {
            session.release()
            shutdownPersistence(service)
        }
    }

    @Test
    fun `pausing audio without a video output still retires its player`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val sessions = ReflectionHelpers.callInstanceMethod<NativePlaybackSessionManager>(service, "getSessionManager")
        val session = sessions.getOrCreate("audio")
        ReflectionHelpers.setField(session, "_player", ExoPlayer.Builder(RuntimeEnvironment.getApplication()).setUsePlatformDiagnostics(false).build())
        try {
            assertEquals(true, service.pause("audio")["ok"])
            assertNull(sessions.get("audio"))
            assertNull(session.playerOrNull())
        } finally {
            session.release()
            shutdownPersistence(service)
        }
    }

    @Test
    fun `loaded video remains retained without an output during fullscreen handoff`() {
        val videoTrack = Tracks.Group(
            TrackGroup(Format.Builder().setSampleMimeType("video/avc").build()),
            false, intArrayOf(C.FORMAT_HANDLED), booleanArrayOf(true)
        )
        var tracks = Tracks(listOf(videoTrack))
        var videoSize = VideoSize.UNKNOWN
        var error: PlaybackException? = null
        val player = Proxy.newProxyInstance(Player::class.java.classLoader, arrayOf(Player::class.java)) { _, method, _ ->
            when (method.name) {
                "getCurrentTracks" -> tracks
                "getVideoSize" -> videoSize
                "getPlayerError" -> error
                else -> error("Unexpected Player access: ${method.name}")
            }
        } as Player
        assertTrue(shouldRetainPausedVideoPlayer(player, false))
        tracks = Tracks.EMPTY
        videoSize = VideoSize(640, 360)
        assertTrue(shouldRetainPausedVideoPlayer(player, false))
        videoSize = VideoSize.UNKNOWN
        assertFalse(shouldRetainPausedVideoPlayer(player, false))
        assertTrue(shouldRetainPausedVideoPlayer(player, true))
        error = PlaybackException("failed video", null, PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND)
        assertFalse(shouldRetainPausedVideoPlayer(player, true))
        assertFalse(shouldRetainPausedVideoPlayer(null, true))
    }

    @Test
    fun `idle cleanup preserves a paused video for attached UI and releases it after UI detaches`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val sessions = ReflectionHelpers.callInstanceMethod<NativePlaybackSessionManager>(service, "getSessionManager")
        val session = sessions.getOrCreate("video")
        val player = ExoPlayer.Builder(RuntimeEnvironment.getApplication()).setUsePlatformDiagnostics(false).build()
        ReflectionHelpers.setField(session, "_player", player)
        service.addStateListener("ui") { }
        service.registerVideoOutput("video", "inline", object : NativeVideoOutputBinding<Player> {
            override fun bindPlayer(player: Player?) = Unit
            override fun setKeepScreenOn(keepScreenOn: Boolean) = Unit
        })
        fun expireIdle() = ReflectionHelpers.callInstanceMethod<Unit>(service, "stopIdleServiceAfterRestore",
            ReflectionHelpers.ClassParameter.from(Int::class.javaPrimitiveType!!, 0),
            ReflectionHelpers.ClassParameter.from(String::class.java, "test_idle"),
            ReflectionHelpers.ClassParameter.from(Boolean::class.javaPrimitiveType!!, true)
        )
        try {
            expireIdle()
            assertSame(player, session.playerOrNull())
            assertSame(session, sessions.get("video"))
            service.unregisterVideoOutput("video", "inline")
            service.removeStateListener("ui")
            expireIdle()
            assertNull(session.playerOrNull())
            assertNull(sessions.get("video"))
        } finally {
            session.release()
            shutdownPersistence(service)
        }
    }

    @Test
    fun `changing one fade multiplier restores another interrupted resume fade`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val sessions = ReflectionHelpers.callInstanceMethod<NativePlaybackSessionManager>(service, "getSessionManager")
        val first = sessions.getOrCreate("A")
        val second = sessions.getOrCreate("B")
        val fade = ReflectionHelpers.callInstanceMethod<NativePlaybackResumeFade>(service, "getTimerResumeFade")
        fade.start(listOf("A", "B"))
        service.setFadeMultiplier("A", 0.5f)

        assertEquals(0.5f, first.fadeMultiplier, 0f)
        assertEquals(1f, second.fadeMultiplier, 0f)
    }

    @Test
    fun `combined stereo changes reprepare once and live changes preserve the queue`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val sessions = ReflectionHelpers.callInstanceMethod<NativePlaybackSessionManager>(service, "getSessionManager")
        val session = sessions.getOrCreate("stereo")
        val player = ExoPlayer.Builder(RuntimeEnvironment.getApplication()).setUsePlatformDiagnostics(false).build()
        ReflectionHelpers.setField(session, "_player", player)
        val descriptor = NativeMediaItemDescriptor("/track.mp3", "file:///track.mp3", "Track", null, null)
        session.configure(
            descriptor = descriptor, queue = listOf(descriptor), queueStartIndex = 0,
            startPositionMs = 1_234L, volume = 1f, speed = 1f,
            repeatOne = false, repeatAll = false, shuffleModeEnabled = false, autoPlay = false
        )
        var queueChanges = 0
        player.addListener(object : Player.Listener {
            override fun onTimelineChanged(timeline: Timeline, reason: Int) {
                if (reason == Player.TIMELINE_CHANGE_REASON_PLAYLIST_CHANGED) queueChanges++
            }
        })
        try {
            service.setAudioEffects("stereo", NativeAudioEffects(panning = 0.5f, channelSwapEnabled = true))
            assertEquals(1, queueChanges)
            assertEquals(1_234L, player.currentPosition)
            service.setAudioEffects("stereo", NativeAudioEffects(channelSwapEnabled = true))
            service.setAudioEffects("stereo", NativeAudioEffects(panning = -0.5f))
            assertEquals(1, queueChanges)
            service.setAudioEffects("stereo", NativeAudioEffects())
            assertEquals(2, queueChanges)
            assertEquals(1_234L, player.currentPosition)
            assertEquals(1, player.mediaItemCount)
        } finally {
            session.release()
            shutdownPersistence(service)
        }
    }

    @Test
    fun `fade and duck update player volume without reapplying user boost`() {
        val player = ExoPlayer.Builder(RuntimeEnvironment.getApplication()).setUsePlatformDiagnostics(false).build()
        player.setAudioSessionId(42)
        val session = NativePlaybackSession("boost", { _, _ -> player }, { _, _, _ -> })
        val effects = ReflectionHelpers.getField<NativeSessionAudioEffectsRuntime>(session, "audioEffects")
        try {
            val descriptor = NativeMediaItemDescriptor("/track.mp3", "file:///track.mp3", "Track", null, null)
            session.configure(
                descriptor = descriptor, queue = listOf(descriptor), queueStartIndex = 0,
                startPositionMs = 1_234L, volume = 2f, speed = 1f,
                repeatOne = false, repeatAll = false, shuffleModeEnabled = false, autoPlay = false
            )
            val enhancer = ReflectionHelpers.getField<LoudnessEnhancer>(effects, "loudnessEnhancer")
            assertEquals(PlaybackVolumeMapper.boostGainMillibels(2f).toFloat(), enhancer.targetGain, 0f)
            enhancer.setTargetGain(123)
            enhancer.enabled = false
            repeat(200) { session.applyFadeMultiplier(it / 200f) }
            session.applyFocusDuckMultiplier(0.2f)
            assertEquals(0.199f, player.volume, 0.001f)
            assertEquals(123f, enhancer.targetGain, 0f)
            assertFalse(enhancer.enabled)

            session.applyVolume(1.5f)
            assertEquals(PlaybackVolumeMapper.boostGainMillibels(1.5f).toFloat(), enhancer.targetGain, 0f)
            assertTrue(enhancer.enabled)
            session.onAudioSessionIdChanged(43)
            val replacement = ReflectionHelpers.getField<LoudnessEnhancer>(effects, "loudnessEnhancer")
            assertEquals(PlaybackVolumeMapper.boostGainMillibels(1.5f).toFloat(), replacement.targetGain, 0f)
            assertTrue(replacement.enabled)
            session.applyVolume(1f)
            assertNull(ReflectionHelpers.getField<LoudnessEnhancer?>(effects, "loudnessEnhancer"))
        } finally {
            session.release()
        }
    }

    @Test
    fun `commands return the snapshot already published to listeners`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val sessions = ReflectionHelpers.callInstanceMethod<NativePlaybackSessionManager>(
            service, "getSessionManager"
        )
        sessions.getOrCreate("deferred")
        val events = mutableListOf<Map<String, Any?>>()
        service.addStateListener("test", events::add)
        val commands = listOf<() -> Map<String, Any?>>(
            { service.seek("deferred", 1_234L) },
            { service.setVolume("deferred", 1.5f) },
            { service.setSpeed("deferred", 1.2f) },
            { service.setAudioEffects("deferred", NativeAudioEffects(panning = 0.5f)) }
        )
        try {
            for (command in commands) {
                events.clear()
                val response = command()
                assertEquals(true, response["ok"])
                assertEquals(1, events.size)
                assertSame(events.single(), response["value"])
            }
            assertEquals(1_234L, events.single()["positionMs"])
            assertEquals(1.5, events.single()["volume"])
            val previous = events.single()
            events.clear()
            val temporarySpeed = service.setTemporarySpeed("deferred", 1.4f)
            assertEquals(previous, temporarySpeed["value"])
            assertTrue(events.isEmpty())
            assertEquals(1.4f, sessions.get("deferred")!!.progressAnchorSnapshot().speed, 0f)
        } finally {
            service.removeStateListener("test")
            shutdownPersistence(service)
        }
    }

    @Test
    fun `single track repeatAll uses REPEAT_MODE_ALL and unchanged queue updates in place`() {
        val player = ExoPlayer.Builder(RuntimeEnvironment.getApplication()).setUsePlatformDiagnostics(false).build()
        val session = NativePlaybackSession("loop", { _, _ -> player }, { _, _, _ -> })
        val track1 = NativeMediaItemDescriptor("/t1.mp3", "file:///t1.mp3", "Track 1", null, null)
        val track0 = NativeMediaItemDescriptor("/t0.mp3", "file:///t0.mp3", "Track 0", null, null)
        val track2 = NativeMediaItemDescriptor("/t2.mp3", "file:///t2.mp3", "Track 2", null, null)
        try {
            session.configure(
                descriptor = track1,
                queue = listOf(track1),
                queueStartIndex = 0,
                startPositionMs = 4_321L,
                volume = 1f,
                speed = 1f,
                repeatOne = false,
                repeatAll = true,
                shuffleModeEnabled = false,
                autoPlay = true
            )
            assertEquals(Player.REPEAT_MODE_ALL, player.repeatMode)
            val initialState = player.playbackState
            assertTrue(initialState != Player.STATE_IDLE)

            session.updateQueue(
                queue = listOf(track0, track1, track2),
                queueStartIndex = 1,
                repeatOne = false,
                repeatAll = true,
                shuffleModeEnabled = false
            )
            assertEquals(3, player.mediaItemCount)
            assertEquals(1, player.currentMediaItemIndex)
            assertEquals("/t1.mp3", player.currentMediaItem?.mediaId)
            assertEquals(initialState, player.playbackState)
            assertTrue(player.playWhenReady)
            assertEquals(4_321L, player.currentPosition)
        } finally {
            session.release()
        }
    }

    @Test
    fun `native transition consumes a removed occurrence and resumes the requested loop`() {
        val player = ExoPlayer.Builder(RuntimeEnvironment.getApplication()).setUsePlatformDiagnostics(false).build()
        val session = NativePlaybackSession("detached", { _, _ -> player }, { _, _, _ -> })
        val removed = NativeMediaItemDescriptor(
            "/same.mp3", "file:///same.mp3", "Removed", null, null, playOnceBeforeQueue = true
        )
        val first = removed.copy(title = "Remaining first", playOnceBeforeQueue = false)
        val second = first.copy(title = "Remaining second")
        try {
            session.configure(
                descriptor = removed, queue = listOf(removed, first, second), queueStartIndex = 0,
                startPositionMs = 42_000L, volume = 1f, speed = 1f, repeatOne = false,
                repeatAll = true, shuffleModeEnabled = true, autoPlay = true
            )
            assertEquals(Player.REPEAT_MODE_OFF, player.repeatMode)
            assertFalse(player.hasPreviousMediaItem())
            assertTrue(player.hasNextMediaItem())
            val before = checkNotNull(session.storedSnapshot().encodeDefinition().decodeDefinition())
            assertTrue(before.queue.first().playOnceBeforeQueue)
            assertTrue(before.repeatAll)

            // The same URI at a different index is a different queue occurrence.
            player.seekTo(2, 3_000L)
            session.onMediaItemTransition()

            assertEquals(2, player.mediaItemCount)
            assertEquals(Player.REPEAT_MODE_ALL, player.repeatMode)
            assertTrue(player.shuffleModeEnabled)
            assertTrue(player.playWhenReady)
            val snapshot = session.snapshot()
            assertEquals("Remaining second", snapshot["title"])
            assertEquals(1, snapshot["queueIndex"])
            assertEquals(3_000L, snapshot["positionMs"])
            assertEquals(true, snapshot["discardedQueuePrefix"])
            val after = checkNotNull(session.storedSnapshot().encodeDefinition().decodeDefinition())
            assertTrue(after.discardedQueuePrefix)
            assertEquals(listOf("Remaining first", "Remaining second"), after.queue.map { it.title })
            assertEquals(1, after.queueStartIndex)
        } finally {
            session.release()
        }
    }

    @Test
    fun `mediaSession registers with MediaSessionService and prepareSession retains player before play`() {
        val service = Robolectric.buildService(NativePlaybackService::class.java).get()
        val sessions = ReflectionHelpers.callInstanceMethod<NativePlaybackSessionManager>(
            service, "getSessionManager"
        )
        val foreground = ReflectionHelpers.callInstanceMethod<NativePlaybackForegroundCoordinator>(
            service, "getForegroundCoordinator"
        )
        val mediaHost = ReflectionHelpers.callInstanceMethod<NativeMediaSessionHost>(
            service, "getMediaSessionHost"
        )
        val existingPlayer = ExoPlayer.Builder(service).setUsePlatformDiagnostics(false).build()
        val existing = sessions.getOrCreate("prep")
        ReflectionHelpers.setField(existing, "_player", existingPlayer)
        try {
            val mediaSession = ReflectionHelpers.callInstanceMethod<MediaSession>(service, "ensureMediaSession")
            assertTrue(service.sessions.contains(mediaSession))

            val track = NativeMediaItemDescriptor("/next.mp3", "file:///next.mp3", "Next", "Artist", null)
            val args = NativePrepareSessionArguments(
                sessionId = "prep",
                uri = track.uri,
                path = track.path,
                title = track.title,
                subtitle = track.subtitle,
                artUri = track.artUri,
                startPositionMs = 0L,
                autoPlay = false,
                volume = 1f,
                speed = 1f,
                audioEffects = NativeAudioEffects(),
                repeatOne = false,
                queue = listOf(track),
                queueStartIndex = 0,
                repeatAll = false,
                shuffle = false,
                candidateUris = listOf(track.uri),
                deferPlayerCreation = false
            )
            val result = service.prepareSession(args)
            assertEquals(true, result["ok"])
            assertTrue(foreground.isHoldingPlaybackStart("prep"))
            assertSame(existing, sessions.get("prep"))
            assertSame(existingPlayer, existing.playerOrNull())

            mediaHost.release("test")
            assertFalse(service.sessions.contains(mediaSession))
        } finally {
            sessions.get("prep")?.release()
            shutdownPersistence(service)
            NativePlaybackStateStore.clearSessions(service)
        }
    }
}
