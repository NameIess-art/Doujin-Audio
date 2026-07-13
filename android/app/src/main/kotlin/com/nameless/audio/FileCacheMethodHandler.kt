package com.nameless.audio

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
            "nameless-file-task-${threadIndex.incrementAndGet()}"
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
        when (call.method) {
            FileCacheMethods.CACHE_FROM_URI -> {
                val uriString = call.argument<String>("uri")
                val name = call.argument<String>("name") ?: "picked_audio"
                val index = call.argument<Int>("index") ?: 0
                if (uriString.isNullOrBlank()) {
                    result.error("invalid_args", "uri is required", null)
                    return
                }
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
                val maxBytes = call.argument<Number>("maxBytes")?.toLong()
                    ?: operations.defaultMaxApplicationCacheBytes
                operations.setMaxApplicationCacheBytes(maxBytes)
                runAsync(result) {
                    operations.enforceApplicationCacheLimit(maxBytes)
                    null
                }
            }
            FileCacheMethods.ENFORCE_APPLICATION_CACHE_LIMIT -> {
                val maxBytes = call.argument<Number>("maxBytes")?.toLong()
                    ?: operations.maxApplicationCacheBytes()
                runAsync(result) {
                    operations.enforceApplicationCacheLimit(maxBytes)
                    null
                }
            }
            FileCacheMethods.SCAN_FOLDER -> {
                val folder = call.argument<String>("folder")
                if (folder.isNullOrBlank()) {
                    result.error("invalid_args", "folder is required", null)
                    return
                }
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
                val sessionId = call.argument<String>("sessionId")
                val folder = call.argument<String>("folder")
                val chunkSize = call.argument<Int>("chunkSize") ?: 120
                if (sessionId.isNullOrBlank() || folder.isNullOrBlank()) {
                    result.error("invalid_args", "sessionId and folder are required", null)
                    return
                }
                result.success(
                    scanStreamHandler.startFolderScan(sessionId, folder, chunkSize)
                )
            }
            FileCacheMethods.CANCEL_FOLDER_SCAN -> {
                val sessionId = call.argument<String>("sessionId")
                if (sessionId.isNullOrBlank()) {
                    result.error("invalid_args", "sessionId is required", null)
                    return
                }
                scanStreamHandler.cancelFolderScan(sessionId)
                result.success(true)
            }
            FileCacheMethods.LIST_CHILD_FOLDERS -> {
                val folder = call.argument<String>("folder")
                if (folder.isNullOrBlank()) {
                    result.error("invalid_args", "folder is required", null)
                    return
                }
                runAsync(result, errorCode = { "list_child_folders_failed" }) {
                    operations.listChildFolders(folder)
                }
            }
            FileCacheMethods.RENAME_DOCUMENT -> {
                val targetPath = call.argument<String>("path")
                val name = call.argument<String>("name")
                if (targetPath.isNullOrBlank() || name.isNullOrBlank()) {
                    result.error("invalid_args", "path and name are required", null)
                    return
                }
                runAsync(
                    result = result,
                    errorCode = { e ->
                        if (e is SecurityException) "rename_permission_denied" else "rename_failed"
                    }
                ) {
                    operations.renameDocumentTarget(targetPath, name)
                }
            }
            FileCacheMethods.READ_AUDIO_DETAIL_BACKUP -> {
                val folder = call.argument<String>("folder")
                if (folder.isNullOrBlank()) {
                    result.error("invalid_args", "folder is required", null)
                    return
                }
                runAsync(result, errorCode = { "detail_backup_read_failed" }) {
                    operations.readAudioDetailBackup(folder)
                }
            }
            FileCacheMethods.WRITE_AUDIO_DETAIL_BACKUP -> {
                val folder = call.argument<String>("folder")
                val json = call.argument<String>("json")
                if (folder.isNullOrBlank() || json == null) {
                    result.error("invalid_args", "folder and json are required", null)
                    return
                }
                runAsync(result, errorCode = { "detail_backup_write_failed" }) {
                    operations.writeAudioDetailBackup(folder, json)
                }
            }
            FileCacheMethods.READ_SINGLE_FILE_DETAIL_BACKUP -> {
                val filePath = call.argument<String>("filePath")
                if (filePath.isNullOrBlank()) {
                    result.error("invalid_args", "filePath is required", null)
                    return
                }
                runAsync(result, errorCode = { "single_detail_backup_read_failed" }) {
                    operations.readSingleFileDetailBackup(filePath)
                }
            }
            FileCacheMethods.WRITE_SINGLE_FILE_DETAIL_BACKUP -> {
                val filePath = call.argument<String>("filePath")
                val json = call.argument<String>("json")
                if (filePath.isNullOrBlank() || json == null) {
                    result.error("invalid_args", "filePath and json are required", null)
                    return
                }
                runAsync(result, errorCode = { "single_detail_backup_write_failed" }) {
                    operations.writeSingleFileDetailBackup(filePath, json)
                }
            }
            FileCacheMethods.WRITE_FILE_BYTES_TO_FOLDER -> {
                val folder = call.argument<String>("folder")
                val name = call.argument<String>("name")
                val bytes = call.argument<ByteArray>("bytes")
                val mimeType = call.argument<String>("mimeType")
                if (folder.isNullOrBlank() || name.isNullOrBlank() || bytes == null) {
                    result.error("invalid_args", "folder, name and bytes are required", null)
                    return
                }
                runAsync(result, errorCode = { "folder_file_write_failed" }) {
                    operations.writeFileBytesToFolder(folder, name, bytes, mimeType)
                }
            }
            FileCacheMethods.DOCUMENT_PATH_EXISTS -> {
                val targetPath = call.argument<String>("path")
                if (targetPath.isNullOrBlank()) {
                    result.error("invalid_args", "path is required", null)
                    return
                }
                runAsync(result, errorCode = { "document_path_exists_failed" }) {
                    operations.documentPathExists(targetPath)
                }
            }
            FileCacheMethods.ENSURE_FOLDER_PATH -> {
                val folder = call.argument<String>("folder")
                val relativePath = call.argument<String>("relativePath")
                val overwrite = call.argument<Boolean>("overwrite") ?: false
                if (folder.isNullOrBlank() || relativePath == null) {
                    result.error("invalid_args", "folder and relativePath are required", null)
                    return
                }
                runAsync(result, errorCode = { "ensure_folder_failed" }) {
                    operations.ensureFolderPath(folder, relativePath, overwrite)
                }
            }
            FileCacheMethods.EXPORT_FILE -> {
                val sourcePath = call.argument<String>("sourcePath")
                val fileName = call.argument<String>("fileName")
                val mimeType = call.argument<String>("mimeType")
                if (
                    sourcePath.isNullOrBlank() ||
                    fileName.isNullOrBlank() ||
                    mimeType.isNullOrBlank()
                ) {
                    result.error(
                        "invalid_args",
                        "sourcePath, fileName and mimeType are required",
                        null
                    )
                    return
                }
                launchExportFile(sourcePath, fileName, mimeType, result)
            }
            FileCacheMethods.COPY_FILE_TO_FOLDER -> {
                val sourcePath = call.argument<String>("sourcePath")
                val folder = call.argument<String>("folder")
                val relativePath = call.argument<String>("relativePath")
                val overwrite = call.argument<Boolean>("overwrite") ?: false
                if (sourcePath.isNullOrBlank() ||
                    folder.isNullOrBlank() ||
                    relativePath.isNullOrBlank()
                ) {
                    result.error("invalid_args", "sourcePath, folder and relativePath are required", null)
                    return
                }
                runAsync(result, errorCode = { "copy_file_failed" }) {
                    operations.copyFileToFolder(sourcePath, folder, relativePath, overwrite)
                }
            }
            FileCacheMethods.DELETE_DOCUMENT_PATH -> {
                val targetPath = call.argument<String>("path")
                if (targetPath.isNullOrBlank()) {
                    result.error("invalid_args", "path is required", null)
                    return
                }
                runAsync(result, errorCode = { "delete_document_failed" }) {
                    operations.deleteDocumentPath(targetPath)
                }
            }
            FileCacheMethods.RESOLVE_TRACK_COVER -> {
                val trackPath = call.argument<String>("path")
                val groupKey = call.argument<String>("groupKey")
                val rootFolder = call.argument<String>("rootFolder")
                if (trackPath.isNullOrBlank()) {
                    result.error("invalid_args", "path is required", null)
                    return
                }
                runAsync(result, errorCode = { "cover_resolve_failed" }) {
                    operations.resolveTrackCover(trackPath, groupKey, rootFolder)
                }
            }
            FileCacheMethods.RESOLVE_VIDEO_FRAME -> {
                val trackPath = call.argument<String>("path")
                val modifiedAtMs = call.argument<Long>("modifiedAtMs")
                if (trackPath.isNullOrBlank()) {
                    result.error("invalid_args", "path is required", null)
                    return
                }
                runAsync(result, errorCode = { "video_frame_resolve_failed" }) {
                    operations.resolveVideoFrame(trackPath, modifiedAtMs)
                }
            }
            FileCacheMethods.RESOLVE_MEDIA_DURATION -> {
                val trackPath = call.argument<String>("path")
                if (trackPath.isNullOrBlank()) {
                    result.error("invalid_args", "path is required", null)
                    return
                }
                runAsync(result, errorCode = { "media_duration_resolve_failed" }) {
                    operations.resolveMediaDurationMs(trackPath)
                }
            }
            FileCacheMethods.DISCOVER_ROOT_IMAGES -> {
                val trackPath = call.argument<String>("path")
                val groupKey = call.argument<String>("groupKey")
                val rootFolder = call.argument<String>("rootFolder")
                if (trackPath.isNullOrBlank()) {
                    result.error("invalid_args", "path is required", null)
                    return
                }
                runAsync(result, errorCode = { "cover_discover_failed" }) {
                    operations.discoverRootImages(trackPath, groupKey, rootFolder)
                }
            }
            FileCacheMethods.RESOLVE_TRACK_SUBTITLE -> {
                val trackPath = call.argument<String>("path")
                val groupKey = call.argument<String>("groupKey")
                if (trackPath.isNullOrBlank()) {
                    result.error("invalid_args", "path is required", null)
                    return
                }
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
