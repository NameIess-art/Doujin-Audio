package com.doujin.audio

import com.doujin.audio.storage.replaceSafDocument
import com.doujin.audio.storage.createSafDocumentIfAbsent
import com.doujin.audio.storage.JsonDocumentOperationLocks
import com.doujin.audio.storage.commitSafDocumentReplacement
import com.doujin.audio.storage.recoverSafDocument
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

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
    fun `commit validation failure restores existing target`() {
        val files = linkedMapOf(
            "track.mp3" to "old",
            "track.mp3.doujin.part" to "invalid"
        )

        val committed = commitSafDocumentReplacement(
            targetName = "track.mp3",
            current = "track.mp3",
            temporary = "track.mp3.doujin.part",
            isValidCommitted = { files[it] == "new" },
            rename = { source, destination ->
                files.remove(source)?.let { value ->
                    files[destination] = value
                    destination
                }
            },
            delete = { file -> files.remove(file) != null }
        )

        assertNull(committed)
        assertEquals("old", files["track.mp3"])
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

    @Test
    fun `missing target restores valid backup before read`() {
        val files = linkedMapOf("metadata.json.doujin.bak" to "old")

        val recovery = recover(files)

        assertFalse(recovery.failed)
        assertEquals("metadata.json", recovery.document)
        assertEquals("old", files["metadata.json"])
        assertFalse(files.containsKey("metadata.json.doujin.bak"))
    }

    @Test
    fun `valid target wins over stale transaction artifacts`() {
        val files = linkedMapOf(
            "metadata.json" to "current",
            "metadata.json.doujin.bak" to "old",
            "metadata.json.doujin.part" to "staged"
        )

        val recovery = recover(files)

        assertFalse(recovery.failed)
        assertEquals("metadata.json", recovery.document)
        assertEquals(mapOf("metadata.json" to "current"), files)
    }

    @Test
    fun `valid staged create is promoted when no target or backup exists`() {
        val files = linkedMapOf("metadata.json.doujin.part" to "staged")

        val recovery = recover(files)

        assertFalse(recovery.failed)
        assertEquals("metadata.json", recovery.document)
        assertEquals("staged", files["metadata.json"])
    }

    @Test
    fun `invalid transaction artifacts fail recovery instead of reporting missing`() {
        val files = linkedMapOf("metadata.json.doujin.bak" to "invalid")

        val recovery = recover(files)

        assertTrue(recovery.failed)
        assertNull(recovery.document)
    }

    @Test
    fun `invalid target without recovery artifacts fails instead of looking valid`() {
        val files = linkedMapOf("metadata.json" to "invalid")

        val recovery = recover(files)

        assertTrue(recovery.failed)
        assertNull(recovery.document)
        assertEquals("invalid", files["metadata.json"])
    }

    @Test
    fun `same target operations are serialized while different targets proceed`() {
        val executor = Executors.newFixedThreadPool(3)
        val firstEntered = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        val sameTargetEntered = CountDownLatch(1)
        val otherTargetEntered = CountDownLatch(1)
        try {
            executor.submit {
                JsonDocumentOperationLocks.withLock("same") {
                    firstEntered.countDown()
                    releaseFirst.await(2, TimeUnit.SECONDS)
                }
            }
            assertTrue(firstEntered.await(1, TimeUnit.SECONDS))
            executor.submit {
                JsonDocumentOperationLocks.withLock("same") {
                    sameTargetEntered.countDown()
                }
            }
            executor.submit {
                JsonDocumentOperationLocks.withLock("other") {
                    otherTargetEntered.countDown()
                }
            }

            assertTrue(otherTargetEntered.await(1, TimeUnit.SECONDS))
            assertFalse(sameTargetEntered.await(100, TimeUnit.MILLISECONDS))
            releaseFirst.countDown()
            assertTrue(sameTargetEntered.await(1, TimeUnit.SECONDS))
        } finally {
            releaseFirst.countDown()
            executor.shutdownNow()
        }
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

    private fun recover(
        files: LinkedHashMap<String, String>
    ) = recoverSafDocument(
        targetName = "metadata.json",
        existing = files.keys.firstOrNull { it == "metadata.json" },
        staleBackup = files.keys.firstOrNull { it == "metadata.json.doujin.bak" },
        staleTemp = files.keys.firstOrNull { it == "metadata.json.doujin.part" },
        isValid = { files[it] != "invalid" },
        rename = { source, destination ->
            files.remove(source)?.let { value ->
                files[destination] = value
                destination
            }
        },
        delete = { file -> files.remove(file) != null }
    )
}
