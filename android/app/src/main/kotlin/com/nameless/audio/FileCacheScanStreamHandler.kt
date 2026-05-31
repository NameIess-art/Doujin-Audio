package com.nameless.audio

import android.app.Activity
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

internal class FileCacheScanStreamHandler(
    private val activity: Activity,
    private val operations: FileCacheOperations
) : EventChannel.StreamHandler {
    private var sink: EventChannel.EventSink? = null
    private val cancellations = ConcurrentHashMap<String, AtomicBoolean>()

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        cancellations.clear()
    }

    fun startFolderScan(sessionId: String, folder: String, chunkSize: Int) {
        val safeChunkSize = chunkSize.coerceIn(20, 500)
        val cancelled = AtomicBoolean(false)
        cancellations[sessionId] = cancelled

        Thread {
            try {
                val tracks = operations.scanFolder(folder)
                for (start in tracks.indices step safeChunkSize) {
                    if (cancelled.get()) return@Thread
                    val end = minOf(start + safeChunkSize, tracks.size)
                    val chunk = ArrayList<HashMap<String, Any?>>(end - start)
                    val paths = ArrayList<String>(end - start)
                    for (index in start until end) {
                        val track = tracks[index]
                        chunk.add(track.toScanPayload())
                        paths.add(track.path)
                    }
                    send(
                        hashMapOf(
                            "sessionId" to sessionId,
                            "type" to "chunk",
                            "tracks" to chunk,
                            "paths" to paths,
                            "folders" to emptyList<String>(),
                            "failureCount" to 0
                        )
                    )
                }
                if (!cancelled.get()) {
                    send(
                        hashMapOf(
                            "sessionId" to sessionId,
                            "type" to "done",
                            "tracks" to emptyList<HashMap<String, Any?>>(),
                            "paths" to emptyList<String>(),
                            "folders" to emptyList<String>(),
                            "failureCount" to 0
                        )
                    )
                }
            } catch (e: Exception) {
                if (!cancelled.get()) {
                    send(
                        hashMapOf(
                            "sessionId" to sessionId,
                            "type" to "error",
                            "code" to scanErrorCode(e),
                            "message" to (e.message ?: "unknown error"),
                            "tracks" to emptyList<HashMap<String, Any?>>(),
                            "paths" to emptyList<String>(),
                            "folders" to emptyList<String>(),
                            "failureCount" to 1
                        )
                    )
                }
            } finally {
                cancellations.remove(sessionId)
            }
        }.start()
    }

    fun cancelFolderScan(sessionId: String) {
        cancellations[sessionId]?.set(true)
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

