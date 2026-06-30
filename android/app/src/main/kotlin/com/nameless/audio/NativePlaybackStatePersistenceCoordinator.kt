package com.nameless.audio

import android.content.Context
import android.os.Handler
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

internal class NativePlaybackStatePersistenceCoordinator(
    context: Context,
    private val mainHandler: Handler,
    private val intervalMs: Long,
    private val debounceMs: Long,
    private val hasSessions: () -> Boolean,
    private val storedSessions: () -> List<StoredNativePlaybackSession>
) {
    private val appContext = context.applicationContext
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "NativePlaybackStateStore").apply { isDaemon = true }
    }
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
            mainHandler.postDelayed(this, intervalMs)
        }
    }

    private val debouncedPersist = Runnable {
        pendingDebounce = false
        persistNow()
    }

    fun ensureTicker() {
        if (tickerScheduled || !hasSessions()) return
        tickerScheduled = true
        mainHandler.postDelayed(ticker, intervalMs)
    }

    fun stopTicker() {
        if (!tickerScheduled) return
        mainHandler.removeCallbacks(ticker)
        tickerScheduled = false
    }

    fun schedulePersist() {
        mainHandler.removeCallbacks(debouncedPersist)
        pendingDebounce = true
        mainHandler.postDelayed(debouncedPersist, debounceMs)
    }

    fun cancelScheduledPersist() {
        if (!pendingDebounce) return
        mainHandler.removeCallbacks(debouncedPersist)
        pendingDebounce = false
    }

    fun persistNow() {
        cancelScheduledPersist()
        val saveGeneration = generation.incrementAndGet()
        if (!hasSessions()) {
            executor.execute {
                if (saveGeneration == generation.get()) {
                    NativePlaybackStateStore.clearSessions(appContext)
                }
            }
            return
        }

        val snapshots = storedSessions()
        executor.execute {
            if (saveGeneration == generation.get()) {
                NativePlaybackStateStore.saveSessions(appContext, snapshots)
            }
        }
    }

    fun shutdown() {
        stopTicker()
        cancelScheduledPersist()
        executor.shutdown()
    }
}
