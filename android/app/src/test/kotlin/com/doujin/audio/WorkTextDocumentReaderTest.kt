package com.doujin.audio

import com.doujin.audio.storage.discoverLocalWorkTexts
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
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
}
