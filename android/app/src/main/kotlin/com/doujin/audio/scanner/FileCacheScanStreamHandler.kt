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
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

internal class FileCacheScanStreamHandler(
    private val activity: Activity,
    private val operations: FileCacheOperations,
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "doujin-folder-scan").apply { isDaemon = true }
    },
    private val chunkAckTimeoutMs: Long = FolderScanTask.DEFAULT_ACK_TIMEOUT_MS
) : EventChannel.StreamHandler {
    companion object {
        private const val progressIntervalMs = 160L
    }

    @Volatile
    private var sink: EventChannel.EventSink? = null
    @Volatile
    private var listenerGenerationId: String? = null
    private val tasks = ConcurrentHashMap<String, FolderScanTask>()
    private val closed = AtomicBoolean(false)

    @Synchronized
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        cancelAll()
        val raw = arguments as? Map<*, *>
        listenerGenerationId = raw?.get("generationId") as? String
        sink = events
    }

    @Synchronized
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
        if (closed.get() || tasks.isNotEmpty() || sink == null) return false
        if (listenerGenerationId != generationId) return false
        val safeChunkSize = chunkSize.coerceIn(20, 500)
        val task = FolderScanTask(generationId, ackTimeoutMs = chunkAckTimeoutMs)
        if (tasks.putIfAbsent(taskId, task) != null) return false

        return try {
            executor.execute {
                runFolderScan(taskId, generationId, folder, safeChunkSize, task)
            }
            true
        } catch (_: RejectedExecutionException) {
            tasks.remove(taskId, task)
            false
        }
    }

    @Synchronized
    fun cancelFolderScan(taskId: String) {
        tasks.remove(taskId)?.cancel()
    }

    fun acknowledgeFolderScanChunk(taskId: String, chunkSequence: Long): Boolean =
        tasks[taskId]?.acknowledgeChunk(chunkSequence) == true

    fun <T> submitLegacyTask(
        block: () -> T,
        completion: (FileCacheTaskResult<T>) -> Unit
    ): Boolean {
        if (closed.get()) return false
        return try {
            executor.execute {
                val taskResult = try {
                    FileCacheTaskResult.Success(block())
                } catch (throwable: Throwable) {
                    fileCacheTaskFailure(throwable)
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
        task: FolderScanTask
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
            if (chunk.isEmpty() || task.cancelled) return
            val sequence = task.beginChunk() ?: return
            val event = baseEvent("chunk")
            event["chunkSequence"] = sequence
            event["tracks"] = ArrayList(chunk)
            event["paths"] = ArrayList(paths)
            send(taskId, generationId, task, event)
            chunk.clear()
            paths.clear()
            // The worker waits for Dart to finish merging, so platform messages
            // cannot grow into an unbounded backlog on the UI isolate.
            if (!task.awaitChunkAcknowledgement() && task.timedOut) {
                val timeoutEvent = baseEvent("failed")
                timeoutEvent["errorCode"] = "scan_ack_timeout"
                timeoutEvent["error"] = "Timed out waiting for scan chunk acknowledgement."
                timeoutEvent["details"] = mapOf("chunkSequence" to sequence)
                timeoutEvent["failureCount"] = 1
                send(taskId, generationId, task, timeoutEvent, allowWhenTimedOut = true)
            }
        }

        val observer = object : FolderScanObserver {
            override fun isCancelled(): Boolean = task.cancelled || closed.get()

            override fun onStage(stage: String) {
                if (isCancelled() || stage == currentStage) return
                currentStage = stage
                send(taskId, generationId, task, baseEvent("stageChanged"))
            }

            override fun onEntryProcessed(total: Int?) {
                if (isCancelled()) return
                processed++
                if (total != null) knownTotal = total
                val now = SystemClock.elapsedRealtime()
                if (now - lastProgressAt >= progressIntervalMs) {
                    lastProgressAt = now
                    send(taskId, generationId, task, baseEvent("progress"))
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
            send(taskId, generationId, task, baseEvent("started"))
            val scanResult = operations.scanFolder(
                folder,
                observer,
                collectTracks = false
            )
            if (task.cancelled || closed.get()) {
                return
            }
            flushChunk()
            if (task.cancelled || closed.get()) return
            val event = baseEvent("completed")
            event["failureCount"] = scanResult.failureCount
            event["complete"] = scanResult.complete
            send(taskId, generationId, task, event)
        } catch (error: Exception) {
            if (!task.cancelled && !closed.get()) {
                val event = baseEvent("failed")
                event["errorCode"] = scanErrorCode(error)
                event["error"] = error.message ?: "unknown error"
                event["details"] = mapOf("exception" to error.javaClass.simpleName)
                event["failureCount"] = 1
                send(taskId, generationId, task, event)
            }
        } finally {
            tasks.remove(taskId, task)
        }
    }

    @Synchronized
    private fun cancelAll() {
        val activeTasks = tasks.values.toList()
        tasks.clear()
        activeTasks.forEach { it.cancel() }
    }

    private fun send(
        taskId: String,
        generationId: String,
        task: FolderScanTask,
        event: HashMap<String, Any?>,
        allowWhenTimedOut: Boolean = false
    ) {
        if (isActivityUnavailable() || !canPublish(taskId, generationId, task, allowWhenTimedOut)) {
            task.cancel()
            return
        }
        val scheduledSink = sink ?: run {
            task.cancel()
            return
        }
        try {
            activity.runOnUiThread {
                if (isActivityUnavailable()) {
                    task.cancel()
                    return@runOnUiThread
                }
                if (shouldDeliverQueuedFolderScanEvent(
                        closed = closed.get(),
                        cancelled = task.cancelled && !(allowWhenTimedOut && task.timedOut),
                        listenerGenerationId = listenerGenerationId,
                        eventGenerationId = generationId,
                        listenerStillCurrent = sink === scheduledSink
                    )
                ) {
                    try {
                        scheduledSink.success(event)
                    } catch (_: Exception) {
                        task.cancel()
                    }
                } else {
                    task.cancel()
                }
            }
        } catch (_: Exception) {
            task.cancel()
        }
    }

    private fun isActivityUnavailable(): Boolean = activity.isFinishing || activity.isDestroyed

    private fun canPublish(
        taskId: String,
        generationId: String,
        task: FolderScanTask,
        allowWhenTimedOut: Boolean = false
    ): Boolean = !closed.get() &&
        (!task.cancelled || (allowWhenTimedOut && task.timedOut)) &&
        tasks[taskId] === task &&
        task.generationId == generationId &&
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

internal class FolderScanTask(
    val generationId: String,
    private val ackTimeoutMs: Long = DEFAULT_ACK_TIMEOUT_MS
) {
    companion object {
        internal const val DEFAULT_ACK_TIMEOUT_MS = 30_000L
    }

    private val lock = ReentrantLock()
    private val acknowledged = lock.newCondition()
    private var chunkSequence = 0L
    private var pendingSequence: Long? = null

    @Volatile
    var cancelled = false
        private set

    @Volatile
    var timedOut = false
        private set

    fun beginChunk(): Long? = lock.withLock {
        if (cancelled) return null
        check(pendingSequence == null) { "Previous scan chunk has not been acknowledged" }
        (++chunkSequence).also { pendingSequence = it }
    }

    fun awaitChunkAcknowledgement(timeoutMs: Long = ackTimeoutMs): Boolean = lock.withLock {
        val safeTimeoutMs = timeoutMs.coerceAtLeast(1L)
        val deadlineNs = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(safeTimeoutMs)
        while (pendingSequence != null && !cancelled) {
            val remainingNs = deadlineNs - System.nanoTime()
            if (remainingNs <= 0L) {
                timedOut = true
                cancelled = true
                acknowledged.signalAll()
                return false
            }
            val waitMs = (remainingNs + 999_999L) / 1_000_000L
            if (!acknowledged.await(waitMs, TimeUnit.MILLISECONDS) &&
                pendingSequence != null &&
                !cancelled &&
                System.nanoTime() >= deadlineNs
            ) {
                timedOut = true
                cancelled = true
                acknowledged.signalAll()
                return false
            }
        }
        !timedOut && !cancelled
    }

    fun acknowledgeChunk(sequence: Long): Boolean = lock.withLock {
        if (cancelled || pendingSequence != sequence) return false
        pendingSequence = null
        acknowledged.signalAll()
        true
    }

    fun cancel() = lock.withLock {
        cancelled = true
        acknowledged.signalAll()
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
