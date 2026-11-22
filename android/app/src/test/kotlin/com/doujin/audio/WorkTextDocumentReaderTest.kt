package com.doujin.audio

import com.doujin.audio.storage.DocumentTooLargeException
import com.doujin.audio.storage.discoverLocalWorkTexts
import com.doujin.audio.storage.readBoundedDocumentBytes
import com.doujin.audio.storage.readLocalDocumentBytes
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException

class WorkTextDocumentReaderTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun `missing directory fails instead of returning an empty discovery`() {
        assertThrows(IOException::class.java) {
            discoverLocalWorkTexts(File(temporary.root, "missing").absolutePath)
        }
    }

    @Test
    fun `file used as directory fails instead of returning an empty discovery`() {
        val file = temporary.newFile("台本.txt")
        assertThrows(IOException::class.java) { discoverLocalWorkTexts(file.absolutePath) }
    }

    @Test
    fun `successful empty directory yields a reusable empty discovery`() {
        assertTrue(discoverLocalWorkTexts(temporary.newFolder("empty").absolutePath).isEmpty())
    }

    @Test
    fun `nested documents retain original paths and relative ordering`() {
        val root = temporary.newFolder("作品")
        val folder = File(root, "Docs").apply { mkdir() }
        File(folder, "01 台本.TXT").writeText("script")
        File(root, "readme.md").writeText("readme")
        File(root, "track.mp3").writeText("audio")
        val result = discoverLocalWorkTexts(root.absolutePath)
        assertEquals(listOf("Docs/01 台本.TXT", "readme.md"), result.map { it["relativePath"] })
        assertEquals(File(folder, "01 台本.TXT").absolutePath, result.first()["path"])
        assertEquals(listOf("6", "6"), result.map { it["fileSizeBytes"] })
    }

    @Test
    fun `nested subtitle formats are discovered without matching audio names`() {
        val root = temporary.newFolder("作品 字幕")
        val folder = File(root, "Extras/字幕").apply { mkdirs() }
        val extensions = listOf("SRT", "lrc", "vtt", "webvtt", "ass", "ssa")
        extensions.forEach { File(folder, "translation.$it").writeText("subtitle") }
        File(folder, "cover.jpg").writeText("image")

        val result = discoverLocalWorkTexts(root.absolutePath)

        assertEquals(extensions.size, result.size)
        assertEquals(
            extensions.map { "Extras/字幕/translation.$it" }.toSet(),
            result.map { it["relativePath"] }.toSet()
        )
    }

    @Test
    fun `empty document retains zero file size`() {
        val root = temporary.newFolder("empty document")
        File(root, "台本.txt").writeBytes(byteArrayOf())

        val result = discoverLocalWorkTexts(root.absolutePath)

        assertEquals("0", result.single()["fileSizeBytes"])
    }

    @Test
    fun `bounded document reader accepts files up to limit and rejects oversized files`() {
        val file = temporary.newFile("booklet.pdf")
        val payload = ByteArray(16) { it.toByte() }
        file.writeBytes(payload)

        assertArrayEquals(payload, readLocalDocumentBytes(file, maxBytes = 16L))
        assertNull(readLocalDocumentBytes(File(temporary.root, "missing.pdf"), maxBytes = 16L))

        val fileError = assertThrows(DocumentTooLargeException::class.java) {
            readLocalDocumentBytes(file, maxBytes = 15L)
        }
        assertEquals(15L, fileError.maxBytes)
        assertEquals(16L, fileError.actualBytes)

        assertArrayEquals(
            payload,
            readBoundedDocumentBytes(ByteArrayInputStream(payload), maxBytes = 16L)
        )
        val streamError = assertThrows(DocumentTooLargeException::class.java) {
            readBoundedDocumentBytes(ByteArrayInputStream(payload), maxBytes = 15L)
        }
        assertEquals(15L, streamError.maxBytes)
    }
}
