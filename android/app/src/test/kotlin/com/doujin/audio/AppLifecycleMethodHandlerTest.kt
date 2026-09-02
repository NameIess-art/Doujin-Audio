package com.doujin.audio

import com.doujin.audio.channel.*
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AppLifecycleMethodHandlerTest {
    @Test
    fun `pending restore termination acknowledges before invoking termination`() {
        val events = mutableListOf<String>()
        val handler = AppLifecycleMethodHandler { events += "terminate" }
        val result = RecordingAppLifecycleResult { events += "success" }
        handler.onMethodCall(MethodCall(AppLifecycleMethods.TERMINATE_FOR_PENDING_RESTORE, null), result)
        assertEquals(listOf("success", "terminate"), events)
        assertTrue((result.successValue as Map<*, *>) ["ok"] == true)
    }

    @Test
    fun `unknown lifecycle method is not implemented`() {
        val handler = AppLifecycleMethodHandler {}
        val result = RecordingAppLifecycleResult()
        handler.onMethodCall(MethodCall("unknown", null), result)
        assertEquals(1, result.notImplementedCalls)
    }

    @Test
    fun `app theme sync forwards the required preset and theme mode`() {
        var receivedPreset: String? = null
        var receivedMode: String? = null
        val handler = AppLifecycleMethodHandler(
            terminateForPendingRestore = {},
            syncAppTheme = { preset, mode ->
                receivedPreset = preset
                receivedMode = mode
            },
        )
        val result = RecordingAppLifecycleResult()

        handler.onMethodCall(
            MethodCall(
                AppLifecycleMethods.SYNC_APP_THEME,
                mapOf("preset" to "mint", "themeMode" to "dark"),
            ),
            result,
        )

        assertEquals("mint", receivedPreset)
        assertEquals("dark", receivedMode)
        assertTrue((result.successValue as Map<*, *>)["ok"] == true)
    }

    @Test
    fun `app theme sync rejects missing arguments`() {
        val handler = AppLifecycleMethodHandler(terminateForPendingRestore = {})
        val result = RecordingAppLifecycleResult()

        handler.onMethodCall(
            MethodCall(AppLifecycleMethods.SYNC_APP_THEME, emptyMap<String, Any>()),
            result,
        )

        val response = result.successValue as Map<*, *>
        assertEquals(false, response["ok"])
        assertEquals(ChannelErrorCodes.INVALID_ARGUMENT, response["errorCode"])
    }
}

private class RecordingAppLifecycleResult(private val onSuccess: () -> Unit = {}) : MethodChannel.Result {
    var successValue: Any? = null
    var notImplementedCalls = 0
    override fun success(result: Any?) { successValue = result; onSuccess() }
    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) = Unit
    override fun notImplemented() { notImplementedCalls++ }
}
