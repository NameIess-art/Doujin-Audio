package com.doujin.audio.player.recovery

import com.doujin.audio.player.service.NativeAudioFocusAction
import com.doujin.audio.player.service.nativeAudioFocusAction
import com.doujin.audio.player.service.nativeFocusDuckMultiplierAfterAction
import com.doujin.audio.player.service.shouldPreservePendingAudioFocusResume
import com.doujin.audio.player.service.shouldResumePendingAudioFocusPause
import com.doujin.audio.player.service.shouldTrackTransientAudioFocusPause
import com.doujin.audio.player.session.StoredPlaybackBehavior

internal interface NativePlaybackAudioFocusAccess {
    val isHeld: Boolean
    fun requestIfNeeded(): Boolean
    fun abandon(reason: String)
}

internal interface NativePlaybackFocusRecoveryHost {
    val behavior: StoredPlaybackBehavior
    val playbackSuspended: Boolean
    fun activePlaybackSessionIds(): List<String>
    fun sessionExists(sessionId: String): Boolean
    fun pause(sessionId: String)
    fun play(sessionId: String)
    fun focus(sessionId: String)
    fun clearPlaybackIntent(sessionId: String)
    fun clearAllPlaybackRecovery()
    fun applyFocusDuckMultiplier(multiplier: Float)
    fun publishAllSessions()
    fun persistNow()
    fun schedulePersist()
    fun syncForeground()
    fun ensureProgressHeartbeat()
    fun logInfo(message: String)
}

internal class NativePlaybackFocusRecoveryCoordinator(
    private val host: NativePlaybackFocusRecoveryHost,
    private val audioFocus: NativePlaybackAudioFocusAccess
) {
    private var transientLossActive = false
    private var duckActive = false
    private val pendingResumeSessionIds = linkedSetOf<String>()

    val interruptionActive: Boolean
        get() = transientLossActive || duckActive

    fun requestIfNeeded(): Boolean {
        if (!host.behavior.requestAudioFocus) return true
        if (interruptionActive) return false
        return audioFocus.requestIfNeeded()
    }

    fun onFocusChange(change: Int) {
        if (!host.behavior.requestAudioFocus) {
            host.logInfo("audio_focus_change_ignored mixing_enabled")
            return
        }
        when (val action = nativeAudioFocusAction(
            change,
            pauseOnDuck = host.behavior.pauseOnTransientAudioFocusLoss
        )) {
            NativeAudioFocusAction.PAUSE_AND_CLEAR_INTENT -> pauseAndClear(action)
            NativeAudioFocusAction.PAUSE_AND_RESUME_ON_GAIN -> pauseForTransientLoss(action)
            NativeAudioFocusAction.DUCK -> duck(action)
            NativeAudioFocusAction.RESTORE -> restore(action)
            NativeAudioFocusAction.NONE -> Unit
        }
    }

    fun onPlayWhenReadyChanged(sessionId: String, playWhenReady: Boolean, reason: Int) {
        val preserve = shouldPreservePendingAudioFocusResume(
            playWhenReady,
            transientLossActive,
            sessionId in pendingResumeSessionIds
        )
        if (shouldTrackTransientAudioFocusPause(
                playWhenReady,
                reason,
                transientLossActive,
                host.playbackSuspended
            )
        ) {
            pendingResumeSessionIds += sessionId
        } else if (!preserve) {
            pendingResumeSessionIds -= sessionId
        }
    }

    fun resumePendingIfPossible(trigger: String): Boolean {
        if (!shouldResumePendingAudioFocusPause(
                audioFocus.isHeld,
                hasPendingResume(),
                host.playbackSuspended
            )
        ) return false
        val sessionIds = pendingResumeSessionIds.filter(host::sessionExists)
        pendingResumeSessionIds.clear()
        if (sessionIds.isEmpty()) return false
        host.logInfo("audio_focus_pending_resume trigger=$trigger sessionCount=${sessionIds.size}")
        sessionIds.forEach { id -> host.focus(id); host.play(id) }
        host.publishAllSessions()
        host.ensureProgressHeartbeat()
        return true
    }

    fun hasPendingResume(): Boolean = pendingResumeSessionIds.any(host::sessionExists)

    fun isPending(sessionId: String): Boolean = sessionId in pendingResumeSessionIds

    fun removePending(sessionId: String) {
        pendingResumeSessionIds -= sessionId
    }

    fun clearTransientLoss() {
        transientLossActive = false
    }

    fun clearInterruptionState() {
        transientLossActive = false
        duckActive = false
        pendingResumeSessionIds.clear()
        host.applyFocusDuckMultiplier(1f)
    }

    fun abandon(reason: String) {
        clearInterruptionState()
        audioFocus.abandon(reason)
    }

    fun onAudioDeviceDisconnected() {
        if (!host.behavior.pauseOnAudioDeviceDisconnect) {
            host.logInfo("audio_device_disconnect_continue")
            return
        }
        clearInterruptionState()
        host.clearAllPlaybackRecovery()
        host.activePlaybackSessionIds().forEach { sessionId ->
            host.clearPlaybackIntent(sessionId)
            host.pause(sessionId)
        }
        host.publishAllSessions()
        host.persistNow()
        host.syncForeground()
    }

    private fun pauseAndClear(action: NativeAudioFocusAction) {
        transientLossActive = false
        duckActive = false
        pendingResumeSessionIds.clear()
        host.clearAllPlaybackRecovery()
        applyDuck(action)
        host.activePlaybackSessionIds().forEach(host::pause)
        host.publishAllSessions()
        host.persistNow()
        host.syncForeground()
    }

    private fun pauseForTransientLoss(action: NativeAudioFocusAction) {
        transientLossActive = true
        if (duckActive) applyDuck(action)
        duckActive = false
        val ids = host.activePlaybackSessionIds()
        pendingResumeSessionIds += ids
        ids.forEach(host::pause)
        host.publishAllSessions()
        host.schedulePersist()
        host.syncForeground()
    }

    private fun duck(action: NativeAudioFocusAction) {
        transientLossActive = false
        duckActive = true
        applyDuck(action)
        host.logInfo("audio_focus_duck")
        host.publishAllSessions()
        host.schedulePersist()
        host.syncForeground()
    }

    private fun restore(action: NativeAudioFocusAction) {
        transientLossActive = false
        val restoreDuck = duckActive
        duckActive = false
        if (restoreDuck) {
            applyDuck(action)
            host.publishAllSessions()
        }
        val resumed = if (host.behavior.resumeAfterTransientAudioFocusGain) {
            resumePendingIfPossible("audio_focus_gain")
        } else {
            val pausedIds = pendingResumeSessionIds.toList()
            pendingResumeSessionIds.clear()
            pausedIds.forEach(host::clearPlaybackIntent)
            pausedIds.isNotEmpty()
        }
        if (resumed || restoreDuck) {
            host.schedulePersist()
            host.syncForeground()
        }
    }

    private fun applyDuck(action: NativeAudioFocusAction) {
        host.applyFocusDuckMultiplier(nativeFocusDuckMultiplierAfterAction(1f, action))
    }
}
