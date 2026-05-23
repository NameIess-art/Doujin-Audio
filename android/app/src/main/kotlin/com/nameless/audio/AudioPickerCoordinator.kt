package com.nameless.audio

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.MethodChannel

internal class AudioPickerCoordinator(
    private val activity: Activity
) {
    private val pickAudioSourceRequestCode = 7001
    private val pickAudioFilesRequestCode = 7002
    private val pickAudioFolderRequestCode = 7003
    private var pendingRequest: PendingPickAudioRequest? = null

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
                mode = PickAudioMode.any
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
        if (pendingRequest != null) {
            result.error("picker_busy", "Audio picker is already active", null)
            return
        }
        try {
            pendingRequest = PendingPickAudioRequest(result = result, mode = mode)
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
        pendingRequest = null

        if (resultCode != Activity.RESULT_OK || data == null) {
            callback.success(null)
            return
        }

        val maybeTreeUri = data.data
        if (maybeTreeUri != null && DocumentsContract.isTreeUri(maybeTreeUri)) {
            if (pending.mode == PickAudioMode.files) {
                callback.success(null)
                return
            }
            persistReadPermission(maybeTreeUri, data.flags)
            callback.success(
                hashMapOf(
                    "kind" to "folder",
                    "path" to maybeTreeUri.toString(),
                    "label" to resolveTreeDisplayName(maybeTreeUri)
                )
            )
            return
        }

        if (pending.mode == PickAudioMode.folder || requestCode == pickAudioFolderRequestCode) {
            callback.success(null)
            return
        }

        val files = arrayListOf<HashMap<String, String>>()
        data.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) {
                val uri = clip.getItemAt(i)?.uri ?: continue
                appendPickedFile(files, uri, data.flags)
            }
        }
        maybeTreeUri?.let { uri ->
            appendPickedFile(files, uri, data.flags)
        }

        if (files.isEmpty()) {
            callback.success(null)
            return
        }

        callback.success(
            hashMapOf(
                "kind" to "files",
                "files" to files
            )
        )
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
    ) {
        persistReadPermission(uri, flags)
        val name = resolveDisplayName(uri)
            ?: uri.lastPathSegment
            ?: "picked_audio"
        files.add(
            hashMapOf(
                "uri" to uri.toString(),
                "name" to name
            )
        )
    }

    private fun persistReadPermission(uri: Uri, flags: Int) {
        val canRead = flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0
        val canWrite = flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0
        if (!canRead && !canWrite) return
        try {
            var modeFlags = 0
            if (canRead) modeFlags = modeFlags or Intent.FLAG_GRANT_READ_URI_PERMISSION
            if (canWrite) modeFlags = modeFlags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            activity.contentResolver.takePersistableUriPermission(
                uri,
                modeFlags
            )
        } catch (_: Exception) {
            // Some providers do not support persistable permissions.
        }
    }

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

    private data class PendingPickAudioRequest(
        val result: MethodChannel.Result,
        val mode: PickAudioMode
    )

    private enum class PickAudioMode {
        any,
        files,
        folder
    }
}
