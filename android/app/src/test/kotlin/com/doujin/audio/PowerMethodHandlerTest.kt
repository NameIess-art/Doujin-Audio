package com.doujin.audio

import android.app.Activity
import com.doujin.audio.channel.PowerMethodHandler
import com.doujin.audio.channel.FileCacheTaskExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Test

class PowerMethodHandlerTest {
    @Test
    fun `missing or invalid power parameters fail before platform side effects`() {
        val activity = PowerActivity()
        val handler = PowerMethodHandler(activity, FileCacheTaskExecutor())
        val calls = listOf(
            MethodCall("setKeepScreenOn", emptyMap<String, Any?>()),
            MethodCall("setKeepScreenOn", mapOf("enabled" to 1))
        )
        for (call in calls) {
            val result = PowerResult()
            handler.onMethodCall(call, result)
            val envelope = result.value as Map<*, *>
            assertEquals(call.method, false, envelope["ok"])
            assertEquals(call.method, "invalid_argument", envelope["errorCode"])
            assertEquals(mapOf("method" to call.method), envelope["details"])
            assertEquals(1, result.responses)
        }
        assertEquals(0, activity.serviceRequests)
    }
}

private class PowerActivity : Activity() {
    var serviceRequests = 0
    override fun getSystemService(name: String): Any? {
        serviceRequests++
        return null
    }
}

private class PowerResult : MethodChannel.Result {
    var value: Any? = null
    var responses = 0
    override fun success(result: Any?) {
        responses++
        value = result
    }
    override fun error(code: String, message: String?, details: Any?) = error("Envelope expected")
    override fun notImplemented() = error("Known method expected")
}
