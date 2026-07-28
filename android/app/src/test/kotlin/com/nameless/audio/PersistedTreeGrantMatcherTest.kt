package com.nameless.audio

import com.nameless.audio.storage.PersistedTreeGrantCandidate
import com.nameless.audio.storage.findMatchingPersistedTreeGrant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PersistedTreeGrantMatcherTest {
    @Test
    fun `returns only the readable tree grant with an exact normalized path`() {
        val result = findMatchingPersistedTreeGrant(
            "/storage/emulated/0/Download/Music/../Music",
            listOf(
                candidate("content://unreadable", false, true, "/storage/emulated/0/Download/Music"),
                candidate("content://document", true, false, "/storage/emulated/0/Download/Music"),
                candidate("content://parent", true, true, "/storage/emulated/0/Download"),
                candidate("content://match", true, true, "/storage/emulated/0/Download/Music")
            )
        )

        assertEquals("content://match", result)
    }

    @Test
    fun `returns null when no readable tree grant matches`() {
        val result = findMatchingPersistedTreeGrant(
            "/storage/emulated/0/Music",
            listOf(
                candidate("content://other", true, true, "/storage/emulated/0/Download"),
                candidate("content://expired", false, true, "/storage/emulated/0/Music")
            )
        )

        assertNull(result)
    }

    private fun candidate(
        uri: String,
        readable: Boolean,
        isTree: Boolean,
        path: String?
    ) = PersistedTreeGrantCandidate(uri, readable, isTree, path)
}
