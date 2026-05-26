package com.nameless.audio

import android.content.Context
import android.util.Log
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

internal object AppFileLogger {
    private const val LOG_FILE_NAME = "nameless_audio_android.log"
    private const val MAX_LOG_BYTES = 1024 * 1024L
    private val timestampFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ", Locale.US)

    @Synchronized
    fun info(context: Context, tag: String, message: String) {
        Log.i(tag, message)
        append(context, "INFO", tag, message, null)
    }

    @Synchronized
    fun warn(context: Context, tag: String, message: String, error: Throwable? = null) {
        if (error == null) {
            Log.w(tag, message)
        } else {
            Log.w(tag, message, error)
        }
        append(context, "WARN", tag, message, error)
    }

    private fun append(
        context: Context,
        level: String,
        tag: String,
        message: String,
        error: Throwable?
    ) {
        try {
            val logDir = File(context.filesDir, "logs")
            if (!logDir.exists() && !logDir.mkdirs()) return

            val logFile = File(logDir, LOG_FILE_NAME)
            rotateIfNeeded(logFile)
            val timestamp = timestampFormat.format(Date())
            val stackTrace = error?.let {
                val writer = StringWriter()
                it.printStackTrace(PrintWriter(writer))
                "\n${writer}"
            } ?: ""
            logFile.appendText("$timestamp [$level/$tag] $message$stackTrace\n")
        } catch (_: Exception) {
            // Logging must never crash playback.
        }
    }

    private fun rotateIfNeeded(logFile: File) {
        if (!logFile.exists() || logFile.length() <= MAX_LOG_BYTES) return
        val rotatedFile = File(logFile.parentFile, "$LOG_FILE_NAME.1")
        if (rotatedFile.exists()) {
            rotatedFile.delete()
        }
        logFile.renameTo(rotatedFile)
    }
}
