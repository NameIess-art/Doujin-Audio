package com.doujin.audio

import android.app.Activity
import com.doujin.audio.channel.AudioPickerCoordinator
import com.doujin.audio.channel.FileCacheTaskExecutor
import com.doujin.audio.channel.FileExportCoordinator
import com.doujin.audio.storage.DocumentStorageOperations
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FilePickerCoordinatorTest {
    @Test
    fun `disposing an active picker completes its result as cancellation`() {
        val activity = RecordingActivity()
        val executor = FileCacheTaskExecutor()
        val coordinator = AudioPickerCoordinator(
            activity,
            executor,
        )
        val result = RecordingResult()

        setPendingPickerRequest(coordinator, result)
        coordinator.dispose()
        coordinator.handleActivityResult(7003, Activity.RESULT_CANCELED, null)
        coordinator.dispose()

        assertEquals(1, result.successCount)
        assertNull(result.value)
        assertEquals(0, result.errorCount)
        executor.shutdownNow()
    }

    @Test
    fun `disposing an active export completes its result as cancellation`() {
        val activity = RecordingActivity()
        val executor = FileCacheTaskExecutor()
        val coordinator = FileExportCoordinator(
            activity,
            DocumentStorageOperations(activity),
            executor,
        )
        val result = RecordingResult()

        setPendingExportRequest(coordinator, result)
        coordinator.dispose()
        coordinator.handleActivityResult(7004, Activity.RESULT_CANCELED, null)
        coordinator.dispose()

        assertEquals(1, result.successCount)
        assertNull(result.value)
        assertEquals(0, result.errorCount)
        executor.shutdownNow()
    }
}

private class RecordingActivity : Activity()

private class RecordingResult : MethodChannel.Result {
    var successCount = 0
    var errorCount = 0
    var value: Any? = null

    override fun success(result: Any?) {
        successCount++
        value = result
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        errorCount++
    }

    override fun notImplemented() = Unit
}

private fun setPendingPickerRequest(
    coordinator: AudioPickerCoordinator,
    result: RecordingResult,
) {
    val modeClass = Class.forName(
        "com.doujin.audio.channel.AudioPickerCoordinator\u0024PickAudioMode",
    )
    val mode = modeClass.enumConstants.first { (it as Enum<*>).name == "folder" }
    val requestClass = Class.forName(
        "com.doujin.audio.channel.AudioPickerCoordinator\u0024PendingPickAudioRequest",
    )
    val request = requestClass.declaredConstructors.single().apply {
        isAccessible = true
    }.newInstance(result, mode, 1L)
    coordinator.javaClass.getDeclaredField("pendingRequest").apply {
        isAccessible = true
        set(coordinator, request)
    }
}

private fun setPendingExportRequest(
    coordinator: FileExportCoordinator,
    result: RecordingResult,
) {
    val requestClass = Class.forName(
        "com.doujin.audio.channel.FileExportCoordinator\u0024PendingExportRequest",
    )
    val request = requestClass.declaredConstructors.single().apply {
        isAccessible = true
    }.newInstance(1L, "/tmp/source.mp3", result)
    coordinator.javaClass.getDeclaredField("pendingRequest").apply {
        isAccessible = true
        set(coordinator, request)
    }
}
