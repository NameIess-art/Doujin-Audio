package com.nameless.audio

import androidx.media3.common.C
import org.junit.Assert.assertEquals
import org.junit.Test

class NativePlayerFactoryTest {
    @Test
    fun `native playback uses local wake mode for screen off audio`() {
        assertEquals(C.WAKE_MODE_LOCAL, nativePlaybackWakeMode())
    }
}
