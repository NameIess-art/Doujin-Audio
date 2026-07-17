package com.nameless.audio.player.session

import android.content.Context
import android.os.Handler
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

internal interface NativePlaybackStatePersistenceEnvironment {
    fun postDelayed(runnable: Runnable, delayMs: Long)
    fun removeCallbacks(runnable: Runnable)
    fun execute(task: () -> Unit)
    fun saveSessions(sessions: List<StoredNativePlaybackSession>)
    fun clearSessions()
    fun shutdown()
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
    private val storedSessions: () -> List<StoredNativePlaybackSession>
) {
    constructor(
        context: Context,
        mainHandler: Handler,
        intervalMs: Long,
        debounceMs: Long,
        hasSessions: () -> Boolean,
        storedSessions: () -> List<StoredNativePlaybackSession>
    ) : this(
        environment = AndroidNativePlaybackStatePersistenceEnvironment(context, mainHandler),
        intervalMs = intervalMs,
        debounceMs = debounceMs,
        hasSessions = hasSessions,
        storedSessions = storedSessions
    )

    private val generation = AtomicLong(0L)
    private var tickerScheduled = false
    private var pendingDebounce = false

    private val ticker = object : Runnable {
        override fun run() {
            persistNow()
            if (!hasSessions()) {
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
        if (tickerScheduled || !hasSessions()) return
        tickerScheduled = true
        environment.postDelayed(ticker, intervalMs)
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
        val saveGeneration = generation.incrementAndGet()
        if (!hasSessions()) {
            environment.execute {
                if (saveGeneration == generation.get()) {
                    environment.clearSessions()
                }
            }
            return
        }

        val snapshots = storedSessions()
        environment.execute {
            if (saveGeneration == generation.get()) {
                environment.saveSessions(snapshots)
            }
        }
    }

    fun shutdown() {
        stopTicker()
        persistNow()
        environment.shutdown()
    }
}
