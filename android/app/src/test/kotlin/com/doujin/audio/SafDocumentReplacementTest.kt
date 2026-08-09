package com.doujin.audio

import com.doujin.audio.storage.replaceSafDocument
import com.doujin.audio.storage.createSafDocumentIfAbsent
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SafDocumentReplacementTest {
    @Test
    fun `createFile returning the target never opens or deletes it`() {
        val files = mutableListOf("metadata.json")
        var writeCalled = false
        var deleteCalled = false

        val result = createSafDocumentIfAbsent(
            listFiles = { emptyList() },
            isTarget = { it.equals("metadata.json", ignoreCase = true) },
            sameDocument = { first, second -> first == second },
            create = { "metadata.json" },
            write = { writeCalled = true; true },
            delete = { deleteCalled = true; files.remove(it) }
        )

        assertFalse(result)
        assertFalse(writeCalled)
        assertFalse(deleteCalled)
        assertTrue(files.single() == "metadata.json")
    }

    @Test
    fun `preserve create removes its new document when a target wins the race`() {
        val files = mutableListOf<String>()
        var listCount = 0
        var writeCalled = false

        val result = createSafDocumentIfAbsent(
            listFiles = {
                listCount++
                if (listCount == 1) emptyList() else files + "concurrent"
            },
            isTarget = { it == "concurrent" },
            sameDocument = { first, second -> first == second },
            create = { "created".also(files::add) },
            write = { writeCalled = true; true },
            delete = { files.remove(it) }
        )

        assertFalse(result)
        assertFalse(writeCalled)
        assertFalse(files.contains("created"))
    }

    @Test
    fun `create failure preserves existing target`() {
        val files = linkedMapOf("track.mp3" to "old")

        val result = replace(files, createFails = true)

        assertFalse(result)
        assertTrue(files["track.mp3"] == "old")
    }

    @Test
    fun `write failure preserves existing target`() {
        val files = linkedMapOf("track.mp3" to "old")

        val result = replace(files, writeFails = true)

        assertFalse(result)
        assertTrue(files["track.mp3"] == "old")
    }

    @Test
    fun `commit rename failure restores existing target`() {
        val files = linkedMapOf("track.mp3" to "old")

        val result = replace(files, commitRenameFails = true)

        assertFalse(result)
        assertTrue(files["track.mp3"] == "old")
        assertFalse(files.containsKey("track.mp3.doujin.bak"))
    }

    @Test
    fun `rollback failure leaves the only old copy under backup name`() {
        val files = linkedMapOf("track.mp3" to "old")

        val result = replace(
            files,
            commitRenameFails = true,
            rollbackRenameFails = true
        )

        assertFalse(result)
        assertTrue(files["track.mp3.doujin.bak"] == "old")
    }

    @Test
    fun `successful replacement recovers stale backup and removes artifacts`() {
        val files = linkedMapOf("track.mp3.doujin.bak" to "old")

        val result = replace(files)

        assertTrue(result)
        assertTrue(files["track.mp3"] == "new")
        assertFalse(files.containsKey("track.mp3.doujin.part"))
        assertFalse(files.containsKey("track.mp3.doujin.bak"))
    }

    private fun replace(
        files: LinkedHashMap<String, String>,
        createFails: Boolean = false,
        writeFails: Boolean = false,
        commitRenameFails: Boolean = false,
        rollbackRenameFails: Boolean = false
    ): Boolean {
        val targetName = "track.mp3"
        val existing = files.keys.firstOrNull { it == targetName }
        val backup = files.keys.firstOrNull { it == "$targetName.doujin.bak" }
        return replaceSafDocument(
            targetName = targetName,
            existing = existing,
            staleBackup = backup,
            createTemp = {
                if (createFails) null else "$targetName.doujin.part".also { files[it] = "" }
            },
            writeTemp = { temp ->
                if (writeFails) false else true.also { files[temp] = "new" }
            },
            rename = { source, destination ->
                val isCommit = source.endsWith(".doujin.part") && destination == targetName
                val isRollback = source.endsWith(".doujin.bak") && destination == targetName
                if (isCommit && commitRenameFails || isRollback && rollbackRenameFails) {
                    null
                } else {
                    files.remove(source)?.let { value ->
                        files[destination] = value
                        destination
                    }
                }
            },
            delete = { file -> files.remove(file) != null }
        )
    }
}
