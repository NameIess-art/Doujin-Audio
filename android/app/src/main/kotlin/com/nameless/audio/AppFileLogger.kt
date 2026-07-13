package com.nameless.audio

import android.content.Context
import android.util.Log
import java.io.BufferedWriter
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStreamWriter
import java.io.PrintWriter
import java.io.StringWriter
import java.nio.charset.StandardCharsets
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

internal class AppFileLogWriter(
    private val logDirectory: File,
    private val fileName: String = DEFAULT_FILE_NAME,
    private val maxLogBytes: Long = DEFAULT_MAX_LOG_BYTES
) {
    companion object {
        const val DEFAULT_FILE_NAME = "nameless_audio_android.log"
        const val DEFAULT_MAX_LOG_BYTES = 1024 * 1024L
    }

    private var writer: BufferedWriter? = null
    private var currentBytes = 0L

    fun append(message: String) {
        val line = "$message\n"
        val lineBytes = line.toByteArray(StandardCharsets.UTF_8).size.toLong()
        try {
            ensureOpen()
            if (currentBytes > 0L && currentBytes + lineBytes > maxLogBytes) {
                rotate()
                ensureOpen()
            }
            writer!!.write(line)
            writer!!.flush()
            currentBytes += lineBytes
        } catch (exception: Exception) {
            closeQuietly()
            throw exception
        }
    }

    fun close() {
        val currentWriter = writer
        writer = null
        currentWriter?.close()
    }

    private fun ensureOpen() {
        if (writer != null) return
        if (!logDirectory.exists() && !logDirectory.mkdirs()) {
            throw IOException("cannot create log directory")
        }
        if (!logDirectory.isDirectory) {
            throw IOException("log path is not a directory")
        }
        val logFile = File(logDirectory, fileName)
        currentBytes = if (logFile.exists()) logFile.length() else 0L
        writer = BufferedWriter(
            OutputStreamWriter(
                FileOutputStream(logFile, true),
                StandardCharsets.UTF_8
            )
        )
    }

    private fun rotate() {
        close()
        val logFile = File(logDirectory, fileName)
        val rotatedFile = File(logDirectory, "$fileName.1")
        if (rotatedFile.exists() && !rotatedFile.delete()) {
            throw IOException("cannot delete rotated log")
        }
        if (logFile.exists() && !logFile.renameTo(rotatedFile)) {
            throw IOException("cannot rotate log")
        }
        currentBytes = 0L
    }

    private fun closeQuietly() {
        try {
            close()
        } catch (_: Exception) {
            writer = null
        }
    }
}

internal object AppFileLogger {
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "nameless-file-log").apply { isDaemon = true }
    }
    private val timestampFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ", Locale.US)
    private var writer: AppFileLogWriter? = null
    private var writerDirectory: File? = null

    fun info(context: Context, tag: String, message: String) {
        Log.i(tag, message)
        enqueue(context.applicationContext.filesDir, "INFO", tag, message, null)
    }

    fun warn(context: Context, tag: String, message: String, error: Throwable? = null) {
        if (error == null) {
            Log.w(tag, message)
        } else {
            Log.w(tag, message, error)
        }
        enqueue(context.applicationContext.filesDir, "WARN", tag, message, error)
    }

    private fun enqueue(
        filesDirectory: File,
        level: String,
        tag: String,
        message: String,
        error: Throwable?
    ) {
        executor.execute {
            try {
                val logDirectory = File(filesDirectory, "logs")
                if (writerDirectory != logDirectory) {
                    writer?.close()
                    writer = null
                    writerDirectory = logDirectory
                }
                val stackTrace = error?.let {
                    val stringWriter = StringWriter()
                    it.printStackTrace(PrintWriter(stringWriter))
                    "\n$stringWriter"
                }.orEmpty()
                val timestamp = timestampFormat.format(Date())
                val fileWriter = writer ?: AppFileLogWriter(logDirectory).also {
                    writer = it
                }
                fileWriter.append("$timestamp [$level/$tag] $message$stackTrace")
            } catch (_: Exception) {
                try {
                    writer?.close()
                } catch (_: Exception) {
                    // Logging must never crash playback.
                }
                writer = null
            }
        }
    }

    internal fun flushAndCloseForTest(timeoutSeconds: Long = 5): Boolean {
        val finished = CountDownLatch(1)
        executor.execute {
            try {
                writer?.close()
                writer = null
            } finally {
                finished.countDown()
            }
        }
        return finished.await(timeoutSeconds, TimeUnit.SECONDS)
    }
}
