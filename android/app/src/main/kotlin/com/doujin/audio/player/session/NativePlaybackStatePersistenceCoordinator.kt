package com.doujin.audio.player.session

import android.content.Context
import android.os.Handler
import java.util.concurrent.atomic.AtomicLong

internal interface NativePlaybackStatePersistenceEnvironment {
    fun postDelayed(runnable: Runnable, delayMs: Long)
    fun removeCallbacks(runnable: Runnable)
    fun execute(task: () -> Unit)
    fun saveSessions(sessions: List<StoredNativePlaybackSession>, revisions: Map<String, Long>)
    fun saveSessionMetadata(sessions: List<StoredNativePlaybackSession>, revisions: Map<String, Long>) {
        saveSessions(sessions, revisions)
    }
    fun saveSessionProgress(progress: List<StoredNativePlaybackProgress>, revisions: Map<String, Long>)
    fun removeSession(sessionId: String, revision: Long)
    fun clearSessions(revision: Long)
    fun shutdown()
    fun stageSessions(sessions: List<StoredNativePlaybackSession>, revisions: Map<String, Long>) {}
    fun awaitTermination(timeoutMs: Long): Boolean = true
}

internal fun StoredNativePlaybackSession.toStoredProgress() =
    StoredNativePlaybackProgress(
        sessionId = sessionId,
        positionMs = positionMs,
        playing = playing,
        playWhenReady = playWhenReady
    )

/**
 * True when two snapshot lists differ only in the per-tick fields, which means
 * the large structural payload (queue, effects, ordering) need not be rewritten.
 */
internal fun nativePlaybackSnapshotsDifferOnlyByProgress(
    previous: List<StoredNativePlaybackSession>,
    next: List<StoredNativePlaybackSession>
): Boolean {
    if (previous.size != next.size) return false
    return previous.zip(next).all { (before, after) ->
        before.copy(positionMs = 0L, playing = false, playWhenReady = false) ==
            after.copy(positionMs = 0L, playing = false, playWhenReady = false)
    }
}

/**
 * True when two snapshots for the same session keep the same queue and retained
 * content URI set, so only the lightweight `sessions` row needs updating.
 */
internal fun nativePlaybackSnapshotsDifferOnlyByMetadata(
    before: StoredNativePlaybackSession,
    after: StoredNativePlaybackSession
): Boolean {
    if (before.sessionId != after.sessionId) return false
    if (before.isTemporary != after.isTemporary) return false
    if (before.queue != after.queue) return false
    if (before.path != after.path || before.uri != after.uri || before.artUri != after.artUri) {
        if (!topLevelContentUrisCoveredByQueue(before) || !topLevelContentUrisCoveredByQueue(after)) {
            return false
        }
    }
    return true
}

private fun topLevelContentUrisCoveredByQueue(session: StoredNativePlaybackSession): Boolean {
    val activeItem = session.queue.getOrNull(session.queueStartIndex)
    fun isCovered(value: String?): Boolean {
        if (value == null || !value.startsWith("content:", ignoreCase = true)) return true
        if (activeItem != null &&
            (value == activeItem.path || value == activeItem.uri || value == activeItem.artUri ||
                value in activeItem.candidateUris)
        ) {
            return true
        }
        return session.queue.any { item ->
            value == item.path || value == item.uri || value == item.artUri || value in item.candidateUris
        }
    }
    return isCovered(session.path) && isCovered(session.uri) && isCovered(session.artUri)
}

