package com.nameless.audio

import com.nameless.audio.channel.*

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChannelContractTest {
    @Test
    fun `envelope result converts success and platform errors without result error`() {
        val delegate = RecordingMethodResult()
        val result = ChannelEnvelopeResult(delegate)

        result.success("saved")
        assertEquals(channelSuccess("saved"), delegate.successValue)

        result.error("copy_failed", "copy failed", mapOf("path" to "source"))
        assertEquals(
            channelFailure("copy_failed", "copy failed", mapOf("path" to "source")),
            delegate.successValue
        )
        assertEquals(0, delegate.errorCalls)
    }

    @Test
    fun `failure envelope keeps stable code message and details`() {
        val result = channelFailure(
            code = ChannelErrorCodes.SERVICE_UNAVAILABLE,
            message = "Native playback service is not ready.",
            details = mapOf("method" to NativePlaybackMethods.PLAY)
        )

        assertFalse(result["ok"] as Boolean)
        assertEquals("service_unavailable", result["errorCode"])
        assertEquals("Native playback service is not ready.", result["error"])
        assertEquals(
            mapOf("method" to NativePlaybackMethods.PLAY),
            result["details"]
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `required long rejects a missing numeric argument`() {
        MethodCall("play", mapOf("sessionId" to "session-1"))
            .requiredLong("transportCommandId")
    }

    @Test(expected = IllegalArgumentException::class)
    fun `required double rejects a value with the wrong type`() {
        MethodCall("setSpeed", mapOf("speed" to "fast"))
            .requiredDouble("speed")
    }

    @Test
    fun `argument reader validates supported boundary types`() {
        val reader = MethodCall(
            "prepare",
            mapOf(
                "sessionId" to " session-1 ",
                "index" to 4L,
                "enabled" to true,
                "items" to listOf("one"),
                "metadata" to mapOf("title" to "Track"),
                "bytes" to byteArrayOf(1, 2),
                "nullable" to null,
                "names" to listOf(" one ", "two"),
                "hour" to 23
            )
        ).argumentReader()

        assertEquals("session-1", reader.requiredString("sessionId"))
        assertEquals(4, reader.requiredInt("index"))
        assertTrue(reader.requiredBoolean("enabled"))
        assertEquals(listOf("one"), reader.requiredList("items"))
        assertEquals(mapOf("title" to "Track"), reader.requiredMap("metadata"))
        assertTrue(byteArrayOf(1, 2).contentEquals(reader.requiredByteArray("bytes")))
        assertNull(reader.requiredNullableLong("nullable"))
        assertEquals(listOf("one", "two"), reader.requiredStringList("names"))
        assertEquals(23, reader.requiredIntInRange("hour", 0..23))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `argument reader rejects a missing required string`() {
        MethodCall("play", emptyMap<String, Any?>())
            .argumentReader()
            .requiredString("sessionId")
    }

    @Test(expected = IllegalArgumentException::class)
    fun `argument reader rejects a fractional integer`() {
        MethodCall("seek", mapOf("positionMs" to 1.5))
            .argumentReader()
            .requiredLong("positionMs")
    }

    @Test(expected = IllegalArgumentException::class)
    fun `required nullable argument still rejects a missing key`() {
        MethodCall("sync", emptyMap<String, Any?>())
            .argumentReader()
            .requiredNullableLong("timerEndsAtWallClockMs")
    }

    @Test(expected = IllegalArgumentException::class)
    fun `strict string list rejects non-string items`() {
        MethodCall("sync", mapOf("ids" to listOf("one", 2)))
            .argumentReader()
            .requiredStringList("ids")
    }

    @Test
    fun `required string allows an explicitly present empty subtitle`() {
        val text = MethodCall("updateSubtitle", mapOf("text" to ""))
            .argumentReader()
            .requiredString("text", allowBlank = true)

        assertEquals("", text)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `required string rejects a missing subtitle even when blank is allowed`() {
        MethodCall("updateSubtitle", emptyMap<String, Any?>())
            .argumentReader()
            .requiredString("text", allowBlank = true)
    }
}

private class RecordingMethodResult : MethodChannel.Result {
    var successValue: Any? = null
    var errorCalls = 0

    override fun success(result: Any?) {
        successValue = result
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        errorCalls++
    }

    override fun notImplemented() = Unit
}
