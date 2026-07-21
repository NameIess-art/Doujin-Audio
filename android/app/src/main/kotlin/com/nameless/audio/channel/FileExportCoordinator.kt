package com.nameless.audio.channel

import com.nameless.audio.storage.*

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

internal class FileExportCoordinator(
    private val activity: Activity,
    private val storage: DocumentStorageOperations,
    private val taskExecutor: FileCacheTaskExecutor
) {
    private val requestCode = 7004
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private var pendingRequest: PendingExportRequest? = null
    private var generation = 0L
    private var disposed = false

    fun launch(
        sourcePath: String,
        fileName: String,
        mimeType: String,
        result: MethodChannel.Result
    ) {
        if (disposed) {
            result.error("export_failed", "file export is unavailable", null)
            return
        }
        if (pendingRequest != null) {
            result.error("export_busy", "another file export is active", null)
            return
        }
        val request = PendingExportRequest(
            generation = ++generation,
            sourcePath = sourcePath,
            result = result
        )
        try {
            pendingRequest = request
            activity.startActivityForResult(
                Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mimeType
                    putExtra(Intent.EXTRA_TITLE, fileName)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                },
                requestCode
            )
        } catch (exception: Exception) {
            pendingRequest = null
            result.error(
                "export_failed",
                exception.message ?: "cannot launch file export",
                null
            )
        }
    }

    fun handleActivityResult(
        receivedRequestCode: Int,
        resultCode: Int,
        data: Intent?
    ): Boolean {
        if (receivedRequestCode != requestCode) return false
        val request = pendingRequest ?: return true
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pendingRequest = null
            request.result.success(null)
            return true
        }

        val targetUri = data.data!!.toString()
        val accepted = taskExecutor.submit(
            block = { storage.copyFileToUri(request.sourcePath, targetUri) },
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
                        is FileCacheTaskResult.Success -> request.result.success(targetUri)
                        is FileCacheTaskResult.Failure -> request.result.error(
                            "export_failed",
                            taskResult.exception.message ?: "file export failed",
                            null
                        )
                    }
                }
            }
        )
        if (!accepted) {
            pendingRequest = null
            request.result.error("export_failed", "file export is unavailable", null)
        }
        return true
    }

    fun dispose() {
        val request = pendingRequest
        disposed = true
        generation++
        pendingRequest = null
        request?.result?.success(null)
    }

    private data class PendingExportRequest(
        val generation: Long,
        val sourcePath: String,
        val result: MethodChannel.Result
    )
}