private class AndroidNativePlaybackStatePersistenceEnvironment(
    context: Context,
    private val mainHandler: Handler
) : NativePlaybackStatePersistenceEnvironment {
    private val appContext = context.applicationContext

    override fun postDelayed(runnable: Runnable, delayMs: Long) {
        mainHandler.postDelayed(runnable, delayMs)
    }

    override fun removeCallbacks(runnable: Runnable) {
        mainHandler.removeCallbacks(runnable)
    }

    override fun execute(task: () -> Unit) {
        NativePlaybackStateStore.executeOnPersistenceExecutor(task)
    }

    override fun stageSessions(sessions: List<StoredNativePlaybackSession>, revisions: Map<String, Long>) {
        NativePlaybackStateStore.stageSessions(sessions, revisions)
    }

    override fun saveSessions(sessions: List<StoredNativePlaybackSession>, revisions: Map<String, Long>) {
        NativePlaybackStateStore.upsertSessions(appContext, sessions, revisions)
    }

    override fun saveSessionMetadata(sessions: List<StoredNativePlaybackSession>, revisions: Map<String, Long>) {
        NativePlaybackStateStore.upsertSessionMetadata(appContext, sessions, revisions)
    }

    override fun saveSessionProgress(progress: List<StoredNativePlaybackProgress>, revisions: Map<String, Long>) {
        NativePlaybackStateStore.upsertSessionProgress(appContext, progress, revisions)
    }

    override fun removeSession(sessionId: String, revision: Long) {
        NativePlaybackStateStore.removeSession(appContext, sessionId, revision)
    }

    override fun clearSessions(revision: Long) {
        NativePlaybackStateStore.clearSessions(appContext, revision)
    }

    override fun shutdown() {
        // The process-scoped persistence executor continues draining queued writes asynchronously.
    }

    override fun awaitTermination(timeoutMs: Long): Boolean =
        NativePlaybackStateStore.awaitPendingPersistenceForTest(timeoutMs)
}

