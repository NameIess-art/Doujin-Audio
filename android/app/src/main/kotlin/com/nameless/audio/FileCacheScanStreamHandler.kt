package com.nameless.audio

import android.app.Activity
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

internal class FileCacheScanStreamHandler(
    private val activity: Activity,
    private val operations: FileCacheOperations,
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "nameless-folder-scan").apply { isDaemon = true }
    }
) : EventChannel.StreamHandler {
    companion object {
        private const val progressIntervalMs = 160L
    }

    @Volatile
    private var sink: EventChannel.EventSink? = null
    private val cancellations = ConcurrentHashMap<String, AtomicBoolean>()
    private val closed = AtomicBoolean(false)

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        cancelAll()
    }

    @Synchronized
    fun startFolderScan(sessionId: String, folder: String, chunkSize: Int): Boolean {
        if (closed.get() || cancellations.isNotEmpty()) return false
        val safeChunkSize = chunkSize.coerceIn(20, 500)
        val cancelled = AtomicBoolean(false)
        if (cancellations.putIfAbsent(sessionId, cancelled) != null) return false

        return try {
            executor.execute {
                runFolderScan(sessionId, folder, safeChunkSize, cancelled)
            }
            true
        } catch (_: RejectedExecutionException) {
            cancellations.remove(sessionId)
            false
        }
    }

    fun cancelFolderScan(sessionId: String) {
        cancellations[sessionId]?.set(true)
    }

    fun shutdown() {
        if (!closed.compareAndSet(false, true)) return
        cancelAll()
        sink = null
        executor.shutdownNow()
    }

    private fun runFolderScan(
        sessionId: String,
        folder: String,
        chunkSize: Int,
        cancelled: AtomicBoolean
    ) {
        val chunk = ArrayList<HashMap<String, Any?>>(chunkSize)
        val paths = ArrayList<String>(chunkSize)
        var processed = 0
        var knownTotal: Int? = null
        var lastProgressAt = 0L
        var currentStage = "preparing"

        fun baseEvent(type: String): HashMap<String, Any?> = hashMapOf(
            "sessionId" to sessionId,
            "generationId" to sessionId,
            "type" to type,
            "stage" to currentStage,
            "processed" to processed,
            "total" to knownTotal,
            "tracks" to emptyList<HashMap<String, Any?>>(),
            "paths" to emptyList<String>(),
            "folders" to emptyList<String>(),
            "failureCount" to 0,
            "complete" to false
        )

        fun flushChunk() {
            if (chunk.isEmpty() || cancelled.get()) return
            val event = baseEvent("chunk")
            event["tracks"] = ArrayList(chunk)
            event["paths"] = ArrayList(paths)
            send(event)
            chunk.clear()
            paths.clear()
        }

        val observer = object : FolderScanObserver {
            override fun isCancelled(): Boolean = cancelled.get() || closed.get()

            override fun onStage(stage: String) {
                if (isCancelled() || stage == currentStage) return
                currentStage = stage
                send(baseEvent("stageChanged"))
            }

            override fun onEntryProcessed(total: Int?) {
                if (isCancelled()) return
                processed++
                if (total != null) knownTotal = total
                val now = SystemClock.elapsedRealtime()
                if (now - lastProgressAt >= progressIntervalMs) {
                    lastProgressAt = now
                    send(baseEvent("progress"))
                }
            }

            override fun onTrack(track: FileCacheOperations.ScannedTrack) {
                if (isCancelled()) return
                chunk.add(track.toScanPayload())
                paths.add(track.path)
                if (chunk.size >= chunkSize) flushChunk()
            }
        }

        try {
            send(baseEvent("started"))
            val scanResult = operations.scanFolder(folder, observer)
            if (cancelled.get() || closed.get()) {
                send(baseEvent("cancelled"))
                return
            }
            flushChunk()
            val event = baseEvent("completed")
            event["failureCount"] = scanResult.failureCount
            event["complete"] = scanResult.complete
            send(event)
        } catch (error: Exception) {
            if (cancelled.get() || closed.get()) {
                send(baseEvent("cancelled"))
            } else {
                val event = baseEvent("failed")
                event["code"] = scanErrorCode(error)
                event["message"] = error.message ?: "unknown error"
                event["failureCount"] = 1
                send(event)
            }
        } finally {
            cancellations.remove(sessionId, cancelled)
        }
    }

    private fun cancelAll() {
        cancellations.values.forEach { it.set(true) }
    }

    private fun send(event: HashMap<String, Any?>) {
        activity.runOnUiThread {
            sink?.success(event)
        }
    }

    private fun scanErrorCode(error: Exception): String {
        return when (error) {
            is SecurityException -> "scan_permission_denied"
            is IllegalStateException -> "scan_provider_error"
            else -> "scan_unknown_error"
        }
    }
}
