package com.nameless.audio

import io.flutter.plugin.common.MethodCall
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
}