internal class NativePlaybackStatePersistenceCoordinator(
    private val environment: NativePlaybackStatePersistenceEnvironment,
    private val intervalMs: Long,
    private val debounceMs: Long,
    private val hasSessions: () -> Boolean,
    private val hasActivePlayback: () -> Boolean,
    private val storedSessions: () -> List<StoredNativePlaybackSession>,
    private val sessionRevisions: () -> Map<String, Long> = { emptyMap() },
    private val screenOffIntervalMs: Long = intervalMs,
    private val isScreenInteractive: () -> Boolean = { true }
) {
    constructor(
        context: Context,
        mainHandler: Handler,
        intervalMs: Long,
        debounceMs: Long,
        hasSessions: () -> Boolean,
        hasActivePlayback: () -> Boolean,
        storedSessions: () -> List<StoredNativePlaybackSession>,
        sessionRevisions: () -> Map<String, Long>,
        screenOffIntervalMs: Long = intervalMs,
        isScreenInteractive: () -> Boolean = { true }
    ) : this(
        environment = AndroidNativePlaybackStatePersistenceEnvironment(context, mainHandler),
        intervalMs = intervalMs,
        debounceMs = debounceMs,
        hasSessions = hasSessions,
        hasActivePlayback = hasActivePlayback,
        storedSessions = storedSessions,
        sessionRevisions = sessionRevisions,
        screenOffIntervalMs = screenOffIntervalMs,
        isScreenInteractive = isScreenInteractive
    )

    private val generation = AtomicLong(0L)
    private var tickerScheduled = false
    private var pendingDebounce = false
    private var lastSubmittedSnapshots: List<StoredNativePlaybackSession>? = null

    // Both caches are accessed only on the storage executor. Queue equality and
    // serialization must not run on the player's application Looper.
    private val persistedStructure = mutableMapOf<String, StoredNativePlaybackSession>()

    private fun currentTickerIntervalMs(): Long =
        if (isScreenInteractive()) intervalMs else screenOffIntervalMs

    private val ticker = object : Runnable {
        override fun run() {
            persistNow()
            if (!hasActivePlayback()) {
                tickerScheduled = false
                return
            }
            environment.postDelayed(this, currentTickerIntervalMs())
        }
    }

    private val debouncedPersist = Runnable {
        pendingDebounce = false
        persistNow()
    }

    fun ensureTicker() {
        if (tickerScheduled || !hasActivePlayback()) return
        tickerScheduled = true
        environment.postDelayed(ticker, currentTickerIntervalMs())
    }

    fun onScreenInteractiveChanged() {
        if (!tickerScheduled || !hasActivePlayback()) return
        environment.removeCallbacks(ticker)
        environment.postDelayed(ticker, currentTickerIntervalMs())
    }

    fun onPlaybackActivityChanged() {
        if (hasActivePlayback()) {
            ensureTicker()
            return
        }
        if (!tickerScheduled) return
        stopTicker()
        persistNow()
    }

    fun stopTicker() {
        if (!tickerScheduled) return
        environment.removeCallbacks(ticker)
        tickerScheduled = false
    }

    fun schedulePersist() {
        environment.removeCallbacks(debouncedPersist)
        pendingDebounce = true
        environment.postDelayed(debouncedPersist, debounceMs)
    }

    fun cancelScheduledPersist() {
        if (!pendingDebounce) return
        environment.removeCallbacks(debouncedPersist)
        pendingDebounce = false
    }

    fun persistNow() {
        cancelScheduledPersist()
        val snapshots = if (hasSessions()) storedSessions() else emptyList()
        val revisions = sessionRevisions()
        if (snapshots.isNotEmpty()) {
            environment.stageSessions(snapshots, revisions)
        }
        val saveGeneration = generation.incrementAndGet()
        environment.execute {
            if (saveGeneration != generation.get() || snapshots == lastSubmittedSnapshots) {
                return@execute
            }
            val previous = lastSubmittedSnapshots.orEmpty().associateBy { it.sessionId }
            val changed = snapshots.filter { previous[it.sessionId] != it }
            val progress = mutableListOf<StoredNativePlaybackSession>()
            val metadata = mutableListOf<StoredNativePlaybackSession>()
            val structure = mutableListOf<StoredNativePlaybackSession>()
            for (stored in changed) {
                val persisted = persistedStructure[stored.sessionId]
                when {
                    persisted != null &&
                        nativePlaybackSnapshotsDifferOnlyByProgress(listOf(persisted), listOf(stored)) ->
                        progress += stored
                    persisted != null &&
                        nativePlaybackSnapshotsDifferOnlyByMetadata(persisted, stored) ->
                        metadata += stored
                    else ->
                        structure += stored
                }
            }
            if (structure.isNotEmpty()) environment.saveSessions(structure, revisions)
            if (metadata.isNotEmpty()) environment.saveSessionMetadata(metadata, revisions)
            if (progress.isNotEmpty()) environment.saveSessionProgress(
                progress.map(StoredNativePlaybackSession::toStoredProgress), revisions
            )
            structure.forEach { persistedStructure[it.sessionId] = it }
            metadata.forEach { persistedStructure[it.sessionId] = it }
            lastSubmittedSnapshots = snapshots
        }
    }

    fun persistSession(session: StoredNativePlaybackSession, revision: Long) {
        generation.incrementAndGet()
        val revisions = mapOf(session.sessionId to revision)
        environment.stageSessions(listOf(session), revisions)
        environment.execute {
            val persisted = persistedStructure[session.sessionId]
            when {
                persisted != null &&
                    nativePlaybackSnapshotsDifferOnlyByProgress(listOf(persisted), listOf(session)) ->
                    environment.saveSessionProgress(listOf(session.toStoredProgress()), revisions)
                persisted != null &&
                    nativePlaybackSnapshotsDifferOnlyByMetadata(persisted, session) ->
                    environment.saveSessionMetadata(listOf(session), revisions)
                else ->
                    environment.saveSessions(listOf(session), revisions)
            }
            persistedStructure.remove(session.sessionId)
            lastSubmittedSnapshots = lastSubmittedSnapshots?.filterNot { it.sessionId == session.sessionId }
        }
    }

    fun removeSession(sessionId: String) {
        generation.incrementAndGet()
        val revision = NativePlaybackStateStore.invalidateSession(sessionId)
        environment.execute {
            environment.removeSession(sessionId, revision)
            persistedStructure.remove(sessionId)
            lastSubmittedSnapshots = lastSubmittedSnapshots?.filterNot { it.sessionId == sessionId }
        }
    }

    fun clearSessions() {
        generation.incrementAndGet()
        val revision = NativePlaybackStateStore.invalidateAllSessions()
        environment.execute {
            environment.clearSessions(revision)
            persistedStructure.clear()
            lastSubmittedSnapshots = null
        }
    }

    fun shutdown() {
        stopTicker()
        persistNow()
        environment.shutdown()
    }

    fun awaitPendingForTest(timeoutMs: Long = 10_000L): Boolean =
        environment.awaitTermination(timeoutMs)

    fun awaitTermination(timeoutMs: Long = 10_000L): Boolean =
        environment.awaitTermination(timeoutMs)
}
