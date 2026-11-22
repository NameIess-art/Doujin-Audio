package com.doujin.audio

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Looper
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import com.doujin.audio.subtitle.SubtitleOverlayService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowSettings
import org.robolectric.shadows.ShadowWindowManagerImpl
import org.robolectric.shadow.api.Shadow

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class SubtitleOverlayServiceTest {
    @Test
    fun `empty subtitle keeps the visible overlay at the last cue size`() {
        ShadowSettings.setCanDrawOverlays(true)
        val controller = Robolectric.buildService(SubtitleOverlayService::class.java).create()
        try {
            val service = controller.get()
            val manager = service.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val window = Shadow.extract<ShadowWindowManagerImpl>(manager).views.single() as TextView
            val looper = shadowOf(Looper.getMainLooper())

            looper.idle()
            assertEquals(View.VISIBLE, window.visibility)
            assertTrue(window.text.isEmpty())
            val initialHeight = window.height
            assertTrue(initialHeight > 0)

            val multiline = "First line of the subtitle\nSecond line\nThird line"
            service.updateSubtitle(multiline)
            looper.idle()
            assertEquals(multiline, window.text.toString())
            val cueWidth = window.width
            val cueHeight = window.height
            assertTrue(cueHeight > initialHeight)

            service.updateSubtitle("")
            looper.idle()
            assertEquals(View.VISIBLE, window.visibility)
            assertTrue(window.text.isEmpty())
            assertEquals(cueWidth, window.width)
            assertEquals(cueHeight, window.height)

            service.updateSubtitle("Short cue")
            looper.idle()
            assertEquals("Short cue", window.text.toString())
            assertTrue(window.width < cueWidth)
            assertTrue(window.height < cueHeight)
        } finally {
            controller.destroy()
            ShadowSettings.setCanDrawOverlays(false)
        }
    }

    @Test
    fun `missing overlay permission skips window attachment without crashing destroy`() {
        ShadowSettings.setCanDrawOverlays(false)
        val controller = Robolectric.buildService(SubtitleOverlayService::class.java).create()
        try {
            val service = controller.get()
            val manager = service.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            assertTrue(Shadow.extract<ShadowWindowManagerImpl>(manager).views.isEmpty())
            assertFalse(service.ensureOverlayAttached())

            ShadowSettings.setCanDrawOverlays(true)
            assertTrue(service.ensureOverlayAttached())
            assertEquals(1, Shadow.extract<ShadowWindowManagerImpl>(manager).views.size)
        } finally {
            controller.destroy()
            ShadowSettings.setCanDrawOverlays(false)
        }
    }

    @Test
    fun `service is not sticky and removes overlay when task is removed`() {
        ShadowSettings.setCanDrawOverlays(true)
        val controller = Robolectric.buildService(SubtitleOverlayService::class.java).create()
        try {
            val service = controller.get()
            val manager = service.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            assertEquals(Service.START_NOT_STICKY, service.onStartCommand(Intent(), 0, 1))
            assertEquals(1, Shadow.extract<ShadowWindowManagerImpl>(manager).views.size)

            service.onTaskRemoved(Intent())
            assertTrue(Shadow.extract<ShadowWindowManagerImpl>(manager).views.isEmpty())
            assertTrue(shadowOf(service).isStoppedBySelf)
        } finally {
            controller.destroy()
            ShadowSettings.setCanDrawOverlays(false)
        }
    }

    @Test
    fun `setStyle deduplicates identical style parameters without recreating background`() {
        ShadowSettings.setCanDrawOverlays(true)
        val controller = Robolectric.buildService(SubtitleOverlayService::class.java).create()
        try {
            val service = controller.get()
            val manager = service.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val window = Shadow.extract<ShadowWindowManagerImpl>(manager).views.single() as TextView
            val looper = shadowOf(Looper.getMainLooper())

            service.setStyle(18f, "#88000000", "#FFFFFFFF", "", 0.5f)
            looper.idle()
            val firstBackground = window.background

            service.setStyle(18f, "#88000000", "#FFFFFFFF", "", 0.5f)
            looper.idle()
            assertTrue(window.background === firstBackground)

            service.setStyle(20f, "#88000000", "#FFFFFFFF", "", 0.5f)
            looper.idle()
            assertTrue(window.background !== firstBackground)
        } finally {
            controller.destroy()
            ShadowSettings.setCanDrawOverlays(false)
        }
    }
}
