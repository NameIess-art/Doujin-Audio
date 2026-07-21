package com.nameless.audio

import com.nameless.audio.player.common.*

import androidx.media3.common.C
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlayerFactoryTest {
    @Test
    fun `native playback uses network wake mode for background streaming`() {
        assertEquals(C.WAKE_MODE_NETWORK, nativePlaybackWakeMode())
    }

    @Test
    fun `native playback keeps platform spatialization from changing stereo layout`() {
        val attributes = nativePlaybackAudioAttributes()

        assertEquals(C.USAGE_MEDIA, attributes.usage)
        assertEquals(C.AUDIO_CONTENT_TYPE_MUSIC, attributes.contentType)
        assertEquals(C.SPATIALIZATION_BEHAVIOR_NEVER, attributes.spatializationBehavior)
    }

    @Test
    fun `ASMR media hosts receive the gateway language header`() {
        val headers = nativePlaybackRequestHeadersForHost("raw.kiko-play-niptan.one")

        assertEquals("zh-CN,zh;q=0.9,en;q=0.8", headers["Accept-Language"])
        assertTrue(nativePlaybackRequestHeadersForHost("example.com").isEmpty())
    }
}
