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
    fun `app theme sync forwards pureBlack flag and rejects invalid pureBlack type`() {
        var receivedPureBlack = false
        val handler = AppLifecycleMethodHandler(
            terminateForPendingRestore = {},
            syncAppTheme = { _, _, pureBlack -> receivedPureBlack = pureBlack },
        )
        val okResult = RecordingAppLifecycleResult()
        handler.onMethodCall(
            MethodCall(
                AppLifecycleMethods.SYNC_APP_THEME,
                mapOf("preset" to "mint", "themeMode" to "dark", "pureBlack" to true),
            ),
            okResult,
        )
        assertTrue(receivedPureBlack)
        assertTrue((okResult.successValue as Map<*, *>)["ok"] == true)

        val badResult = RecordingAppLifecycleResult()
        handler.onMethodCall(
            MethodCall(
                AppLifecycleMethods.SYNC_APP_THEME,
                mapOf("preset" to "mint", "themeMode" to "dark", "pureBlack" to "yes"),
            ),
            badResult,
        )
        val response = badResult.successValue as Map<*, *>
        assertEquals(false, response["ok"])
        assertEquals(ChannelErrorCodes.INVALID_ARGUMENT, response["errorCode"])
    }

    @Test
    fun `getSystemAccentColor returns provided accent value`() {
        val handler = AppLifecycleMethodHandler(
            terminateForPendingRestore = {},
            syncAppTheme = { _, _, _ -> },
            getSystemAccentColor = { 0xFF3366CC.toInt() },
        )
        val result = RecordingAppLifecycleResult()
        handler.onMethodCall(
            MethodCall(AppLifecycleMethods.GET_SYSTEM_ACCENT_COLOR, null),
            result,
        )
        val response = result.successValue as Map<*, *>
        assertEquals(true, response["ok"])
        assertEquals(0xFF3366CC.toInt(), response["value"])
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
