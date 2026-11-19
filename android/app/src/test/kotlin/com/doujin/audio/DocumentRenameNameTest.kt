package com.doujin.audio

import com.doujin.audio.storage.preserveDocumentExtension
import com.doujin.audio.storage.sanitizeCacheExtension
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

    @Test
    fun `cache extension sanitizer strips traversal separators and unsafe characters`() {
        assertEquals("mp3", sanitizeCacheExtension("Track.mp3", "bin"))
        assertEquals("bin", sanitizeCacheExtension("../evil", "bin"))
        assertEquals("img", sanitizeCacheExtension("cover.jpg/../../evil", "img"))
        assertEquals("img", sanitizeCacheExtension("cover.jpg/..", "img"))
        assertEquals("bin", sanitizeCacheExtension(".hidden", "bin"))
        assertEquals("png", sanitizeCacheExtension("a\\b\\cover.p..ng", "img"))
    }
}
