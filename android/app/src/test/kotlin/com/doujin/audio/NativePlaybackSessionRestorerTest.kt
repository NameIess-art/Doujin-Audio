package com.doujin.audio

import com.doujin.audio.player.session.*

import org.junit.Assert.assertEquals
import org.junit.Test

class NativePlaybackSessionRestorerTest {
    @Test
    fun `restored queue keeps persisted queue metadata`() {
        val stored = storedSession(
            queue = listOf(
                StoredNativePlaybackQueueItem(
                    path = "first-path",
                    uri = "first-uri",
                    title = "First",
                    subtitle = "One",
                    artUri = "first-art",
                    candidateUris = listOf(
                        "https://example.com/first.mp3",
                        "https://backup.example.com/first.mp3"
                    )
                ),
                StoredNativePlaybackQueueItem(
                    path = "second-path",
                    uri = "second-uri",
                    title = "Second",
                    subtitle = null,
                    artUri = null
                )
            )
        )

        val restored = stored.restoredQueue()

        assertEquals(listOf("first-path", "second-path"), restored.map { it.path })
        assertEquals(listOf("First", "Second"), restored.map { it.title })
        assertEquals(
            listOf(
                "first-uri",
                "https://example.com/first.mp3",
                "https://backup.example.com/first.mp3"
            ),
            restored.first().candidateUris
        )
        assertEquals(listOf("second-uri"), restored[1].candidateUris)
    }

    @Test
    fun `restored queue falls back to current persisted item`() {
        val stored = storedSession(queue = emptyList())

        val restored = stored.restoredQueue()

        assertEquals(1, restored.size)
        assertEquals(stored.path, restored.single().path)
        assertEquals(stored.uri, restored.single().uri)
    }

    private fun storedSession(
        queue: List<StoredNativePlaybackQueueItem>
    ): StoredNativePlaybackSession {
        return StoredNativePlaybackSession(
            sessionId = "session",
            uri = "uri",
            path = "path",
            title = "Title",
            subtitle = "Subtitle",
            artUri = "art",
            positionMs = 10,
            volume = 1f,
            speed = 1f,
            skipSilenceEnabled = false,
            noiseReductionEnabled = false,
            eqEnabled = false,
            eqPresetId = null,
            eqBandLevels = emptyMap(),
            volumeNormalizationEnabled = false,
            panning = 0f,
            repeatOne = false,
            repeatAll = false,
            shuffleModeEnabled = false,
            queueStartIndex = 0,
            queue = queue,
            channelSwapEnabled = false,
            playing = true,
            playWhenReady = true
        )
    }
}
