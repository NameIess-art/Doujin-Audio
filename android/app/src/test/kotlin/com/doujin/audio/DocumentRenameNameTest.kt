package com.doujin.audio

import com.doujin.audio.storage.preserveDocumentExtension
import org.junit.Assert.assertEquals
import org.junit.Test

class DocumentRenameNameTest {
    @Test
    fun `rename retains display name extension independently of document ID`() {
        for ((displayName, expected) in listOf(
            "Track.mp3" to "New.Title.mp3",
            "cover.original.jpg" to "New.Title.jpg",
            "Voice.FLAC" to "New.Title.FLAC",
            "README" to "New.Title",
            ".hidden" to "New.Title"
        )) {
            assertEquals(expected, preserveDocumentExtension(displayName, "New.Title"))
        }
    }
}
