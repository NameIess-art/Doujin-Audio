package com.doujin.audio

import android.media.audiofx.LoudnessEnhancer
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.exoplayer.ExoPlayer
import com.doujin.audio.player.effects.NativeSessionAudioEffectsRuntime
import com.doujin.audio.player.effects.NativePlaybackResumeFade
import com.doujin.audio.player.effects.PlaybackVolumeMapper
import com.doujin.audio.player.service.NativePlaybackService
import com.doujin.audio.player.session.NativeAudioEffects
import com.doujin.audio.player.session.NativePlaybackSession
import com.doujin.audio.player.session.NativeMediaItemDescriptor
import com.doujin.audio.player.session.NativePlaybackSessionManager
import com.doujin.audio.player.session.NativePlaybackStatePersistenceCoordinator
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
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class NativePlaybackCommandSnapshotTest {
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
            ReflectionHelpers.callInstanceMethod<NativePlaybackStatePersistenceCoordinator>(service, "getStatePersistence").shutdown()
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
            ReflectionHelpers.callInstanceMethod<NativePlaybackStatePersistenceCoordinator>(service, "getStatePersistence").shutdown()
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
            ReflectionHelpers.callInstanceMethod<NativePlaybackStatePersistenceCoordinator>(service, "getStatePersistence").shutdown()
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
            ReflectionHelpers.callInstanceMethod<NativePlaybackStatePersistenceCoordinator>(service, "getStatePersistence").shutdown()
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
            ReflectionHelpers.callInstanceMethod<NativePlaybackStatePersistenceCoordinator>(service, "getStatePersistence").shutdown()
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
            ReflectionHelpers.callInstanceMethod<NativePlaybackStatePersistenceCoordinator>(
                service, "getStatePersistence"
            ).shutdown()
        }
    }
}
