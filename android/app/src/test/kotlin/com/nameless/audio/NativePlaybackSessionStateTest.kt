package com.nameless.audio

import androidx.media3.common.C
import androidx.media3.common.Player
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NativePlaybackSessionStateTest {
    @Test
    fun `duration keeps zero duration but filters unset and negative values`() {
        assertNull(durationOrNull(C.TIME_UNSET))
        assertNull(durationOrNull(-1L))
        assertEquals(0L, durationOrNull(0L))
        assertEquals(42L, durationOrNull(42L))
    }

    @Test
    fun `playback state names remain stable for persisted snapshots`() {
        assertEquals("idle", playbackStateName(Player.STATE_IDLE))
        assertEquals("buffering", playbackStateName(Player.STATE_BUFFERING))
        assertEquals("ready", playbackStateName(Player.STATE_READY))
        assertEquals("completed", playbackStateName(Player.STATE_ENDED))
        assertEquals("unknown", playbackStateName(Int.MIN_VALUE))
    }
}
