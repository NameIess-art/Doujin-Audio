package com.doujin.audio.scanner

import com.doujin.audio.channel.*
import com.doujin.audio.storage.*

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
        Thread(runnable, "doujin-folder-scan").apply { isDaemon = true }
    }
) : EventChannel.StreamHandler {
    companion object {
        private const val progressIntervalMs = 160L
    }

    @Volatile
    private var sink: EventChannel.EventSink? = null
    @Volatile
    private var listenerGenerationId: String? = null
    private val cancellations = ConcurrentHashMap<String, AtomicBoolean>()
    private val taskGenerations = ConcurrentHashMap<String, String>()
    private val closed = AtomicBoolean(false)

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        val raw = arguments as? Map<*, *>
        listenerGenerationId = raw?.get("generationId") as? String
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        listenerGenerationId = null
        cancelAll()
    }

    @Synchronized
    fun startFolderScan(
        taskId: String,
        generationId: String,
        folder: String,
        chunkSize: Int
    ): Boolean {
        if (closed.get() || cancellations.isNotEmpty() || sink == null) return false
        if (listenerGenerationId != generationId) return false
        val safeChunkSize = chunkSize.coerceIn(20, 500)
        val cancelled = AtomicBoolean(false)
        if (cancellations.putIfAbsent(taskId, cancelled) != null) return false
        taskGenerations[taskId] = generationId

        return try {
            executor.execute {
                runFolderScan(taskId, generationId, folder, safeChunkSize, cancelled)
            }
            true
        } catch (_: RejectedExecutionException) {
            cancellations.remove(taskId)
            taskGenerations.remove(taskId)
            false
        }
    }

    fun cancelFolderScan(taskId: String) {
        cancellations[taskId]?.set(true)
    }

    fun <T> submitLegacyTask(
        block: () -> T,
        completion: (FileCacheTaskResult<T>) -> Unit
    ): Boolean {
        if (closed.get()) return false
        return try {
            executor.execute {
                val taskResult = try {
                    FileCacheTaskResult.Success(block())
                } catch (exception: Exception) {
                    FileCacheTaskResult.Failure(exception)
                }
                completion(taskResult)
            }
            true
        } catch (_: RejectedExecutionException) {
            false
        }
    }

    fun shutdown() {
        if (!closed.compareAndSet(false, true)) return
        cancelAll()
        sink = null
        listenerGenerationId = null
        executor.shutdownNow()
    }

    private fun runFolderScan(
        taskId: String,
        generationId: String,
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

        fun baseEvent(eventType: String): HashMap<String, Any?> = hashMapOf(
            "taskId" to taskId,
            "generationId" to generationId,
            "eventType" to eventType,
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
            send(taskId, generationId, cancelled, event)
            chunk.clear()
            paths.clear()
        }

        val observer = object : FolderScanObserver {
            override fun isCancelled(): Boolean = cancelled.get() || closed.get()

            override fun onStage(stage: String) {
                if (isCancelled() || stage == currentStage) return
                currentStage = stage
                send(taskId, generationId, cancelled, baseEvent("stageChanged"))
            }

            override fun onEntryProcessed(total: Int?) {
                if (isCancelled()) return
                processed++
                if (total != null) knownTotal = total
                val now = SystemClock.elapsedRealtime()
                if (now - lastProgressAt >= progressIntervalMs) {
                    lastProgressAt = now
                    send(taskId, generationId, cancelled, baseEvent("progress"))
                }
            }

            override fun onTrack(track: ScannedTrack) {
                if (isCancelled()) return
                chunk.add(track.toScanPayload())
                paths.add(track.path)
                if (chunk.size >= chunkSize) flushChunk()
            }
        }

        try {
            send(taskId, generationId, cancelled, baseEvent("started"))
            val scanResult = operations.scanFolder(folder, observer)
            if (cancelled.get() || closed.get()) {
                return
            }
            flushChunk()
            val event = baseEvent("completed")
            event["failureCount"] = scanResult.failureCount
            event["complete"] = scanResult.complete
            send(taskId, generationId, cancelled, event)
        } catch (error: Exception) {
            if (!cancelled.get() && !closed.get()) {
                val event = baseEvent("failed")
                event["errorCode"] = scanErrorCode(error)
                event["error"] = error.message ?: "unknown error"
                event["details"] = mapOf("exception" to error.javaClass.simpleName)
                event["failureCount"] = 1
                send(taskId, generationId, cancelled, event)
            }
        } finally {
            cancellations.remove(taskId, cancelled)
            taskGenerations.remove(taskId, generationId)
        }
    }

    private fun cancelAll() {
        cancellations.values.forEach { it.set(true) }
    }

    private fun send(
        taskId: String,
        generationId: String,
        cancelled: AtomicBoolean,
        event: HashMap<String, Any?>
    ) {
        if (!canPublish(taskId, generationId, cancelled)) return
        val scheduledSink = sink ?: return
        activity.runOnUiThread {
            if (shouldDeliverQueuedFolderScanEvent(
                    closed = closed.get(),
                    cancelled = cancelled.get(),
                    listenerGenerationId = listenerGenerationId,
                    eventGenerationId = generationId,
                    listenerStillCurrent = sink === scheduledSink
                )
            ) {
                scheduledSink.success(event)
            }
        }
    }

    private fun canPublish(
        taskId: String,
        generationId: String,
        cancelled: AtomicBoolean
    ): Boolean = !closed.get() &&
        !cancelled.get() &&
        cancellations[taskId] === cancelled &&
        taskGenerations[taskId] == generationId &&
        listenerGenerationId == generationId &&
        sink != null

    private fun scanErrorCode(error: Exception): String {
        return when (error) {
            is SecurityException -> "scan_permission_denied"
            is IllegalStateException -> "scan_provider_error"
            else -> "scan_unknown_error"
        }
    }
}

internal fun shouldDeliverQueuedFolderScanEvent(
    closed: Boolean,
    cancelled: Boolean,
    listenerGenerationId: String?,
    eventGenerationId: String,
    listenerStillCurrent: Boolean
): Boolean = !closed &&
    !cancelled &&
    listenerGenerationId == eventGenerationId &&
    listenerStillCurrent
