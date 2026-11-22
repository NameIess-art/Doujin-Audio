package com.doujin.audio

import android.app.Activity
import com.doujin.audio.channel.ChannelErrorCodes
import com.doujin.audio.channel.FileCacheTaskExecutor
import com.doujin.audio.channel.PowerMethodHandler
import com.doujin.audio.channel.PowerMethods
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Test

class PowerMethodHandlerTest {
    @Test
    fun `missing or invalid power parameters fail before platform side effects`() {
        val activity = PowerActivity()
        val executor = FileCacheTaskExecutor()
        val handler = PowerMethodHandler(activity, executor)
        try {
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
        } finally {
            handler.dispose()
            executor.shutdownNow()
        }
    }

    @Test
    fun `unexpected exceptions in power handler convert to platform error envelope`() {
        val activity = PowerActivity(throwOnService = true)
        val executor = FileCacheTaskExecutor()
        val handler = PowerMethodHandler(activity, executor)
        try {
            val result = PowerResult()
            handler.onMethodCall(MethodCall(PowerMethods.IS_IGNORING_BATTERY_OPTIMIZATIONS, null), result)
            val envelope = result.value as Map<*, *>
            assertEquals(false, envelope["ok"])
            assertEquals(ChannelErrorCodes.PLATFORM_ERROR, envelope["errorCode"])
            assertEquals(mapOf("method" to PowerMethods.IS_IGNORING_BATTERY_OPTIMIZATIONS), envelope["details"])
        } finally {
            handler.dispose()
            executor.shutdownNow()
        }
    }

    @Test
    fun `disposed power handler rejects executeNow with service unavailable`() {
        val activity = PowerActivity()
        val executor = FileCacheTaskExecutor()
        val handler = PowerMethodHandler(activity, executor)
        handler.dispose()
        try {
            val result = PowerResult()
            handler.onMethodCall(
                MethodCall(PowerMethods.EXECUTE_TIMER_EXPIRED_NOW, mapOf("generation" to 1)),
                result
            )
            val envelope = result.value as Map<*, *>
            assertEquals(false, envelope["ok"])
            assertEquals(ChannelErrorCodes.SERVICE_UNAVAILABLE, envelope["errorCode"])
        } finally {
            executor.shutdownNow()
        }
    }
}

private class PowerActivity(
    private val throwOnService: Boolean = false
) : Activity() {
    var serviceRequests = 0
    override fun getSystemService(name: String): Any? {
        serviceRequests++
        if (throwOnService) throw IllegalStateException("power manager unavailable")
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
