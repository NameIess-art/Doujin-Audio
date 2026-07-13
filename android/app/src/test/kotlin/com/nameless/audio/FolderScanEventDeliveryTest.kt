package com.nameless.audio

import com.nameless.audio.scanner.shouldDeliverQueuedFolderScanEvent
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FolderScanEventDeliveryTest {
    @Test
    fun `queued terminal event remains deliverable after scan worker completes`() {
        assertTrue(
            shouldDeliverQueuedFolderScanEvent(
                closed = false,
                cancelled = false,
                listenerGenerationId = "generation-1",
                eventGenerationId = "generation-1",
                listenerStillCurrent = true
            )
        )
    }

    @Test
    fun `queued event is rejected for cancelled or replaced listeners`() {
        assertFalse(
            shouldDeliverQueuedFolderScanEvent(
                closed = false,
                cancelled = true,
                listenerGenerationId = "generation-1",
                eventGenerationId = "generation-1",
                listenerStillCurrent = true
            )
        )
        assertFalse(
            shouldDeliverQueuedFolderScanEvent(
                closed = false,
                cancelled = false,
                listenerGenerationId = "generation-2",
                eventGenerationId = "generation-1",
                listenerStillCurrent = false
            )
        )
    }
}
