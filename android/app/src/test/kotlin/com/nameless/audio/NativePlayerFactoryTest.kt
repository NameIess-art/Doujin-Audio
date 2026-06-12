package com.nameless.audio

import androidx.media3.common.C
import org.junit.Assert.assertEquals
import org.junit.Test

class NativePlayerFactoryTest {
    @Test
    fun `native playback uses network wake mode for background streaming`() {
        assertEquals(C.WAKE_MODE_NETWORK, nativePlaybackWakeMode())
    }
}
