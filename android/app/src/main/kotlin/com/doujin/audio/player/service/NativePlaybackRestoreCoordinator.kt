package com.doujin.audio.player.service

import android.content.Context
import android.os.Handler
import com.doujin.audio.player.session.NativePlaybackStateStore
import com.doujin.audio.player.session.StoredNativePlaybackSession
import java.util.concurrent.Executors

internal interface NativePlaybackRestoreEnvironment {
    fun loadSessions(): List<StoredNativePlaybackSession>
    fun executeBackground(task: () -> Unit)
    fun postMain(task: () -> Unit)
    fun shutdown()
}

internal class AndroidNativePlaybackRestoreEnvironment(
    private val context: Context,
    private val mainHandler: Handler
) : NativePlaybackRestoreEnvironment {
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "NativePlaybackRestore").apply { isDaemon = true }
    }

    override fun loadSessions(): List<StoredNativePlaybackSession> =
        NativePlaybackStateStore.loadSessions(context)

    override fun executeBackground(task: () -> Unit) = executor.execute(task)

    override fun postMain(task: () -> Unit) {
        mainHandler.post(task)
    }

    override fun shutdown() {
        executor.shutdownNow()
    }
}

internal class NativePlaybackRestoreCoordinator(
    private val environment: NativePlaybackRestoreEnvironment,
    private val restoreSessions: (
        List<StoredNativePlaybackSession>,
        (StoredNativePlaybackSession) -> Boolean,
        (String) -> Unit
    ) -> List<String>,
    private val startBootstrap: () -> NativePlaybackForegroundStartResult,
    private val resetRestoreState: () -> Unit,
    private val completeRestore: (List<String>) -> Unit,
    private val sessionExists: (String) -> Boolean,
    private val hasSessions: () -> Boolean,
    private val hasPlaybackToKeepAlive: () -> Boolean,
    private val hasPendingCommandDelivery: () -> Boolean,
    private val stopIdleService: (Int, String) -> Unit,
    private val onMissingSessionsRestored: (List<String>) -> Unit,
    private val onNotificationSessionRestored: (String) -> Unit,
    private val logInfo: (String) -> Unit
) {
    private var generation = 0L
    private var latestAcceptedStartId = 0
    private var deferredIdleExit: DeferredIdleExit? = null
    private var excludedSessionIds: MutableSet<String>? = null

    fun acceptStart(startId: Int) {
        latestAcceptedStartId = startId
    }

    fun restoreAfterServiceRestart(startId: Int) {
        val requestedGeneration = ++generation
        excludedSessionIds = mutableSetOf()
        environment.executeBackground {
            val storedSessions = environment.loadSessions()
                .filter { it.playing || it.playWhenReady }
            environment.postMain {
                if (requestedGeneration != generation) return@postMain
                restoreOnMain(storedSessions, requestedGeneration, startId)
            }
        }
    }

    fun excludeSessionFromRestartRestore(sessionId: String) {
        excludedSessionIds?.add(sessionId)
    }

    fun cancelRestartRestore() {
        generation += 1
        excludedSessionIds = null
        deferredIdleExit = null
    }

    fun restoreMissingSessions(
        sessionIds: List<String>,
        existingSessionIds: Set<String>
    ) {
        val missingSessionIds = sessionIds.filterNot(existingSessionIds::contains).toSet()
        if (missingSessionIds.isEmpty()) return
        val restored = restoreSessions(
            environment.loadSessions().filter { it.sessionId in missingSessionIds },
            { false },
            {}
        )
        onMissingSessionsRestored(restored)
    }

    fun restoreSessionForNotification(
        sessionId: String,
        loadedSessions: List<StoredNativePlaybackSession>,
        sessionExists: Boolean
    ) {
        if (sessionExists) return
        restoreSessions(
            loadedSessions.filter { it.sessionId == sessionId },
            { false },
            onNotificationSessionRestored
        )
    }

    fun onPendingCommandDeliveriesSettled() {
        environment.postMain {
            if (hasPendingCommandDelivery()) return@postMain
            val pending = deferredIdleExit ?: return@postMain
            deferredIdleExit = null
            stopIdleServiceAfterRestoreIfEligible(
                pending.generation,
                pending.startId,
                pending.reason
            )
        }
    }

    fun shutdown() {
        cancelRestartRestore()
        environment.shutdown()
    }

    private fun restoreOnMain(
        storedSessions: List<StoredNativePlaybackSession>,
        requestedGeneration: Long,
        startId: Int
    ) {
        if (storedSessions.isEmpty()) {
            excludedSessionIds = null
            logInfo("sticky_restore_skip no_active_sessions")
            stopIdleServiceAfterRestoreIfEligible(
                requestedGeneration,
                startId,
                "sticky_restore_empty"
            )
            return
        }
        logInfo("sticky_restore_begin sessionCount=${storedSessions.size}")
        if (!hasSessions()) {
            startBootstrap()
            resetRestoreState()
        }
        val restoredSessionIds = mutableListOf<String>()

        fun restoreNext(index: Int) {
            if (requestedGeneration != generation) return
            if (index >= storedSessions.size) {
                excludedSessionIds = null
                if (restoredSessionIds.isEmpty()) {
                    logInfo("sticky_restore_skip restore_failed")
                    stopIdleServiceAfterRestoreIfEligible(
                        requestedGeneration,
                        startId,
                        "sticky_restore_failed"
                    )
                    return
                }
                completeRestore(restoredSessionIds)
                logInfo(
                    "sticky_restore_complete restored=${restoredSessionIds.size} " +
                        "queueItems=${storedSessions.sumOf { it.queue.size }}"
                )
                return
            }
            val stored = storedSessions[index]
            // Live commands may have prepared or restored this session while disk I/O
            // or the previous main-thread restore step was pending.
            if (!sessionExists(stored.sessionId) &&
                excludedSessionIds?.contains(stored.sessionId) != true
            ) {
                restoredSessionIds += restoreSessions(listOf(stored), { false }, {})
            }
            environment.postMain { restoreNext(index + 1) }
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
        when (decision.action) {
            IdlePlaybackServiceStopAction.SKIP -> logInfo(
                "idle_exit_skip reason=$reason restoreStartId=$startId " +
                    "latestStartId=$latestAcceptedStartId"
            )
            IdlePlaybackServiceStopAction.DEFER -> {
                deferredIdleExit = DeferredIdleExit(
                    requestedGeneration,
                    decision.startId ?: latestAcceptedStartId,
                    reason
                )
                logInfo("idle_exit_defer reason=$reason pending_command_delivery=true")
            }
            IdlePlaybackServiceStopAction.STOP -> {
                deferredIdleExit = null
                generation += 1
                stopIdleService(decision.startId ?: latestAcceptedStartId, reason)
            }
        }
    }

    private data class DeferredIdleExit(
        val generation: Long,
        val startId: Int,
        val reason: String
    )
}
