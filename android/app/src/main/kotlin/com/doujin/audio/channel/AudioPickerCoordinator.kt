package com.doujin.audio.channel

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.documentfile.provider.DocumentFile
import com.doujin.audio.storage.NewlyPersistedUriPermission
import com.doujin.audio.storage.PersistedUriPermissionOperations
import io.flutter.plugin.common.MethodChannel

internal class AudioPickerCoordinator(
    private val activity: Activity,
    private val taskExecutor: FileCacheTaskExecutor
) {
    private val pickAudioSourceRequestCode = 7001
    private val pickAudioFilesRequestCode = 7002
    private val pickAudioFolderRequestCode = 7003
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private var pendingRequest: PendingPickAudioRequest? = null
    private var generation = 0L
    private var disposed = false

    private val audioPickerMimeTypes = arrayOf(
        "audio/*",
        "video/*",
        "application/ogg",
        "audio/ogg",
        "audio/flac",
        "audio/x-flac",
        "audio/wav",
        "audio/x-wav",
        "audio/mpeg",
        "audio/mp4",
        "audio/aac",
        "audio/x-m4a",
        "audio/3gpp",
        "audio/opus",
        "video/mp4",
        "video/x-matroska",
        "video/webm",
        "video/quicktime",
        "video/x-msvideo",
        "video/3gpp"
    )

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (
            requestCode != pickAudioSourceRequestCode &&
            requestCode != pickAudioFilesRequestCode &&
            requestCode != pickAudioFolderRequestCode
        ) {
            return false
        }
        handlePickAudioSourceResult(requestCode, resultCode, data)
        return true
    }

    fun launchPickAudioSource(result: MethodChannel.Result) {
        if (disposed) {
            result.error("picker_failed", "audio picker is unavailable", null)
            return
        }
        if (pendingRequest != null) {
            result.error("picker_busy", "Audio picker is already active", null)
            return
        }
        try {
            val pickFilesIntent = buildPickAudioFilesIntent()
            val pickFolderIntent = buildPickAudioFolderIntent()
            val chooserIntent = Intent(Intent.ACTION_CHOOSER).apply {
                putExtra(Intent.EXTRA_INTENT, pickFilesIntent)
                putExtra(Intent.EXTRA_TITLE, "Select audio")
                putExtra(Intent.EXTRA_INITIAL_INTENTS, arrayOf(pickFolderIntent))
            }

            pendingRequest = PendingPickAudioRequest(
                result = result,
                mode = PickAudioMode.any,
                generation = ++generation
            )
            activity.startActivityForResult(chooserIntent, pickAudioSourceRequestCode)
        } catch (e: Exception) {
            pendingRequest = null
            result.error("picker_failed", e.message ?: "cannot launch picker", null)
        }
    }

    fun launchPickAudioFiles(result: MethodChannel.Result) {
        launchAudioPicker(
            result = result,
            mode = PickAudioMode.files,
            requestCode = pickAudioFilesRequestCode,
            intentBuilder = ::buildPickAudioFilesIntent
        )
    }

    fun launchPickAudioFolder(result: MethodChannel.Result) {
        launchAudioPicker(
            result = result,
            mode = PickAudioMode.folder,
            requestCode = pickAudioFolderRequestCode,
            intentBuilder = ::buildPickAudioFolderIntent
        )
    }

    private fun launchAudioPicker(
        result: MethodChannel.Result,
        mode: PickAudioMode,
        requestCode: Int,
        intentBuilder: () -> Intent
    ) {
        if (disposed) {
            result.error("picker_failed", "audio picker is unavailable", null)
            return
        }
        if (pendingRequest != null) {
            result.error("picker_busy", "Audio picker is already active", null)
            return
        }
        try {
            pendingRequest = PendingPickAudioRequest(
                result = result,
                mode = mode,
                generation = ++generation
            )
            activity.startActivityForResult(intentBuilder(), requestCode)
        } catch (e: Exception) {
            pendingRequest = null
            result.error("picker_failed", e.message ?: "cannot launch picker", null)
        }
    }

    private fun buildPickAudioFilesIntent(): Intent {
        return Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            putExtra(Intent.EXTRA_MIME_TYPES, audioPickerMimeTypes)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
    }

    private fun buildPickAudioFolderIntent(): Intent {
        return Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
    }

    private fun handlePickAudioSourceResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ) {
        val pending = pendingRequest ?: return
        val callback = pending.result

        if (resultCode != Activity.RESULT_OK || data == null) {
            pendingRequest = null
            callback.success(null)
            return
        }

        val maybeTreeUri = data.data
        if (maybeTreeUri != null && DocumentsContract.isTreeUri(maybeTreeUri)) {
            if (pending.mode == PickAudioMode.files) {
                pendingRequest = null
                callback.success(null)
                return
            }
            submitPickerTask(pending) {
                PersistedUriPermissionOperations.withPermissionLock {
                    persistReadPermission(maybeTreeUri, data.flags)
                    hashMapOf(
                        "kind" to "folder",
                        "path" to maybeTreeUri.toString(),
                        "label" to resolveTreeDisplayName(maybeTreeUri)
                    )
                }
            }
            return
        }

        if (pending.mode == PickAudioMode.folder || requestCode == pickAudioFolderRequestCode) {
            pendingRequest = null
            callback.success(null)
            return
        }

        val pickedUris = arrayListOf<Uri>()
        data.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) {
                val uri = clip.getItemAt(i)?.uri ?: continue
                pickedUris.add(uri)
            }
        }
        maybeTreeUri?.let { uri ->
            pickedUris.add(uri)
        }

        if (pickedUris.isEmpty()) {
            pendingRequest = null
            callback.success(null)
            return
        }

        submitPickerTask(pending) {
            PersistedUriPermissionOperations.withPermissionLock {
                val files = arrayListOf<HashMap<String, String>>()
                val newlyPersisted = mutableListOf<NewlyPersistedUriPermission>()
                try {
                    for (uri in pickedUris.distinct()) {
                        appendPickedFile(files, uri, data.flags)?.let(newlyPersisted::add)
                    }
                } catch (error: Exception) {
                    PersistedUriPermissionOperations.rollbackPickerGrants(
                        activity.contentResolver,
                        newlyPersisted
                    )
                    throw error
                }
                hashMapOf<String, Any>(
                    "kind" to "files",
                    "files" to files
                )
            }
        }
    }

    private fun submitPickerTask(
        request: PendingPickAudioRequest,
        block: () -> Any?
    ) {
        val accepted = taskExecutor.submit(
            block = block,
            completion = { taskResult ->
                mainHandler.post {
                    if (
                        disposed ||
                        pendingRequest?.generation != request.generation
                    ) {
                        return@post
                    }
                    pendingRequest = null
                    when (taskResult) {
                        is FileCacheTaskResult.Success ->
                            request.result.success(taskResult.value)
                        is FileCacheTaskResult.Failure -> request.result.error(
                            if (taskResult.exception is SecurityException) {
                                "picker_permission_denied"
                            } else {
                                "picker_failed"
                            },
                            taskResult.exception.message ?: "audio picker failed",
                            null
                        )
                    }
                }
            }
        )
        if (!accepted) {
            pendingRequest = null
            request.result.error("picker_failed", "audio picker is unavailable", null)
        }
    }

    private fun resolveTreeDisplayName(uri: Uri): String? {
        val treeRoot = DocumentFile.fromTreeUri(activity, uri)
        val name = treeRoot?.name?.trim()
        if (!name.isNullOrBlank()) {
            return name
        }
        return resolveDisplayName(uri)
    }

    private fun appendPickedFile(
        files: MutableList<HashMap<String, String>>,
        uri: Uri,
        flags: Int
    ): NewlyPersistedUriPermission? {
        val persisted = persistReadPermission(uri, flags)
        val name = resolveDisplayName(uri)
            ?: uri.lastPathSegment
            ?: "picked_audio"
        files.add(
            hashMapOf(
                "uri" to uri.toString(),
                "name" to name
            )
        )
        return persisted
    }

    private fun persistReadPermission(
        uri: Uri,
        flags: Int
    ): NewlyPersistedUriPermission? = PersistedUriPermissionOperations.takeForPicker(
        activity.contentResolver,
        uri,
        flags
    )

    private fun resolveDisplayName(uri: Uri): String? {
        return try {
            activity.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (!cursor.moveToFirst()) return@use null
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index < 0) return@use null
                cursor.getString(index)
            }
        } catch (_: Exception) {
            null
        }
    }

    fun dispose() {
        val request = pendingRequest
        disposed = true
        generation++
        pendingRequest = null
        request?.result?.success(null)
    }

    private data class PendingPickAudioRequest(
        val result: MethodChannel.Result,
        val mode: PickAudioMode,
        val generation: Long
    )

    private enum class PickAudioMode {
        any,
        files,
        folder
    }
}
