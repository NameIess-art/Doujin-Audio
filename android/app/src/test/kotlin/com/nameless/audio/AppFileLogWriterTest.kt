package com.nameless.audio

import com.nameless.audio.common.*

import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppFileLogWriterTest {
    @Test
    fun `writes complete utf8 lines in order and reopens for append`() {
        val directory = Files.createTempDirectory("nameless-log-test").toFile()
        val writer = AppFileLogWriter(directory)

        writer.append("first")
        writer.append("第二行")
        writer.close()
        AppFileLogWriter(directory).apply {
            append("third")
            close()
        }

        val logFile = File(directory, AppFileLogWriter.DEFAULT_FILE_NAME)
        assertEquals("first\n第二行\nthird\n", logFile.readText())
        assertEquals(
            "first\n第二行\nthird\n".toByteArray(StandardCharsets.UTF_8).size.toLong(),
            logFile.length()
        )
    }

    @Test
    fun `rotation keeps only the current file and one previous file`() {
        val directory = Files.createTempDirectory("nameless-log-rotation").toFile()
        val writer = AppFileLogWriter(directory, maxLogBytes = 12)

        writer.append("12345")
        writer.append("67890")
        writer.append("rotate")
        writer.append("again")
        writer.close()

        val current = File(directory, AppFileLogWriter.DEFAULT_FILE_NAME)
        val rotated = File(directory, "${AppFileLogWriter.DEFAULT_FILE_NAME}.1")
        assertTrue(current.exists())
        assertTrue(rotated.exists())
        assertEquals("again\n", current.readText())
        assertEquals("rotate\n", rotated.readText())
        assertFalse(File(directory, "${AppFileLogWriter.DEFAULT_FILE_NAME}.2").exists())
    }

    @Test
    fun `writer can recover after a filesystem failure`() {
        val parent = Files.createTempDirectory("nameless-log-recovery").toFile()
        val blockedDirectory = File(parent, "logs").apply { writeText("not a directory") }
        val writer = AppFileLogWriter(blockedDirectory)

        runCatching { writer.append("fails") }
        assertTrue(blockedDirectory.delete())
        assertTrue(blockedDirectory.mkdirs())
        writer.append("recovers")
        writer.close()

        assertEquals(
            "recovers\n",
            File(blockedDirectory, AppFileLogWriter.DEFAULT_FILE_NAME).readText()
        )
    }
}
