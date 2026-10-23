@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.doujin.audio

import com.doujin.audio.player.common.*

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.TrackGroup
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.source.MediaSource.MediaPeriodId
import androidx.media3.exoplayer.source.SinglePeriodTimeline
import androidx.media3.exoplayer.source.TrackGroupArray
import androidx.media3.exoplayer.trackselection.FixedTrackSelection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class NativePlayerFactoryTest {
    @Test
    fun `item headers follow every HLS request without leaking into the next item`() {
        val requests = mutableListOf<DataSpec>()
        val delegate = DataSource.Factory {
            object : DataSource {
                override fun addTransferListener(listener: TransferListener) = Unit
                override fun open(dataSpec: DataSpec): Long { requests.add(dataSpec); return 0L }
                override fun read(buffer: ByteArray, offset: Int, length: Int): Int = -1
                override fun getUri(): android.net.Uri? = null
                override fun close() = Unit
            }
        }
        val queue = com.doujin.audio.player.session.NativePlaybackQueue(listOf(
            com.doujin.audio.player.session.NativeMediaItemDescriptor("chapter", "https://example.com/a.m3u8", "A", null, null,
                httpHeaders = mapOf("Referer" to "https://japaneseasmr.com/")),
            com.doujin.audio.player.session.NativeMediaItemDescriptor("ordinary", "https://other.test/a.wav", "B", null, null)))
        for (uri in listOf("https://example.com/a.m3u8", "https://cdn.test/segment.ts", "https://cdn.test/key")) {
            nativePlaybackMediaDataSourceFactory(delegate, queue.mediaItems[0]).createDataSource()
                .open(DataSpec.Builder().setUri(uri).build())
        }
        nativePlaybackMediaDataSourceFactory(delegate, queue.mediaItems[1]).createDataSource()
            .open(DataSpec.Builder().setUri("https://other.test/a.wav").build())
        requests.take(3).forEach { assertEquals("https://japaneseasmr.com/", it.httpRequestHeaders["Referer"]) }
        assertTrue(requests.last().httpRequestHeaders.isEmpty())
    }

    @Test
    fun `Japanese stream headers are scoped to exact media hosts`() {
        assertEquals("https://japaneseasmr.com/", nativePlaybackRequestHeadersForHost("v.weeab0o.xyz")["Referer"])
        assertTrue(nativePlaybackRequestHeadersForHost("v.weeab0o.xyz.evil.test").isEmpty())
        assertTrue(nativePlaybackRequestHeadersForHost("example.com").isEmpty())
    }

    @Test
    fun `native HLS chapters use separate media ids and bounded clipping configurations`() {
        val queue = com.doujin.audio.player.session.NativePlaybackQueue(listOf(
            com.doujin.audio.player.session.NativeMediaItemDescriptor("chapter-a", "https://v.weeab0o.xyz/a.m3u8", "A", null, null,
                clipStartMs = 10_000L, clipEndMs = 20_000L),
            com.doujin.audio.player.session.NativeMediaItemDescriptor("chapter-b", "https://v.weeab0o.xyz/a.m3u8", "B", null, null,
                clipStartMs = 20_000L, clipEndMs = 40_000L)))
        val items = queue.mediaItems
        assertEquals("chapter-a", items[0].mediaId)
        assertEquals("chapter-b", items[1].mediaId)
        assertEquals(10_000L, items[0].clippingConfiguration.startPositionMs)
        assertEquals(40_000L, items[1].clippingConfiguration.endPositionMs)
        assertEquals("application/x-mpegURL", items[0].localConfiguration!!.mimeType)
    }

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

    @Test
    fun `local video stops loading at its byte target before the time threshold`() {
        for (uri in listOf("file:///storage/video.mp4", "content://media/video/2")) {
            val control = nativePlaybackLoadControl()
            val parameters = loadingParameters(uri, bufferedUs = 500_000L)
            val video = TrackGroup(Format.Builder().setSampleMimeType("video/avc").build())
            control.onPrepared(parameters.playerId)
            control.onTracksSelected(parameters, TrackGroupArray(video),
                arrayOf(FixedTrackSelection(video, 0)))
            val allocator = control.getAllocator(parameters.playerId)
            while (allocator.totalBytesAllocated < DefaultLoadControl.DEFAULT_VIDEO_BUFFER_SIZE_FOR_LOCAL_PLAYBACK) {
                allocator.allocate()
            }

            assertFalse(uri, control.shouldContinueLoading(parameters))
            assertEquals(0L, control.getBackBufferDurationUs(parameters.playerId))
            control.onReleased(parameters.playerId)
        }
    }

    @Test
    fun `network audio retains sixty seconds of forward buffering even at byte target`() {
        val control = nativePlaybackLoadControl()
        val parameters = loadingParameters("https://asmr.one/track.mp3", 59_000_000L)
        control.onPrepared(parameters.playerId)
        val allocator = control.getAllocator(parameters.playerId)
        while (allocator.totalBytesAllocated < DefaultLoadControl.DEFAULT_MIN_BUFFER_SIZE) allocator.allocate()

        assertTrue(control.shouldContinueLoading(parameters))
        assertFalse(control.shouldContinueLoading(loadingParameters("https://asmr.one/track.mp3", 60_000_000L)))
        assertEquals(0L, control.getBackBufferDurationUs(parameters.playerId))
        control.onReleased(parameters.playerId)
    }

    @Test
    fun `network audio keeps the maximum and startup thresholds for overnight playback`() {
        val control = nativePlaybackLoadControl()
        val uri = "https://asmr.one/track.mp3"
        val parameters = loadingParameters(uri, 0L)
        control.onPrepared(parameters.playerId)

        assertTrue(control.shouldContinueLoading(parameters))
        assertTrue(control.shouldContinueLoading(loadingParameters(uri, 119_999_999L)))
        assertFalse(control.shouldContinueLoading(loadingParameters(uri, 120_000_000L)))
        assertFalse(control.shouldStartPlayback(loadingParameters(uri, 2_499_999L)))
        assertTrue(control.shouldStartPlayback(loadingParameters(uri, 2_500_000L)))
        assertFalse(control.shouldStartPlayback(loadingParameters(uri, 4_999_999L, rebuffering = true)))
        assertTrue(control.shouldStartPlayback(loadingParameters(uri, 5_000_000L, rebuffering = true)))
        control.onReleased(parameters.playerId)
    }

    @Test
    fun `local files can start after one second without the network startup delay`() {
        val control = nativePlaybackLoadControl()
        val uri = "file:///storage/track.flac"
        val parameters = loadingParameters(uri, 0L)
        control.onPrepared(parameters.playerId)

        assertFalse(control.shouldStartPlayback(loadingParameters(uri, 999_999L)))
        assertTrue(control.shouldStartPlayback(loadingParameters(uri, 1_000_000L)))
        control.onReleased(parameters.playerId)
    }

    private fun loadingParameters(uri: String, bufferedUs: Long, rebuffering: Boolean = false): LoadControl.Parameters {
        val timeline = SinglePeriodTimeline(300_000_000L, true, false, false, null,
            MediaItem.fromUri(uri))
        return LoadControl.Parameters(PlayerId.UNSET, timeline, MediaPeriodId(timeline.getUidOfPeriod(0)),
            0L, bufferedUs, 1f, true, rebuffering, C.TIME_UNSET, C.TIME_UNSET)
    }
}
