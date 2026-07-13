package com.nameless.audio

import io.flutter.plugin.common.MethodCall
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChannelContractTest {
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
                "bytes" to byteArrayOf(1, 2)
            )
        ).argumentReader()

        assertEquals("session-1", reader.requiredString("sessionId"))
        assertEquals(4, reader.requiredInt("index"))
        assertTrue(reader.requiredBoolean("enabled"))
        assertEquals(listOf("one"), reader.requiredList("items"))
        assertEquals(mapOf("title" to "Track"), reader.requiredMap("metadata"))
        assertTrue(byteArrayOf(1, 2).contentEquals(reader.requiredByteArray("bytes")))
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
}
