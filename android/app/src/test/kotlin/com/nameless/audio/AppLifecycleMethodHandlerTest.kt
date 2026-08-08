package com.nameless.audio

import com.nameless.audio.channel.*
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

        handler.onMethodCall(
            MethodCall(AppLifecycleMethods.TERMINATE_FOR_PENDING_RESTORE, null),
            result
        )

        assertEquals(listOf("success", "terminate"), events)
        assertTrue((result.successValue as Map<*, *>)["ok"] == true)
    }

    @Test
    fun `unknown lifecycle method is not implemented`() {
        val handler = AppLifecycleMethodHandler {}
        val result = RecordingAppLifecycleResult()

        handler.onMethodCall(MethodCall("unknown", null), result)

        assertEquals(1, result.notImplementedCalls)
    }
}

private class RecordingAppLifecycleResult(
    private val onSuccess: () -> Unit = {}
) : MethodChannel.Result {
    var successValue: Any? = null
    var notImplementedCalls = 0

    override fun success(result: Any?) {
        successValue = result
        onSuccess()
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) = Unit

    override fun notImplemented() {
        notImplementedCalls++
    }
}
