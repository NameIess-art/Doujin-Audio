package com.doujin.audio.player.session

import android.content.Context
import android.os.Handler
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

internal interface NativePlaybackStatePersistenceEnvironment {
    fun postDelayed(runnable: Runnable, delayMs: Long)
    fun removeCallbacks(runnable: Runnable)
    fun execute(task: () -> Unit)
    fun saveSessions(sessions: List<StoredNativePlaybackSession>, revisions: Map<String, Long>)
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

private class AndroidNativePlaybackStatePersistenceEnvironment(
    context: Context,
    private val mainHandler: Handler
) : NativePlaybackStatePersistenceEnvironment {
    private val appContext = context.applicationContext
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "NativePlaybackStateStore").apply { isDaemon = true }
    }

    override fun postDelayed(runnable: Runnable, delayMs: Long) {
        mainHandler.postDelayed(runnable, delayMs)
    }

    override fun removeCallbacks(runnable: Runnable) {
        mainHandler.removeCallbacks(runnable)
    }

    override fun execute(task: () -> Unit) {
        executor.execute {
            try {
                task()
            } catch (error: Exception) {
                Log.e("PlaybackRecovery", "Unable to persist playback state", error)
            }
        }
    }

    override fun stageSessions(sessions: List<StoredNativePlaybackSession>, revisions: Map<String, Long>) {
        NativePlaybackStateStore.stageSessions(sessions, revisions)
    }

    override fun saveSessions(sessions: List<StoredNativePlaybackSession>, revisions: Map<String, Long>) {
        NativePlaybackStateStore.upsertSessions(appContext, sessions, revisions)
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
        executor.shutdown()
    }

    override fun awaitTermination(timeoutMs: Long): Boolean =
        executor.awaitTermination(timeoutMs, TimeUnit.MILLISECONDS)
}

internal class NativePlaybackStatePersistenceCoordinator(
    private val environment: NativePlaybackStatePersistenceEnvironment,
    private val intervalMs: Long,
    private val debounceMs: Long,
    private val hasSessions: () -> Boolean,
    private val hasActivePlayback: () -> Boolean,
    private val storedSessions: () -> List<StoredNativePlaybackSession>,
    private val sessionRevisions: () -> Map<String, Long> = { emptyMap() }
) {
    constructor(
        context: Context,
        mainHandler: Handler,
        intervalMs: Long,
        debounceMs: Long,
        hasSessions: () -> Boolean,
        hasActivePlayback: () -> Boolean,
        storedSessions: () -> List<StoredNativePlaybackSession>,
        sessionRevisions: () -> Map<String, Long>
    ) : this(
        environment = AndroidNativePlaybackStatePersistenceEnvironment(context, mainHandler),
        intervalMs = intervalMs,
        debounceMs = debounceMs,
        hasSessions = hasSessions,
        hasActivePlayback = hasActivePlayback,
        storedSessions = storedSessions,
        sessionRevisions = sessionRevisions
    )

    private val generation = AtomicLong(0L)
    private var tickerScheduled = false
    private var pendingDebounce = false
    private var lastSubmittedSnapshots: List<StoredNativePlaybackSession>? = null

    // Both caches are accessed only on the storage executor. Queue equality and
    // serialization must not run on the player's application Looper.
    private val persistedStructure = mutableMapOf<String, StoredNativePlaybackSession>()

    private val ticker = object : Runnable {
        override fun run() {
            persistNow()
            if (!hasActivePlayback()) {
                tickerScheduled = false
                return
            }
            environment.postDelayed(this, intervalMs)
        }
    }

    private val debouncedPersist = Runnable {
        pendingDebounce = false
        persistNow()
    }

    fun ensureTicker() {
        if (tickerScheduled || !hasActivePlayback()) return
        tickerScheduled = true
        environment.postDelayed(ticker, intervalMs)
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
            val (progress, structure) = changed.partition { stored ->
                persistedStructure[stored.sessionId]?.let {
                    nativePlaybackSnapshotsDifferOnlyByProgress(listOf(it), listOf(stored))
                } == true
            }
            if (structure.isNotEmpty()) environment.saveSessions(structure, revisions)
            if (progress.isNotEmpty()) environment.saveSessionProgress(
                progress.map(StoredNativePlaybackSession::toStoredProgress), revisions)
            structure.forEach { persistedStructure[it.sessionId] = it }
            lastSubmittedSnapshots = snapshots
        }
    }

    fun persistSession(session: StoredNativePlaybackSession, revision: Long) {
        environment.stageSessions(listOf(session), mapOf(session.sessionId to revision))
        environment.execute {
            environment.saveSessions(listOf(session), mapOf(session.sessionId to revision))
            persistedStructure.remove(session.sessionId)
            lastSubmittedSnapshots = lastSubmittedSnapshots?.filterNot { it.sessionId == session.sessionId }
        }
    }

    fun removeSession(sessionId: String) {
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

    fun awaitTermination(timeoutMs: Long = 10_000L): Boolean =
        environment.awaitTermination(timeoutMs)
}
