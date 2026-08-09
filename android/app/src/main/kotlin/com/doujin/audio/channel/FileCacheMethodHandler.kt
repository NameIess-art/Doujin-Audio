package com.doujin.audio.channel

import com.doujin.audio.scanner.*
import com.doujin.audio.storage.*

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

internal sealed interface FileCacheTaskResult<out T> {
    data class Success<T>(val value: T) : FileCacheTaskResult<T>
    data class Failure(val exception: Exception) : FileCacheTaskResult<Nothing>
}

internal class FileCacheTaskExecutor {
    private val closed = AtomicBoolean(false)
    private val threadIndex = AtomicInteger()
    private val executor = Executors.newFixedThreadPool(2) { runnable ->
        Thread(
            runnable,
            "doujin-file-task-${threadIndex.incrementAndGet()}"
        ).apply { isDaemon = true }
    }

    fun <T> submit(
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

    fun shutdownNow() {
        if (closed.compareAndSet(false, true)) {
            executor.shutdownNow()
        }
    }
}

internal class FileCacheMethodHandler(
    private val operations: FileCacheOperations,
    private val scanStreamHandler: FileCacheScanStreamHandler,
    private val taskExecutor: FileCacheTaskExecutor,
    private val launchExportFile: (
        String,
        String,
        String,
        MethodChannel.Result
    ) -> Unit,
    private val launchPickAudioSource: (MethodChannel.Result) -> Unit,
    private val launchPickAudioFiles: (MethodChannel.Result) -> Unit,
    private val launchPickAudioFolder: (MethodChannel.Result) -> Unit
) : MethodChannel.MethodCallHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val closed = AtomicBoolean(false)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val envelopeResult = ChannelEnvelopeResult(result)
        try {
            handleMethodCall(call, call.argumentReader(), envelopeResult)
        } catch (exception: IllegalArgumentException) {
            envelopeResult.error(
                ChannelErrorCodes.INVALID_ARGUMENT,
                exception.message ?: "Invalid channel arguments",
                mapOf("method" to call.method)
            )
        }
    }

    private fun handleMethodCall(
        call: MethodCall,
        arguments: ChannelArgumentReader,
        result: MethodChannel.Result
    ) {
        when (call.method) {
            FileCacheMethods.CACHE_FROM_URI -> {
                val uriString = arguments.requiredString("uri")
                val name = arguments.requiredString("name")
                val index = arguments.requiredInt("index")
                runAsync(
                    result = result,
                    errorCode = { e ->
                        if (e is IllegalStateException) "open_failed" else "cache_failed"
                    }
                ) {
                    operations.cacheFromUri(uriString, name, index)
                }
            }
            FileCacheMethods.CLEAR_APPLICATION_CACHE -> runAsync(result) {
                operations.clearApplicationCache()
            }
            FileCacheMethods.SET_APPLICATION_CACHE_LIMIT -> {
                val maxBytes = arguments.requiredLong("maxBytes")
                operations.setMaxApplicationCacheBytes(maxBytes)
                runAsync(result) {
                    operations.enforceApplicationCacheLimit(maxBytes)
                    null
                }
            }
            FileCacheMethods.ENFORCE_APPLICATION_CACHE_LIMIT -> {
                val maxBytes = arguments.requiredLong("maxBytes")
                runAsync(result) {
                    operations.enforceApplicationCacheLimit(maxBytes)
                    null
                }
            }
            FileCacheMethods.GET_STORAGE_USAGE -> runAsync(
                result,
                errorCode = { "storage_usage_failed" }
            ) {
                operations.storageUsage()
            }
            FileCacheMethods.SCAN_FOLDER -> {
                val folder = arguments.requiredString("folder")
                runScanAsync(
                    result = result,
                    errorCode = { e ->
                        when (e) {
                            is SecurityException -> "scan_permission_denied"
                            is IllegalStateException -> "scan_provider_error"
                            else -> "scan_unknown_error"
                        }
                    }
                ) {
                    val tracks = operations.scanFolder(folder).tracks
                    val payload = ArrayList<HashMap<String, Any?>>(tracks.size)
                    for (track in tracks) {
                        payload.add(track.toScanPayload())
                    }
                    payload
                }
            }
            FileCacheMethods.START_FOLDER_SCAN -> {
                val taskId = arguments.requiredString("taskId")
                val generationId = arguments.requiredString("generationId")
                val folder = arguments.requiredString("folder")
                val chunkSize = arguments.requiredInt("chunkSize")
                result.success(
                    scanStreamHandler.startFolderScan(taskId, generationId, folder, chunkSize)
                )
            }
            FileCacheMethods.CANCEL_FOLDER_SCAN -> {
                val taskId = arguments.requiredString("taskId")
                scanStreamHandler.cancelFolderScan(taskId)
                result.success(true)
            }
            FileCacheMethods.LIST_CHILD_FOLDERS -> {
                val folder = arguments.requiredString("folder")
                runAsync(result, errorCode = { "list_child_folders_failed" }) {
                    operations.listChildFolders(folder)
                }
            }
            FileCacheMethods.RENAME_DOCUMENT -> {
                val targetPath = arguments.requiredString("path")
                val name = arguments.requiredString("name")
                runAsync(
                    result = result,
                    errorCode = { e ->
                        if (e is SecurityException) "rename_permission_denied" else "rename_failed"
                    }
                ) {
                    operations.renameDocumentTarget(targetPath, name)
                }
            }
            FileCacheMethods.READ_JSON_DOCUMENT -> {
                val locationKind = arguments.requiredString("locationKind")
                val basePath = arguments.requiredString("basePath")
                val name = arguments.requiredString("name")
                runAsync(result, errorCode = { "json_document_read_failed" }) {
                    operations.readJsonDocument(locationKind, basePath, name)
                }
            }
            FileCacheMethods.RECONCILE_PERSISTED_URI_PERMISSIONS -> {
                val retainedUris = arguments.requiredList("retainedUris")
                    .mapIndexed { index, value ->
                        (value as? String)?.trim()?.takeIf(String::isNotEmpty)
                            ?: throw IllegalArgumentException(
                                "Invalid retainedUris item at index $index"
                            )
                    }
                    .toSet()
                runAsync(result, errorCode = { "uri_permission_reconcile_failed" }) {
                    operations.reconcilePersistedUriPermissions(retainedUris)
                }
            }
            FileCacheMethods.WRITE_JSON_DOCUMENT -> {
                val locationKind = arguments.requiredString("locationKind")
                val basePath = arguments.requiredString("basePath")
                val name = arguments.requiredString("name")
                val bytes = arguments.requiredByteArray("bytes")
                val mode = arguments.requiredString("mode")
                val expectedRevision = arguments.optionalString("expectedRevision")
                runAsync(result, errorCode = { "json_document_write_failed" }) {
                    operations.writeJsonDocument(
                        locationKind,
                        basePath,
                        name,
                        bytes,
                        mode,
                        expectedRevision
                    )
                }
            }
            FileCacheMethods.DELETE_JSON_DOCUMENT -> {
                val locationKind = arguments.requiredString("locationKind")
                val basePath = arguments.requiredString("basePath")
                val name = arguments.requiredString("name")
                val expectedRevision = arguments.requiredString("expectedRevision")
                runAsync(result, errorCode = { "json_document_delete_failed" }) {
                    operations.deleteJsonDocument(
                        locationKind,
                        basePath,
                        name,
                        expectedRevision
                    )
                }
            }
            FileCacheMethods.WRITE_FILE_BYTES_TO_FOLDER -> {
                val folder = arguments.requiredString("folder")
                val name = arguments.requiredString("name")
                val bytes = arguments.requiredByteArray("bytes")
                val mimeType = arguments.optionalString("mimeType")
                runAsync(result, errorCode = { "folder_file_write_failed" }) {
                    operations.writeFileBytesToFolder(folder, name, bytes, mimeType)
                }
            }
            FileCacheMethods.DOCUMENT_PATH_EXISTS -> {
                val targetPath = arguments.requiredString("path")
                runAsync(result, errorCode = { "document_path_exists_failed" }) {
                    operations.documentPathExists(targetPath)
                }
            }
            FileCacheMethods.RESOLVE_DOCUMENT_FILE_SYSTEM_PATH -> {
                val targetPath = arguments.requiredString("path")
                runAsync(result, errorCode = { "document_path_resolve_failed" }) {
                    operations.resolveDocumentFileSystemPath(targetPath)
                }
            }
            FileCacheMethods.ENSURE_FOLDER_PATH -> {
                val folder = arguments.requiredString("folder")
                val relativePath = arguments.requiredString("relativePath", allowBlank = true)
                val overwrite = arguments.requiredBoolean("overwrite")
                runAsync(result, errorCode = { "ensure_folder_failed" }) {
                    operations.ensureFolderPath(folder, relativePath, overwrite)
                }
            }
            FileCacheMethods.EXPORT_FILE -> {
                val sourcePath = arguments.requiredString("sourcePath")
                val fileName = arguments.requiredString("fileName")
                val mimeType = arguments.requiredString("mimeType")
                launchExportFile(sourcePath, fileName, mimeType, result)
            }
            FileCacheMethods.COPY_FILE_TO_FOLDER -> {
                val sourcePath = arguments.requiredString("sourcePath")
                val folder = arguments.requiredString("folder")
                val relativePath = arguments.requiredString("relativePath")
                val overwrite = arguments.requiredBoolean("overwrite")
                runAsync(result, errorCode = { "copy_file_failed" }) {
                    operations.copyFileToFolder(sourcePath, folder, relativePath, overwrite)
                }
            }
            FileCacheMethods.DELETE_DOCUMENT_PATH -> {
                val targetPath = arguments.requiredString("path")
                runAsync(result, errorCode = { "delete_document_failed" }) {
                    operations.deleteDocumentPath(targetPath)
                }
            }
            FileCacheMethods.RESOLVE_TRACK_COVER -> {
                val trackPath = arguments.requiredString("path")
                val groupKey = arguments.optionalString("groupKey")
                val rootFolder = arguments.optionalString("rootFolder")
                runAsync(result, errorCode = { "cover_resolve_failed" }) {
                    operations.resolveTrackCover(trackPath, groupKey, rootFolder)
                }
            }
            FileCacheMethods.RESOLVE_VIDEO_FRAME -> {
                val trackPath = arguments.requiredString("path")
                val modifiedAtMs = arguments.optionalLong("modifiedAtMs")
                runAsync(result, errorCode = { "video_frame_resolve_failed" }) {
                    operations.resolveVideoFrame(trackPath, modifiedAtMs)
                }
            }
            FileCacheMethods.RESOLVE_MEDIA_DURATION -> {
                val trackPath = arguments.requiredString("path")
                runAsync(result, errorCode = { "media_duration_resolve_failed" }) {
                    operations.resolveMediaDurationMs(trackPath)
                }
            }
            FileCacheMethods.DISCOVER_ROOT_IMAGES -> {
                val trackPath = arguments.requiredString("path")
                val groupKey = arguments.optionalString("groupKey")
                val rootFolder = arguments.optionalString("rootFolder")
                val recursive = arguments.optionalBoolean("recursive", true)
                runAsync(result, errorCode = { "cover_discover_failed" }) {
                    operations.discoverRootImages(trackPath, groupKey, rootFolder, recursive)
                }
            }
            FileCacheMethods.RESOLVE_TRACK_SUBTITLE -> {
                val trackPath = arguments.requiredString("path")
                val groupKey = arguments.optionalString("groupKey")
                runAsync(result, errorCode = { "subtitle_resolve_failed" }) {
                    operations.resolveTrackSubtitle(trackPath, groupKey)
                }
            }
            FileCacheMethods.PICK_AUDIO_SOURCE -> launchPickAudioSource(result)
            FileCacheMethods.PICK_AUDIO_FILES -> launchPickAudioFiles(result)
            FileCacheMethods.PICK_AUDIO_FOLDER -> launchPickAudioFolder(result)
            else -> result.notImplemented()
        }
    }

    private fun runAsync(
        result: MethodChannel.Result,
        errorCode: (Exception) -> String = { "operation_failed" },
        block: () -> Any?
    ) {
        if (closed.get()) {
            result.error("operation_failed", "file operations are unavailable", null)
            return
        }
        val accepted = taskExecutor.submit(block) { taskResult ->
            deliver(result, errorCode, taskResult)
        }
        if (!accepted) {
            result.error("operation_failed", "file operations are unavailable", null)
        }
    }

    private fun runScanAsync(
        result: MethodChannel.Result,
        errorCode: (Exception) -> String,
        block: () -> Any?
    ) {
        if (closed.get()) {
            result.error("operation_failed", "file operations are unavailable", null)
            return
        }
        val accepted = scanStreamHandler.submitLegacyTask(block) { taskResult ->
            deliver(result, errorCode, taskResult)
        }
        if (!accepted) {
            result.error("operation_failed", "file operations are unavailable", null)
        }
    }

    private fun deliver(
        result: MethodChannel.Result,
        errorCode: (Exception) -> String,
        taskResult: FileCacheTaskResult<Any?>
    ) {
        if (closed.get()) return
        mainHandler.post {
            if (closed.get()) return@post
            when (taskResult) {
                is FileCacheTaskResult.Success -> result.success(taskResult.value)
                is FileCacheTaskResult.Failure -> {
                    val exception = taskResult.exception
                    result.error(
                        errorCode(exception),
                        exception.message ?: "unknown error",
                        null
                    )
                }
            }
        }
    }

    fun shutdown() {
        closed.set(true)
    }
}
