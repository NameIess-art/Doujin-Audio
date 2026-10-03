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
    fun `replacement validates imported source removal before deleting target backup`() {
        val files = linkedMapOf("track.srt" to "old", "selected.srt" to "new")
        val result = replaceSafDocument(
            targetName = "track.srt",
            existing = "track.srt",
            staleBackup = null,
            createTemp = { "temporary".also { files[it] = "" } },
            writeTemp = { files[it] = "new"; true },
            isValidCommitted = {
                assertEquals("new", files[it])
                assertEquals("old", files["track.srt.doujin.bak"])
                false
            },
            rename = { source, destination ->
                files.remove(source)?.let { bytes -> files[destination] = bytes; destination }
            },
            delete = { files.remove(it) != null }
        )
        assertNull(result)
        assertEquals(mapOf("track.srt" to "old", "selected.srt" to "new"), files)
    }

    @Test
    fun `replacement returns provider document after commit rename`() {
        data class Document(val uri: String, val name: String)
        val existing = Document("old-uri", "cover.jpg")
        val temporary = Document("temporary-uri", "cover.jpg.doujin.part")
        val committed = Document("committed-uri", "cover.jpg")
        val deleted = mutableListOf<Document>()
        val result = replaceSafDocument(
            targetName = "cover.jpg",
            existing = existing,
            staleBackup = null,
            createTemp = { temporary },
            writeTemp = { true },
            rename = { document, name ->
                if (document == temporary) committed else Document("backup-uri", name)
            },
            delete = { deleted.add(it); true }
        )

        assertEquals(committed, result)
        assertEquals(listOf(Document("backup-uri", "cover.jpg.doujin.bak")), deleted)
    }

    @Test
    fun `partial write exception preserves old subtitle and removes temporary`() {
        val files = linkedMapOf("track.srt" to "old subtitle")
        val result = replaceSafDocument(
            targetName = "track.srt",
            existing = "track.srt",
            staleBackup = null,
            createTemp = { "track.srt.doujin.part".also { files[it] = "" } },
            writeTemp = { files[it] = "partial subtitle"; throw java.io.IOException("storage full") },
            rename = { _, _ -> error("Failed write must not rename the old document") },
            delete = { files.remove(it) != null }
        )

        assertNull(result)
        assertEquals(mapOf("track.srt" to "old subtitle"), files)
    }

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
    fun `failed stale cleanup keeps validated target readable but blocks mutations`() {
        for (artifact in listOf("backup", "staged")) {
            for (throws in listOf(false, true)) {
                for (forRead in listOf(false, true)) {
                    val files = linkedMapOf("target" to "current", artifact to "old")
                    val recovery = recoverSafDocument(
                        targetName = "target",
                        existing = "target",
                        staleBackup = artifact.takeIf { it == "backup" },
                        staleTemp = artifact.takeIf { it == "staged" },
                        forRead = forRead,
                        isValid = { files[it] != "invalid" },
                        rename = { _, _ -> error("A validated target must not be renamed") },
                        delete = {
                            if (throws) throw java.io.IOException("Cleanup denied")
                            false
                        }
                    )

                    assertEquals(!forRead, recovery.failed)
                    assertEquals("target", recovery.document)
                    assertEquals(mapOf("target" to "current", artifact to "old"), files)
                }
            }
        }
    }

    @Test
    fun `read still fails when cleanup is required to restore a valid backup`() {
        val files = linkedMapOf("target" to "invalid", "backup" to "old")
        val recovery = recoverSafDocument(
            targetName = "target",
            existing = "target",
            staleBackup = "backup",
            staleTemp = null,
            forRead = true,
            isValid = { files[it] != "invalid" },
            rename = { _, _ -> error("Failed cleanup must prevent restoration") },
            delete = { false }
        )

        assertTrue(recovery.failed)
        assertNull(recovery.document)
        assertEquals(mapOf("target" to "invalid", "backup" to "old"), files)
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
    fun `read failure during recovery preserves target backup and staged documents`() {
        val documents = listOf("target", "backup", "staged")
        for (unreadable in documents) {
            val files = linkedMapOf("target" to "current", "backup" to "old", "staged" to "new")
            val recovery = recoverSafDocument(
                targetName = "target",
                existing = "target",
                staleBackup = "backup",
                staleTemp = "staged",
                forRead = true,
                isValid = {
                    if (it == unreadable) throw java.io.IOException("Provider is unavailable")
                    documents.indexOf(it) > documents.indexOf(unreadable)
                },
                rename = { source, destination ->
                    files.remove(source)?.let { files[destination] = it; destination }
                },
                delete = { files.remove(it) != null }
            )

            assertTrue(recovery.failed)
            assertEquals(mapOf("target" to "current", "backup" to "old", "staged" to "new"), files)
        }
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
        ) != null
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
