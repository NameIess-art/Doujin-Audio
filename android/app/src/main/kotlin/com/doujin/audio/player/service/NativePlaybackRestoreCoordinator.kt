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
    private val logInfo: (String) -> Unit,
    private val logWarn: (String, Throwable) -> Unit = { message, error -> logInfo("$message error=$error") },
    private val prepareSessionsOnBackground: (List<StoredNativePlaybackSession>) -> Unit = {},
    private val discardPreparedSessions: (List<StoredNativePlaybackSession>) -> Unit = {}
) {
    private var generation = 0L
    private var latestAcceptedStartId = 0
    private var deferredIdleExit: DeferredIdleExit? = null
    private var excludedSessionIds: MutableSet<String>? = null
    private val missingRestoreGenerations = mutableMapOf<String, Long>()
    private val pendingCompletions = linkedSetOf<() -> Unit>()

    fun acceptStart(startId: Int) {
        latestAcceptedStartId = startId
    }

    fun restoreAfterServiceRestart(startId: Int) {
        val requestedGeneration = ++generation
        excludedSessionIds = mutableSetOf()
        environment.executeBackground {
            var storedSessions = emptyList<StoredNativePlaybackSession>()
            val loaded = runCatching {
                storedSessions = environment.loadSessions().filter { it.playing || it.playWhenReady }
                prepareSessionsOnBackground(storedSessions)
            }
            environment.postMain {
                if (requestedGeneration != generation) {
                    discardPreparedSessions(storedSessions)
                    return@postMain
                }
                loaded.exceptionOrNull()?.let { error ->
                    discardPreparedSessions(storedSessions)
                    excludedSessionIds = null
                    logWarn("sticky_restore_load_failed", error)
                    stopIdleServiceAfterRestoreIfEligible(requestedGeneration, startId, "sticky_restore_load_failed")
                    return@postMain
                }
                restoreOnMain(storedSessions, requestedGeneration, startId)
            }
        }
    }

    fun excludeSessionFromRestartRestore(sessionId: String) {
        excludedSessionIds?.add(sessionId)
        missingRestoreGenerations[sessionId] = (missingRestoreGenerations[sessionId] ?: 0L) + 1L
    }

    fun cancelRestartRestore() {
        generation += 1
        excludedSessionIds = null
        deferredIdleExit = null
        missingRestoreGenerations.keys.toList().forEach(::excludeSessionFromRestartRestore)
    }

    fun restoreMissingSessions(
        sessionIds: List<String>,
        existingSessionIds: Set<String>,
        onFailure: ((Throwable) -> Unit)? = null,
        complete: (Boolean) -> Unit = {}
    ) {
        val missingSessionIds = sessionIds.filterNot(existingSessionIds::contains).toSet()
        if (missingSessionIds.isEmpty()) { complete(true); return }
        val requestedGeneration = generation
        val requests = missingSessionIds.associateWith { sessionId ->
            ((missingRestoreGenerations[sessionId] ?: 0L) + 1L).also {
                missingRestoreGenerations[sessionId] = it
            }
        }
        val finish = pendingCompletion(Result.success(false)) { result: Result<Boolean> ->
            result.fold(complete) { error ->
                logWarn("missing_restore_failed", error)
                if (onFailure != null) onFailure(error) else complete(false)
            }
        }
        environment.executeBackground {
            var stored = emptyList<StoredNativePlaybackSession>()
            val loaded = runCatching {
                stored = environment.loadSessions().filter { it.sessionId in requests }
                prepareSessionsOnBackground(stored)
            }
            environment.postMain {
                val restored = loaded.mapCatching {
                    val valid = stored.filter { session ->
                        requestedGeneration == generation &&
                        requests[session.sessionId] == missingRestoreGenerations[session.sessionId] &&
                            !sessionExists(session.sessionId)
                    }
                    restoreSessions(valid, { false }, {}).also(onMissingSessionsRestored)
                }
                discardPreparedSessions(stored)
                finish(restored.map {
                    requestedGeneration == generation && requests.all { (id, version) ->
                        missingRestoreGenerations[id] == version
                    }
                })
            }
        }
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

    fun loadStoredSessions(
        sessionId: String,
        complete: (List<StoredNativePlaybackSession>?) -> Unit
    ) {
        val requestedGeneration = generation
        val sessionGeneration = (missingRestoreGenerations[sessionId] ?: 0L) + 1L
        missingRestoreGenerations[sessionId] = sessionGeneration
        val sessionGenerations = missingRestoreGenerations.toMap()
        val finish = pendingCompletion<List<StoredNativePlaybackSession>?>(null, complete)
        environment.executeBackground {
            var stored = emptyList<StoredNativePlaybackSession>()
            val loaded = runCatching {
                stored = environment.loadSessions().filter { sessionId.isBlank() || it.sessionId == sessionId }
                prepareSessionsOnBackground(stored)
            }
            environment.postMain {
                loaded.exceptionOrNull()?.let { logWarn("notification_restore_load_failed", it) }
                val valid = loaded.isSuccess && requestedGeneration == generation &&
                    missingRestoreGenerations[sessionId] == sessionGeneration &&
                    (sessionId.isBlank() || !sessionExists(sessionId))
                try {
                    finish(if (valid) stored.filter {
                        sessionGenerations[it.sessionId] == missingRestoreGenerations[it.sessionId]
                    } else null)
                } finally {
                    discardPreparedSessions(stored)
                }
            }
        }
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
        pendingCompletions.toList().forEach { it() }
        environment.shutdown()
    }

    private fun <T> pendingCompletion(cancelled: T, complete: (T) -> Unit): (T) -> Unit {
        var settled = false
        lateinit var cancel: () -> Unit
        val finish: (T) -> Unit = { value ->
            if (!settled) {
                settled = true
                pendingCompletions.remove(cancel)
                complete(value)
            }
        }
        cancel = { finish(cancelled) }
        pendingCompletions += cancel
        return finish
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
            if (requestedGeneration != generation) {
                discardPreparedSessions(storedSessions)
                return
            }
            if (index >= storedSessions.size) {
                discardPreparedSessions(storedSessions)
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
