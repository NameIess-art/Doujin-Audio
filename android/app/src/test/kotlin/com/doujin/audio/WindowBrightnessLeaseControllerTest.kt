package com.doujin.audio

import com.doujin.audio.channel.WindowBrightnessLeaseController
import com.doujin.audio.channel.readSystemScreenBrightnessFraction

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WindowBrightnessLeaseControllerTest {
    @Test
    fun `lease uses effective system brightness and restores default override`() {
        var windowBrightness = -1f
        val writes = mutableListOf<Float>()
        val controller = WindowBrightnessLeaseController(
            readWindowBrightness = { windowBrightness },
            readSystemBrightness = { 0.72f },
            writeWindowBrightness = {
                windowBrightness = it
                writes += it
            },
            nextToken = { "token-1" }
        )

        val lease = controller.begin()
        assertEquals("token-1", lease.token)
        assertEquals(0.72f, lease.brightness, 0.001f)
        assertTrue(controller.set(lease.token, 0.9f))
        assertEquals(0.9f, windowBrightness, 0.001f)
        assertTrue(controller.end(lease.token))
        assertEquals(-1f, windowBrightness, 0.001f)
        assertEquals(listOf(0.9f, -1f), writes)
    }

    @Test
    fun `stale token cannot mutate or restore a newer lease`() {
        var windowBrightness = 0.4f
        var tokenIndex = 0
        val controller = WindowBrightnessLeaseController(
            readWindowBrightness = { windowBrightness },
            readSystemBrightness = { 0.5f },
            writeWindowBrightness = { windowBrightness = it },
            nextToken = { "token-${++tokenIndex}" }
        )

        val first = controller.begin()
        val second = controller.begin()

        assertFalse(controller.set(first.token, 0.8f))
        assertFalse(controller.end(first.token))
        assertTrue(controller.set(second.token, 0.6f))
        assertTrue(controller.end(second.token))
        assertEquals(0.4f, windowBrightness, 0.001f)
    }

    @Test
    fun `system brightness fraction respects OEM max brightness and falls back to 255`() {
        assertEquals(0.5f, readSystemScreenBrightnessFraction(2048, 4096), 0.001f)
        assertEquals(1.0f, readSystemScreenBrightnessFraction(4095, 4095), 0.001f)
        assertEquals(128f / 255f, readSystemScreenBrightnessFraction(128, null), 0.001f)
        assertEquals(128f / 255f, readSystemScreenBrightnessFraction(128, 0), 0.001f)
        assertEquals(0.01f, readSystemScreenBrightnessFraction(0, 4095), 0.001f)
    }
}
