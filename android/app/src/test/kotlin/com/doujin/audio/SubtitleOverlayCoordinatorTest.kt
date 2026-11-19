package com.doujin.audio

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.ContextWrapper
import android.content.Intent
import android.content.ServiceConnection
import com.doujin.audio.subtitle.SubtitleOverlayCoordinator
import com.doujin.audio.subtitle.SubtitleOverlayMethodHandler
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SubtitleOverlayCoordinatorTest {
    @Test
    fun `stop before connection unbinds pending service and ignores late binder`() {
        val context = OverlayContext()
        val coordinator = SubtitleOverlayCoordinator(context)
        assertTrue(coordinator.start())
        val oldConnection = context.bound.single()

        coordinator.stop()
        oldConnection.onServiceConnected(null, null)

        assertEquals(listOf(oldConnection), context.unbound)
        assertEquals(1, context.stops)
        assertTrue(coordinator.start())
        oldConnection.onServiceConnected(null, null)
        oldConnection.onServiceDisconnected(null)
        coordinator.stop()
        assertEquals(context.bound, context.unbound)
    }

    @Test
    fun `repeated start does not register another pending binding and dispose unbinds it`() {
        val context = OverlayContext()
        val coordinator = SubtitleOverlayCoordinator(context)
        assertTrue(coordinator.start())
        assertTrue(coordinator.start())
        assertEquals(1, context.bound.size)

        coordinator.dispose()
        coordinator.dispose()
        context.bound.single().onServiceConnected(null, null)

        assertEquals(context.bound, context.unbound)
        assertEquals(0, context.stops)
    }

    @Test
    fun `disconnected service still unregisters binding when stopped`() {
        val context = OverlayContext()
        val coordinator = SubtitleOverlayCoordinator(context)
        coordinator.start()
        context.bound.single().onServiceDisconnected(null)
        coordinator.stop()
        assertEquals(context.bound, context.unbound)
    }

    @Test
    fun `failed registration reports false and can retry`() {
        val context = OverlayContext().apply { bindResult = false }
        val coordinator = SubtitleOverlayCoordinator(context)
        assertFalse(coordinator.start())
        assertEquals(1, context.stops)
        assertTrue(context.unbound.isEmpty())

        context.bindResult = true
        assertTrue(coordinator.start())
        coordinator.stop()
        assertEquals(listOf(context.bound.last()), context.unbound)
    }

    @Test
    fun `overlay channel reports failed binding rather than success`() {
        val context = OverlayContext().apply { bindResult = false }
        var response: Any? = null
        val result = object : MethodChannel.Result {
            override fun success(result: Any?) { response = result }
            override fun error(code: String, message: String?, details: Any?) = error("Envelope expected")
            override fun notImplemented() = error("Known method expected")
        }
        SubtitleOverlayMethodHandler(SubtitleOverlayCoordinator(context))
            .onMethodCall(MethodCall("startOverlay", null), result)
        assertEquals(mapOf("ok" to true, "value" to false), response)
    }

    @Test
    fun `background start restriction and missing settings activity propagate structured channel errors`() {
        val context = OverlayContext().apply {
            startServiceError = IllegalStateException("background restricted")
            startActivityError = ActivityNotFoundException("no settings")
        }
        val handler = SubtitleOverlayMethodHandler(SubtitleOverlayCoordinator(context))

        val responses = mutableListOf<Any?>()
        val result = object : MethodChannel.Result {
            override fun success(result: Any?) { responses += result }
            override fun error(code: String, message: String?, details: Any?) = error("Envelope expected")
            override fun notImplemented() = error("Known method expected")
        }

        handler.onMethodCall(MethodCall("startOverlay", null), result)
        handler.onMethodCall(MethodCall("openOverlaySettings", null), result)

        assertEquals(2, responses.size)
        val startError = responses[0] as Map<*, *>
        assertEquals(false, startError["ok"])
        assertEquals("platform_error", startError["errorCode"])
        val settingsError = responses[1] as Map<*, *>
        assertEquals(false, settingsError["ok"])
        assertEquals("platform_error", settingsError["errorCode"])
    }
}

private class OverlayContext : ContextWrapper(null) {
    val bound = mutableListOf<ServiceConnection>()
    val unbound = mutableListOf<ServiceConnection>()
    var bindResult = true
    var startServiceError: RuntimeException? = null
    var startActivityError: RuntimeException? = null
    var stops = 0

    override fun getPackageName() = "com.doujin.audio"
    override fun startActivity(intent: Intent) {
        startActivityError?.let { throw it }
    }
    override fun startService(intent: Intent): ComponentName? {
        startServiceError?.let { throw it }
        return null
    }
    override fun bindService(intent: Intent, connection: ServiceConnection, flags: Int): Boolean {
        bound.add(connection)
        return bindResult
    }
    override fun unbindService(connection: ServiceConnection) {
        check(connection in bound && connection !in unbound)
        unbound.add(connection)
    }
    override fun stopService(intent: Intent): Boolean {
        stops++
        return true
    }
}
