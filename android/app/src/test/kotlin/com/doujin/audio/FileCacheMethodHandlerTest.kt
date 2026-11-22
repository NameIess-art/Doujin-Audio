package com.doujin.audio

import android.app.Activity
import android.os.Looper
import com.doujin.audio.channel.ChannelErrorCodes
import com.doujin.audio.channel.FileCacheMethodHandler
import com.doujin.audio.channel.FileCacheMethods
import com.doujin.audio.channel.FileCacheTaskExecutor
import com.doujin.audio.scanner.FileCacheScanStreamHandler
import com.doujin.audio.storage.FileCacheOperations
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class FileCacheMethodHandlerTest {
    @Test
    fun `startFolderScan rejects non-positive chunkSize and outer catch wraps sync errors`() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val operations = FileCacheOperations(activity.applicationContext)
        val scanStream = FileCacheScanStreamHandler(activity, operations)
        val executor = FileCacheTaskExecutor()
        val handler = FileCacheMethodHandler(
            operations = operations,
            scanStreamHandler = scanStream,
            taskExecutor = executor,
            launchExportFile = { _, _, _, _ -> throw IllegalStateException("export unavailable") },
            launchPickAudioFiles = {},
            launchPickAudioFolder = {}
        )
        try {
            fun invoke(method: String, args: Any?): Map<*, *> {
                var response: Any? = null
                val result = object : MethodChannel.Result {
                    override fun success(value: Any?) { response = value }
                    override fun error(code: String, message: String?, details: Any?) = error("Envelope expected")
                    override fun notImplemented() = error("Known method expected")
                }
                handler.onMethodCall(MethodCall(method, args), result)
                return response as Map<*, *>
            }

            for (badSize in listOf(0, -10)) {
                val resp = invoke(
                    FileCacheMethods.START_FOLDER_SCAN,
                    mapOf(
                        "taskId" to "t1",
                        "generationId" to "g1",
                        "folder" to "/music",
                        "chunkSize" to badSize
                    )
                )
                assertEquals(false, resp["ok"])
                assertEquals(ChannelErrorCodes.INVALID_ARGUMENT, resp["errorCode"])
            }

            val syncErr = invoke(
                FileCacheMethods.EXPORT_FILE,
                mapOf("sourcePath" to "/a.mp3", "fileName" to "a.mp3", "mimeType" to "audio/mpeg")
            )
            assertEquals(false, syncErr["ok"])
            assertEquals(ChannelErrorCodes.PLATFORM_ERROR, syncErr["errorCode"])
        } finally {
            handler.shutdown()
            scanStream.shutdown()
            executor.shutdownNow()
        }
    }

    @Test
    fun `in-flight async task completing after shutdown receives unavailable envelope`() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val operations = FileCacheOperations(activity.applicationContext)
        val scanStream = FileCacheScanStreamHandler(activity, operations)
        val executor = FileCacheTaskExecutor()
        val handler = FileCacheMethodHandler(
            operations = operations,
            scanStreamHandler = scanStream,
            taskExecutor = executor,
            launchExportFile = { _, _, _, _ -> },
            launchPickAudioFiles = {},
            launchPickAudioFolder = {}
        )
        try {
            var response: Any? = null
            val delivered = CountDownLatch(1)
            val result = object : MethodChannel.Result {
                override fun success(value: Any?) { response = value; delivered.countDown() }
                override fun error(code: String, message: String?, details: Any?) = error("Envelope expected")
                override fun notImplemented() = error("Known method expected")
            }
            handler.onMethodCall(
                MethodCall(FileCacheMethods.DOCUMENT_PATH_EXISTS, mapOf("path" to "/nonexistent")),
                result
            )
            // Shut down immediately so delivery observes closed == true.
            handler.shutdown()

            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
            while (delivered.count > 0 && System.nanoTime() < deadline) {
                shadowOf(Looper.getMainLooper()).idle()
                Thread.sleep(10)
            }
            assertEquals(0L, delivered.count)
            val envelope = response as Map<*, *>
            assertEquals(false, envelope["ok"])
            assertEquals(ChannelErrorCodes.SERVICE_UNAVAILABLE, envelope["errorCode"])
        } finally {
            handler.shutdown()
            scanStream.shutdown()
            executor.shutdownNow()
        }
    }

    @Test
    fun `folder scan stream times out unacknowledged chunk and reports error without deadlocking`() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val tempDir = File(activity.cacheDir, "scan-timeout-test").apply {
            deleteRecursively()
            mkdirs()
        }
        repeat(25) { index ->
            File(tempDir, "track_$index.mp3").writeBytes(byteArrayOf(0))
        }
        val operations = FileCacheOperations(activity.applicationContext)
        val scanStream = FileCacheScanStreamHandler(
            activity = activity,
            operations = operations,
            chunkAckTimeoutMs = 50L
        )
        val events = CopyOnWriteArrayList<Map<*, *>>()
        val failedLatch = CountDownLatch(1)
        try {
            scanStream.onListen(
                mapOf("generationId" to "gen-timeout"),
                object : EventChannel.EventSink {
                    override fun success(event: Any?) {
                        val map = event as Map<*, *>
                        events += map
                        if (map["eventType"] == "failed") {
                            failedLatch.countDown()
                        }
                    }

                    override fun error(errorCode: String?, errorMessage: String?, errorDetails: Any?) = Unit
                    override fun endOfStream() = Unit
                }
            )
            assertTrue(
                scanStream.startFolderScan(
                    "task-1",
                    "gen-timeout",
                    tempDir.absolutePath.replace('\\', '/'),
                    20
                )
            )

            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (failedLatch.count > 0 && System.nanoTime() < deadline) {
                shadowOf(Looper.getMainLooper()).idle()
                Thread.sleep(15)
            }
            assertEquals(0L, failedLatch.count)
            val failedEvent = events.first { it["eventType"] == "failed" }
            assertEquals("scan_ack_timeout", failedEvent["errorCode"])
        } finally {
            scanStream.shutdown()
            tempDir.deleteRecursively()
        }
    }

    @Test
    fun `folder scan stream cancels task immediately when event sink throws`() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val tempDir = File(activity.cacheDir, "scan-sink-error-test").apply {
            deleteRecursively()
            mkdirs()
        }
        repeat(25) { index ->
            File(tempDir, "track_$index.mp3").writeBytes(byteArrayOf(0))
        }
        val operations = FileCacheOperations(activity.applicationContext)
        val scanStream = FileCacheScanStreamHandler(
            activity = activity,
            operations = operations,
            chunkAckTimeoutMs = 10_000L
        )
        val chunkThrown = CountDownLatch(1)
        try {
            scanStream.onListen(
                mapOf("generationId" to "gen-err"),
                object : EventChannel.EventSink {
                    override fun success(event: Any?) {
                        val map = event as Map<*, *>
                        if (map["eventType"] == "chunk") {
                            chunkThrown.countDown()
                            throw IllegalStateException("detached sink")
                        }
                    }

                    override fun error(errorCode: String?, errorMessage: String?, errorDetails: Any?) = Unit
                    override fun endOfStream() = Unit
                }
            )
            assertTrue(
                scanStream.startFolderScan(
                    "task-err",
                    "gen-err",
                    tempDir.absolutePath.replace('\\', '/'),
                    20
                )
            )

            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
            while (chunkThrown.count > 0 && System.nanoTime() < deadline) {
                shadowOf(Looper.getMainLooper()).idle()
                Thread.sleep(15)
            }
            assertEquals(0L, chunkThrown.count)

            // Worker should exit promptly (< 2s, far below the 10s ack timeout) so a second task can start.
            val startedSecond = run {
                val retryDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
                var ok = false
                while (!ok && System.nanoTime() < retryDeadline) {
                    shadowOf(Looper.getMainLooper()).idle()
                    ok = scanStream.startFolderScan(
                        "task-after-err",
                        "gen-err",
                        tempDir.absolutePath.replace('\\', '/'),
                        20
                    )
                    if (!ok) Thread.sleep(15)
                }
                ok
            }
            assertTrue(startedSecond)
        } finally {
            scanStream.shutdown()
            tempDir.deleteRecursively()
        }
    }
}
