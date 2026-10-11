package com.doujin.audio

import android.media.audiofx.LoudnessEnhancer
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.exoplayer.ExoPlayer
import com.doujin.audio.player.effects.NativeSessionAudioEffectsRuntime
import com.doujin.audio.player.effects.PlaybackVolumeMapper
import com.doujin.audio.player.service.NativePlaybackService
import com.doujin.audio.player.session.NativeAudioEffects
import com.doujin.audio.player.session.NativePlaybackSession
import com.doujin.audio.player.session.NativeMediaItemDescriptor
import com.doujin.audio.player.session.NativePlaybackSessionManager
import com.doujin.audio.player.session.NativePlaybackStatePersistenceCoordinator
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
