package com.doujin.audio

import com.doujin.audio.storage.copyImportedDocumentToFile
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ImportedDocumentFileTest {
    @get:Rule
    val directory = TemporaryFolder()

    @Test
    fun `opening input failure removes precreated import`() {
        val output = directory.newFile("unopened.mp3")
        val failure = IOException("provider unavailable")
        try {
            copyImportedDocumentToFile(output) { throw failure }
            error("Import should fail")
        } catch (error: IOException) {
            assertSame(failure, error)
        }
        assertFalse(output.exists())
    }

    @Test
    fun `partial read failure removes import and preserves original error`() {
        val output = directory.newFile("failed.mp3")
        val failure = IOException("provider disconnected")
        var closed = false
        val stream = object : InputStream() {
            private var emitted = false
            override fun read(): Int = error("Bulk read expected")
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                if (emitted) throw failure
                emitted = true
                bytes[offset] = 7
                return 1
            }
            override fun close() { closed = true }
        }
        try {
            copyImportedDocumentToFile(output) { stream }
            error("Import should fail")
        } catch (error: IOException) {
            assertSame(failure, error)
        }
        assertFalse(output.exists())
        assertTrue(closed)
    }

    @Test
    fun `input close failure removes a fully written import`() {
        val output = directory.newFile("failed-close.mp3")
        try {
            copyImportedDocumentToFile(output) {
                object : ByteArrayInputStream(byteArrayOf(1, 2)) {
                    override fun close() { throw IOException("close failed") }
                }
            }
            error("Import should fail")
        } catch (_: IOException) { }
        assertFalse(output.exists())
    }

    @Test
    fun `successful import retains the complete bytes`() {
        val output = directory.newFile("complete.mp3")
        val bytes = byteArrayOf(1, 2, 3)
        copyImportedDocumentToFile(output) { ByteArrayInputStream(bytes) }
        assertArrayEquals(bytes, output.readBytes())
    }
}
