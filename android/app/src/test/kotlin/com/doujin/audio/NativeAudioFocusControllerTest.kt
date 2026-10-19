package com.doujin.audio

import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import com.doujin.audio.player.recovery.NativeAudioFocusController
import com.doujin.audio.player.recovery.NativePlaybackFocusRecoveryCoordinator
import com.doujin.audio.player.recovery.NativePlaybackFocusRecoveryHost
import com.doujin.audio.player.session.StoredPlaybackBehavior
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowAudioManager

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [26, 33], manifest = Config.NONE)
class NativeAudioFocusControllerTest {
    @Test
    fun `duck requests reach the pause policy and gain resumes playback`() {
        val fixture = FocusFixture(pauseOnDuck = true)

        fixture.dispatch(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)

        assertFalse(fixture.controller.isHeld)
        assertEquals(1, fixture.host.pauseCount)
        assertTrue(fixture.coordinator.isPending("session"))

        fixture.dispatch(AudioManager.AUDIOFOCUS_GAIN)

        assertTrue(fixture.controller.isHeld)
        assertEquals(1, fixture.host.playCount)
        assertFalse(fixture.coordinator.hasPendingResume())
    }

    @Test
    fun `duck requests lower volume and gain restores it when pause is disabled`() {
        val fixture = FocusFixture(pauseOnDuck = false)

        fixture.dispatch(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
        fixture.dispatch(AudioManager.AUDIOFOCUS_GAIN)

        assertEquals(listOf(0.2f, 1f), fixture.host.duckMultipliers)
        assertEquals(0, fixture.host.pauseCount)
        assertEquals(0, fixture.host.playCount)
        assertFalse(fixture.coordinator.interruptionActive)
    }

    @Test
    fun `an existing focus request follows policy changes in both directions`() {
        val fixture = FocusFixture(pauseOnDuck = false)
        fixture.host.behavior = fixture.host.behavior.copy(pauseOnTransientAudioFocusLoss = true)

        fixture.dispatch(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
        fixture.dispatch(AudioManager.AUDIOFOCUS_GAIN)

        assertEquals(1, fixture.host.pauseCount)
        assertEquals(1, fixture.host.playCount)

        fixture.host.behavior = fixture.host.behavior.copy(pauseOnTransientAudioFocusLoss = false)
        fixture.dispatch(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
        fixture.dispatch(AudioManager.AUDIOFOCUS_GAIN)

        assertEquals(1, fixture.host.pauseCount)
        assertEquals(1, fixture.host.playCount)
        assertEquals(listOf(0.2f, 1f), fixture.host.duckMultipliers)
    }

    @Test
    fun `gain keeps a duck interruption paused when automatic resume is disabled`() {
        val fixture = FocusFixture(pauseOnDuck = true)
        fixture.host.behavior = fixture.host.behavior.copy(resumeAfterTransientAudioFocusGain = false)

        fixture.dispatch(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
        fixture.dispatch(AudioManager.AUDIOFOCUS_GAIN)

        assertEquals(1, fixture.host.pauseCount)
        assertEquals(0, fixture.host.playCount)
        assertEquals(listOf("session"), fixture.host.clearedIntents)
        assertFalse(fixture.coordinator.hasPendingResume())
    }
}

private class FocusFixture(pauseOnDuck: Boolean) {
    val host = FocusPolicyHost(pauseOnDuck)
    val controller: NativeAudioFocusController
    val coordinator: NativePlaybackFocusRecoveryCoordinator
    private val request: ShadowAudioManager.AudioFocusRequest

    init {
        val context = RuntimeEnvironment.getApplication()
        val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val shadowManager = shadowOf(manager)
        shadowManager.setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
        controller = NativeAudioFocusController(
            context,
            Handler(Looper.getMainLooper()),
            logInfo = {},
            logWarn = { _, error -> throw AssertionError(error) },
            onFocusChange = ::onFocusChange
        )
        coordinator = NativePlaybackFocusRecoveryCoordinator(host, controller)
        assertTrue(coordinator.requestIfNeeded())
        request = checkNotNull(shadowManager.lastAudioFocusRequest)
        // Android otherwise ducks MUSIC itself and can omit the listener callback.
        assertTrue(request.audioFocusRequest.willPauseWhenDucked())
    }

    fun dispatch(change: Int) = request.listener.onAudioFocusChange(change)

    private fun onFocusChange(change: Int) = coordinator.onFocusChange(change)
}

private class FocusPolicyHost(pauseOnDuck: Boolean) : NativePlaybackFocusRecoveryHost {
    override var behavior = StoredPlaybackBehavior(pauseOnTransientAudioFocusLoss = pauseOnDuck)
    override val playbackSuspended = false
    var pauseCount = 0
    var playCount = 0
    val duckMultipliers = mutableListOf<Float>()
    val clearedIntents = mutableListOf<String>()
    override fun activePlaybackSessionIds() = listOf("session")
    override fun sessionExists(sessionId: String) = sessionId == "session"
    override fun pause(sessionId: String) { pauseCount++ }
    override fun play(sessionId: String) { playCount++ }
    override fun focus(sessionId: String) = Unit
    override fun clearPlaybackIntent(sessionId: String) { clearedIntents += sessionId }
    override fun clearAllPlaybackRecovery() = Unit
    override fun applyFocusDuckMultiplier(multiplier: Float) { duckMultipliers += multiplier }
    override fun publishAllSessions() = Unit
    override fun persistNow() = Unit
    override fun schedulePersist() = Unit
    override fun syncForeground() = Unit
    override fun ensureProgressHeartbeat() = Unit
    override fun logInfo(message: String) = Unit
}
