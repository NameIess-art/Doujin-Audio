package com.doujin.audio.player.session

import android.content.Context
import android.os.Handler
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

internal interface NativePlaybackStatePersistenceEnvironment {
    fun postDelayed(runnable: Runnable, delayMs: Long)
    fun removeCallbacks(runnable: Runnable)
    fun execute(task: () -> Unit)
    fun saveSessions(sessions: List<StoredNativePlaybackSession>)
    fun saveSessionProgress(progress: List<StoredNativePlaybackProgress>)
    fun clearSessions()
    fun shutdown()
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
        executor.execute { task() }
    }

    override fun saveSessions(sessions: List<StoredNativePlaybackSession>) {
        NativePlaybackStateStore.saveSessions(appContext, sessions)
    }

    override fun saveSessionProgress(progress: List<StoredNativePlaybackProgress>) {
        NativePlaybackStateStore.saveSessionProgress(appContext, progress)
    }

    override fun clearSessions() {
        NativePlaybackStateStore.clearSessions(appContext)
    }

    override fun shutdown() {
        executor.shutdown()
    }
}

internal class NativePlaybackStatePersistenceCoordinator(
    private val environment: NativePlaybackStatePersistenceEnvironment,
    private val intervalMs: Long,
    private val debounceMs: Long,
    private val hasSessions: () -> Boolean,
    private val hasActivePlayback: () -> Boolean,
    private val storedSessions: () -> List<StoredNativePlaybackSession>
) {
    constructor(
        context: Context,
        mainHandler: Handler,
        intervalMs: Long,
        debounceMs: Long,
        hasSessions: () -> Boolean,
        hasActivePlayback: () -> Boolean,
        storedSessions: () -> List<StoredNativePlaybackSession>
    ) : this(
        environment = AndroidNativePlaybackStatePersistenceEnvironment(context, mainHandler),
        intervalMs = intervalMs,
        debounceMs = debounceMs,
        hasSessions = hasSessions,
        hasActivePlayback = hasActivePlayback,
        storedSessions = storedSessions
    )

    private val generation = AtomicLong(0L)
    private var tickerScheduled = false
    private var pendingDebounce = false
    private var lastSubmittedSnapshots: List<StoredNativePlaybackSession>? = null

    // Both caches are accessed only on the storage executor. Queue equality and
    // serialization must not run on the player's application Looper.
    private var persistedStructure: List<StoredNativePlaybackSession>? = null

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
        val saveGeneration = generation.incrementAndGet()
        environment.execute {
            if (saveGeneration != generation.get() || snapshots == lastSubmittedSnapshots) {
                return@execute
            }
            if (snapshots.isEmpty()) {
                environment.clearSessions()
                persistedStructure = null
            } else if (persistedStructure?.let {
                    nativePlaybackSnapshotsDifferOnlyByProgress(it, snapshots)
                } == true
            ) {
                environment.saveSessionProgress(snapshots.map(StoredNativePlaybackSession::toStoredProgress))
            } else {
                environment.saveSessions(snapshots)
                persistedStructure = snapshots
            }
            lastSubmittedSnapshots = snapshots
        }
    }

    fun shutdown() {
        stopTicker()
        persistNow()
        environment.shutdown()
    }
}
