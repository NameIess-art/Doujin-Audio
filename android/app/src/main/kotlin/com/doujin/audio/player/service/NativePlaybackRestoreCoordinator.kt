package com.doujin.audio.player.service

import android.content.Context
import android.os.Handler
import com.doujin.audio.player.session.NativePlaybackSessionRestorer
import com.doujin.audio.player.session.NativePlaybackStateStore
import com.doujin.audio.player.session.StoredNativePlaybackSession
import java.util.concurrent.Executors

internal class NativePlaybackRestoreCoordinator(
    private val context: Context,
    private val mainHandler: Handler,
    private val sessionRestorer: NativePlaybackSessionRestorer,
    private val resumePlaybackOnStartupRestore: () -> Boolean,
    private val requestAudioFocus: () -> Boolean,
    private val startBootstrap: () -> Unit,
    private val resetRestoreState: () -> Unit,
    private val completeRestore: (
        restoredSessionIds: List<String>,
        autoPlay: Boolean
    ) -> Unit,
    private val hasSessions: () -> Boolean,
    private val hasPlaybackToKeepAlive: () -> Boolean,
    private val hasPendingCommandDelivery: () -> Boolean,
    private val stopIdleService: (startId: Int, reason: String) -> Unit,
    private val onTimerSessionsRestored: (List<String>) -> Unit,
    private val onNotificationSessionRestored: (String) -> Unit,
    private val logInfo: (String) -> Unit
) {
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "NativePlaybackRestore").apply { isDaemon = true }
    }
    private var generation = 0L
    private var latestAcceptedStartId = 0
    private var deferredIdleExit: DeferredIdleExit? = null

    fun acceptStart(startId: Int) {
        latestAcceptedStartId = startId
    }

    fun restoreAfterServiceRestart(startId: Int) {
        val requestedGeneration = ++generation
        executor.execute {
            val storedSessions = NativePlaybackStateStore.loadSessions(context)
                .filter { it.playing || it.playWhenReady }
            mainHandler.post {
                if (requestedGeneration != generation) return@post
                restoreOnMain(storedSessions, requestedGeneration, startId)
            }
        }
    }

    fun restoreSessionsForTimer(sessionIds: List<String>, existingSessionIds: Set<String>) {
        val missingSessionIds = sessionIds.filterNot(existingSessionIds::contains).toSet()
        if (missingSessionIds.isEmpty()) return
        val restored = sessionRestorer.restore(
            storedSessions = NativePlaybackStateStore.loadSessions(context)
                .filter { it.sessionId in missingSessionIds },
            autoPlay = { false }
        )
        onTimerSessionsRestored(restored)
    }

    fun restoreSessionForNotification(
        sessionId: String,
        loadedSessions: List<StoredNativePlaybackSession>,
        sessionExists: Boolean
    ) {
        if (sessionExists) return
        sessionRestorer.restore(
            storedSessions = loadedSessions.filter { it.sessionId == sessionId },
            autoPlay = { false },
            onRestored = onNotificationSessionRestored
        )
    }

    fun onPendingCommandDeliveriesSettled() {
        mainHandler.post {
            if (hasPendingCommandDelivery()) return@post
            val pending = deferredIdleExit ?: return@post
            deferredIdleExit = null
            stopIdleServiceAfterRestoreIfEligible(
                requestedGeneration = pending.generation,
                startId = pending.startId,
                reason = pending.reason
            )
        }
    }

    fun shutdown() {
        generation += 1
        deferredIdleExit = null
        executor.shutdownNow()
    }

    private fun restoreOnMain(
        storedSessions: List<StoredNativePlaybackSession>,
        requestedGeneration: Long,
        startId: Int
    ) {
        if (storedSessions.isEmpty()) {
            logInfo("sticky_restore_skip no_active_sessions")
            stopIdleServiceAfterRestoreIfEligible(
                requestedGeneration = requestedGeneration,
                startId = startId,
                reason = "sticky_restore_empty"
            )
            return
        }

        logInfo("sticky_restore_begin sessionCount=${storedSessions.size}")
        startBootstrap()
        resetRestoreState()
        val restoredSessionIds = mutableListOf<String>()
        val resumeRequested = resumePlaybackOnStartupRestore()
        val shouldAutoPlay = shouldAutoPlayWithAudioFocus(resumeRequested, requestAudioFocus)
        if (resumeRequested && !shouldAutoPlay) {
            logInfo("sticky_restore_auto_play_focus_denied")
        }

        fun restoreNext(index: Int) {
            if (requestedGeneration != generation) return
            if (index >= storedSessions.size) {
                if (restoredSessionIds.isEmpty()) {
                    logInfo("sticky_restore_skip restore_failed")
                    stopIdleServiceAfterRestoreIfEligible(
                        requestedGeneration = requestedGeneration,
                        startId = startId,
                        reason = "sticky_restore_failed"
                    )
                    return
                }
                completeRestore(restoredSessionIds, shouldAutoPlay)
                logInfo(
                    "sticky_restore_complete restored=${restoredSessionIds.size} " +
                        "queueItems=${storedSessions.sumOf { it.queue.size }}"
                )
                return
            }

            val stored = storedSessions[index]
            restoredSessionIds += sessionRestorer.restore(
                storedSessions = listOf(stored),
                autoPlay = { shouldAutoPlay && (it.playWhenReady || it.playing) }
            )
            mainHandler.post { restoreNext(index + 1) }
        }

        restoreNext(0)
    }

    private fun stopIdleServiceAfterRestoreIfEligible(
        requestedGeneration: Long,
        startId: Int,
        reason: String
    ) {
        val decision = decideIdlePlaybackServiceStopAfterRestore(
            hasSessions = hasSessions(),
            hasPlaybackToKeepAlive = hasPlaybackToKeepAlive(),
            restoreGeneration = requestedGeneration,
            currentRestoreGeneration = generation,
            latestStartId = latestAcceptedStartId,
            hasPendingCommandDelivery = hasPendingCommandDelivery()
        )
        if (decision.action == IdlePlaybackServiceStopAction.SKIP) {
            logInfo(
                "idle_exit_skip reason=$reason restoreStartId=$startId " +
                    "latestStartId=$latestAcceptedStartId"
            )
            return
        }
        if (decision.action == IdlePlaybackServiceStopAction.DEFER) {
            deferredIdleExit = DeferredIdleExit(
                generation = requestedGeneration,
                startId = decision.startId ?: latestAcceptedStartId,
                reason = reason
            )
            logInfo("idle_exit_defer reason=$reason pending_command_delivery=true")
            return
        }
        deferredIdleExit = null
        generation += 1
        stopIdleService(decision.startId ?: latestAcceptedStartId, reason)
    }

    private data class DeferredIdleExit(
        val generation: Long,
        val startId: Int,
        val reason: String
    )
}
