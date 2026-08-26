package com.doujin.audio

import android.media.AudioManager
import androidx.media3.common.Player
import com.doujin.audio.player.recovery.NativePlaybackAudioFocusAccess
import com.doujin.audio.player.recovery.NativePlaybackFocusRecoveryCoordinator
import com.doujin.audio.player.recovery.NativePlaybackFocusRecoveryHost
import com.doujin.audio.player.session.StoredPlaybackBehavior
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackFocusRecoveryCoordinatorTest {
    @Test
    fun `transient loss pauses active sessions and gain resumes pending sessions`() {
        val host = FakeFocusRecoveryHost(activeIds = linkedSetOf("a", "b"))
        val focus = FakeAudioFocusAccess(isHeld = false)
        val coordinator = NativePlaybackFocusRecoveryCoordinator(host, focus)

        coordinator.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)

        assertEquals(listOf("a", "b"), host.paused)
        assertTrue(coordinator.interruptionActive)
        assertTrue(coordinator.isPending("a"))

        focus.isHeld = true
        coordinator.onFocusChange(AudioManager.AUDIOFOCUS_GAIN)

        assertEquals(listOf("a", "b"), host.played)
        assertFalse(coordinator.interruptionActive)
        assertFalse(coordinator.hasPendingResume())
    }

    @Test
    fun `permanent loss clears recovery and playback intent without auto resume`() {
        val host = FakeFocusRecoveryHost(activeIds = linkedSetOf("a"))
        val coordinator = NativePlaybackFocusRecoveryCoordinator(host, FakeAudioFocusAccess())

        coordinator.onFocusChange(AudioManager.AUDIOFOCUS_LOSS)
        coordinator.onFocusChange(AudioManager.AUDIOFOCUS_GAIN)

        assertEquals(listOf("a"), host.paused)
        assertEquals(1, host.clearAllRecoveryCount)
        assertTrue(host.played.isEmpty())
        assertFalse(coordinator.hasPendingResume())
    }

    @Test
    fun `duck loss changes multiplier without pausing and gain restores volume`() {
        val host = FakeFocusRecoveryHost(activeIds = linkedSetOf("a"))
        val coordinator = NativePlaybackFocusRecoveryCoordinator(host, FakeAudioFocusAccess())

        coordinator.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
        coordinator.onFocusChange(AudioManager.AUDIOFOCUS_GAIN)

        assertEquals(listOf(0.2f, 1f), host.duckMultipliers)
        assertTrue(host.paused.isEmpty())
    }

    @Test
    fun `request is deferred while interrupted and mixing bypasses platform focus`() {
        val host = FakeFocusRecoveryHost(activeIds = linkedSetOf("a"))
        val focus = FakeAudioFocusAccess(isHeld = true)
        val coordinator = NativePlaybackFocusRecoveryCoordinator(host, focus)
        coordinator.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)

        assertFalse(coordinator.requestIfNeeded())
        assertEquals(0, focus.requestCount)

        host.behavior = host.behavior.copy(requestAudioFocus = false)
        assertTrue(coordinator.requestIfNeeded())
        assertEquals(0, focus.requestCount)
    }

    @Test
    fun `player callback preserves only native transient focus pause`() {
        val host = FakeFocusRecoveryHost(activeIds = linkedSetOf("a"))
        val coordinator = NativePlaybackFocusRecoveryCoordinator(host, FakeAudioFocusAccess())
        coordinator.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)

        coordinator.removePending("a")
        coordinator.onPlayWhenReadyChanged(
            sessionId = "a",
            playWhenReady = false,
            reason = Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS
        )
        assertTrue(coordinator.isPending("a"))

        coordinator.removePending("a")
        coordinator.onPlayWhenReadyChanged(
            sessionId = "a",
            playWhenReady = false,
            reason = Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST
        )
        assertFalse(coordinator.isPending("a"))
    }

    @Test
    fun `audio device disconnect clears intent and pauses active sessions`() {
        val host = FakeFocusRecoveryHost(activeIds = linkedSetOf("a", "b"))
        val coordinator = NativePlaybackFocusRecoveryCoordinator(host, FakeAudioFocusAccess())

        coordinator.onAudioDeviceDisconnected()

        assertEquals(listOf("a", "b"), host.clearedIntents)
        assertEquals(listOf("a", "b"), host.paused)
        assertEquals(1, host.clearAllRecoveryCount)
    }
}

private class FakeAudioFocusAccess(
    override var isHeld: Boolean = false
) : NativePlaybackAudioFocusAccess {
    var requestCount = 0
    val abandoned = mutableListOf<String>()
    override fun requestIfNeeded(): Boolean { requestCount += 1; return isHeld }
    override fun abandon(reason: String) { isHeld = false; abandoned += reason }
}

private class FakeFocusRecoveryHost(
    val activeIds: LinkedHashSet<String>
) : NativePlaybackFocusRecoveryHost {
    override var behavior = StoredPlaybackBehavior()
    override var playbackSuspended = false
    val paused = mutableListOf<String>()
    val played = mutableListOf<String>()
    val duckMultipliers = mutableListOf<Float>()
    val clearedIntents = mutableListOf<String>()
    var clearAllRecoveryCount = 0
    override fun activePlaybackSessionIds(): List<String> = activeIds.toList()
    override fun sessionExists(sessionId: String): Boolean = sessionId in activeIds
    override fun pause(sessionId: String) { paused += sessionId }
    override fun play(sessionId: String) { played += sessionId }
    override fun focus(sessionId: String) = Unit
    override fun clearPlaybackIntent(sessionId: String) { clearedIntents += sessionId }
    override fun clearAllPlaybackRecovery() { clearAllRecoveryCount += 1 }
    override fun applyFocusDuckMultiplier(multiplier: Float) { duckMultipliers += multiplier }
    override fun publishAllSessions() = Unit
    override fun persistNow() = Unit
    override fun schedulePersist() = Unit
    override fun syncForeground() = Unit
    override fun ensureProgressHeartbeat() = Unit
    override fun logInfo(message: String) = Unit
}
