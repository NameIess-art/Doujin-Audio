package com.doujin.audio

import android.os.Handler
import android.os.Looper
import com.doujin.audio.player.effects.NativePlaybackResumeFade
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class NativePlaybackResumeFadeTest {
    @Test
    fun `cancelling a partial fade restores every resumed session and retires ticks`() {
        val levels = mutableMapOf<String, Float>()
        val fade = NativePlaybackResumeFade(Handler(Looper.getMainLooper())) { id, level -> levels[id] = level }
        fade.start(listOf("A", "B"))
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(2))
        assertEquals(0.2f, levels["B"]!!, 0.001f)

        fade.cancel()
        levels["A"] = 0.7f
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(10))
        assertEquals(0.7f, levels["A"]!!, 0f)
        assertEquals(1f, levels["B"]!!, 0f)
    }

    @Test
    fun `replacing a fade before its first tick restores previous targets`() {
        val levels = mutableMapOf<String, Float>()
        val fade = NativePlaybackResumeFade(Handler(Looper.getMainLooper())) { id, level -> levels[id] = level }
        fade.start(listOf("A", "B"))
        fade.start(listOf("C"))
        assertEquals(1f, levels["A"]!!, 0f)
        assertEquals(1f, levels["B"]!!, 0f)
        assertEquals(0f, levels["C"]!!, 0f)
        fade.cancel()
        assertEquals(1f, levels["C"]!!, 0f)
    }
}
