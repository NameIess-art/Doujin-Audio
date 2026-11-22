package com.doujin.audio

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.ContextWrapper
import android.content.Intent
import android.content.ServiceConnection
import com.doujin.audio.subtitle.SubtitleOverlayCoordinator
import com.doujin.audio.subtitle.SubtitleOverlayMethodHandler
import com.doujin.audio.subtitle.SubtitleOverlayService
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowSettings

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class SubtitleOverlayCoordinatorTest {
    @Before
    fun grantOverlayPermission() {
        ShadowSettings.setCanDrawOverlays(true)
    }

    @After
    fun resetOverlayPermission() {
        ShadowSettings.setCanDrawOverlays(false)
    }

    @Test
    fun `stop before connection unbinds pending service stops it and ignores late binder`() {
        val context = OverlayContext()
        val coordinator = SubtitleOverlayCoordinator(context)
        assertTrue(coordinator.start())
        val oldConnection = context.bound.single()
        assertEquals(1, context.starts)

        coordinator.stop()
        oldConnection.onServiceConnected(null, null)

        assertEquals(listOf(oldConnection), context.unbound)
        assertEquals(1, context.stops)
        assertTrue(coordinator.start())
        oldConnection.onServiceConnected(null, null)
        oldConnection.onServiceDisconnected(null)
        coordinator.stop()
        assertEquals(context.bound, context.unbound)
        assertEquals(2, context.stops)
    }

    @Test
    fun `repeated start does not register another pending binding and dispose only unbinds`() {
        val context = OverlayContext()
        val coordinator = SubtitleOverlayCoordinator(context)
        assertTrue(coordinator.start())
        assertTrue(coordinator.start())
        assertEquals(1, context.bound.size)
        assertEquals(1, context.starts)

        coordinator.dispose()
        coordinator.dispose()
        context.bound.single().onServiceConnected(null, null)

        assertEquals(context.bound, context.unbound)
        assertEquals(0, context.stops)
    }

    @Test
    fun `disconnected service clears connection so subsequent start can rebind`() {
        val context = OverlayContext()
        val coordinator = SubtitleOverlayCoordinator(context)
        assertTrue(coordinator.start())
        val firstConnection = context.bound.single()

        firstConnection.onServiceDisconnected(null)
        assertEquals(listOf(firstConnection), context.unbound)

        assertTrue(coordinator.start())
        assertEquals(2, context.bound.size)
        coordinator.stop()
        assertEquals(context.bound, context.unbound)
        assertEquals(1, context.stops)
    }

    @Test
    fun `failed registration reports false stops started service and can retry`() {
        val context = OverlayContext().apply { bindResult = false }
        val coordinator = SubtitleOverlayCoordinator(context)
        assertFalse(coordinator.start())
        assertEquals(1, context.starts)
        assertEquals(1, context.stops)
        assertTrue(context.unbound.isEmpty())

        context.bindResult = true
        assertTrue(coordinator.start())
        coordinator.stop()
        assertEquals(listOf(context.bound.last()), context.unbound)
        assertEquals(2, context.stops)
    }

    @Test
    fun `start checks overlay permission and unbinds if overlay attachment fails`() {
        val context = OverlayContext()
        val coordinator = SubtitleOverlayCoordinator(context)
        ShadowSettings.setCanDrawOverlays(false)
        assertFalse(coordinator.start())
        assertTrue(context.bound.isEmpty())

        ShadowSettings.setCanDrawOverlays(true)
        assertTrue(coordinator.start())
        val firstConnection = context.bound.single()

        // Simulate permission lost before the service finishes attaching its overlay view.
        ShadowSettings.setCanDrawOverlays(false)
        val serviceController = Robolectric.buildService(SubtitleOverlayService::class.java).create()
        try {
            val binder = serviceController.get().onBind(null)
            firstConnection.onServiceConnected(null, binder)
            assertEquals(listOf(firstConnection), context.unbound)

            // Once permission is granted again, start() binds fresh instead of wedging.
            ShadowSettings.setCanDrawOverlays(true)
            assertTrue(coordinator.start())
            assertEquals(2, context.bound.size)
            context.bound.last().onServiceConnected(null, binder)
            assertEquals(1, context.unbound.size)
            assertTrue(coordinator.start())
            coordinator.stop()
            assertEquals(context.bound, context.unbound)
        } finally {
            serviceController.destroy()
        }
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
    fun `bind failure and missing settings activity propagate structured channel errors`() {
        val context = OverlayContext().apply {
            bindServiceError = IllegalStateException("bind restricted")
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

    @Test
    fun `updateStyle rejects missing required fields and validates backgroundOpacity before updating`() {
        val context = OverlayContext()
        val coordinator = SubtitleOverlayCoordinator(context)
        val handler = SubtitleOverlayMethodHandler(coordinator)

        fun invoke(args: Map<String, Any?>): Map<*, *> {
            var response: Any? = null
            val result = object : MethodChannel.Result {
                override fun success(result: Any?) { response = result }
                override fun error(code: String, message: String?, details: Any?) = error("Envelope expected")
                override fun notImplemented() = error("Known method expected")
            }
            handler.onMethodCall(MethodCall("updateStyle", args), result)
            return response as Map<*, *>
        }

        val valid = mapOf(
            "fontSize" to 18.0,
            "backgroundColor" to "#33000000",
            "textColor" to "#FFFFFFFF",
            "fontFamily" to "",
            "borderDepth" to 0.5,
            "backgroundOpacity" to 0.2
        )

        for (requiredKey in listOf("fontSize", "backgroundColor", "textColor", "fontFamily", "borderDepth")) {
            val missing = valid - requiredKey
            val response = invoke(missing)
            assertEquals(requiredKey, false, response["ok"])
            assertEquals(requiredKey, "invalid_argument", response["errorCode"])
        }

        // Invalid backgroundOpacity must fail BEFORE mutating pendingStyle.
        val badOpacity = invoke(valid + ("backgroundOpacity" to 1.5))
        assertEquals(false, badOpacity["ok"])
        assertEquals("invalid_argument", badOpacity["errorCode"])
        val pendingStyleField = SubtitleOverlayCoordinator::class.java.getDeclaredField("pendingStyle")
            .apply { isAccessible = true }
        assertEquals(null, pendingStyleField.get(coordinator))

        // Valid payload succeeds and updates pendingStyle.
        val okResponse = invoke(valid)
        assertEquals(true, okResponse["ok"])
        assertTrue(pendingStyleField.get(coordinator) != null)
    }
}

private class OverlayContext : ContextWrapper(null) {
    val bound = mutableListOf<ServiceConnection>()
    val unbound = mutableListOf<ServiceConnection>()
    var bindResult = true
    var bindServiceError: RuntimeException? = null
    var startActivityError: RuntimeException? = null
    var starts = 0
    var stops = 0

    override fun getApplicationContext() = this
    override fun getPackageName() = "com.doujin.audio"
    override fun startActivity(intent: Intent) {
        startActivityError?.let { throw it }
    }
    override fun startService(intent: Intent): ComponentName? {
        starts++
        return null
    }
    override fun bindService(intent: Intent, connection: ServiceConnection, flags: Int): Boolean {
        bindServiceError?.let { throw it }
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
