package com.nameless.audio

import com.nameless.audio.player.common.*

import androidx.media3.common.C
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlayerFactoryTest {
    @Test
    fun `network queues keep the network wake mode for background streaming`() {
        assertEquals(
            C.WAKE_MODE_NETWORK,
            nativePlaybackWakeModeForUris(listOf("https://asmr.one/media/track.mp3"))
        )
    }

    @Test
    fun `local only queues avoid the wifi lock that network wake mode implies`() {
        assertEquals(
            C.WAKE_MODE_LOCAL,
            nativePlaybackWakeModeForUris(
                listOf("file:///storage/emulated/0/a.flac", "content://media/audio/2", null)
            )
        )
    }

    @Test
    fun `a single network item promotes the whole queue so prefetch stays covered`() {
        assertEquals(
            C.WAKE_MODE_NETWORK,
            nativePlaybackWakeModeForUris(
                listOf("file:///storage/emulated/0/a.flac", "http://asmr-100.com/b.mp3")
            )
        )
    }

    @Test
    fun `empty queues do not hold a wifi lock`() {
        assertEquals(C.WAKE_MODE_LOCAL, nativePlaybackWakeModeForUris(emptyList()))
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
