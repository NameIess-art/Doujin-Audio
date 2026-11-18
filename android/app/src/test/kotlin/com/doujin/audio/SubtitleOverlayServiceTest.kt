package com.doujin.audio

import android.content.Context
import android.os.Looper
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import com.doujin.audio.subtitle.SubtitleOverlayService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowWindowManagerImpl
import org.robolectric.shadow.api.Shadow

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class SubtitleOverlayServiceTest {
    @Test
    fun `empty subtitle keeps the visible overlay at the last cue size`() {
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
        }
    }
}
