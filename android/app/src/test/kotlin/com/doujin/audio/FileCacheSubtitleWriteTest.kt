package com.doujin.audio

import com.doujin.audio.channel.*
import com.doujin.audio.subtitle.*
import io.flutter.plugin.common.MethodCall
import org.junit.Assert.*
import org.junit.Test
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException

class FileCacheSubtitleWriteTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test
    fun `path mode writes exact original URI and bytes without requiring track`() {
        val path = "content://documents/tree/root/document/root%2Ftrack.en.srt"
        val bytes = "edited".toByteArray()
        var writtenPath: String? = null
        val action = trackSubtitleWriteAction(arguments(mapOf("path" to path, "bytes" to bytes)),
            { destination, content -> writtenPath = destination; assertArrayEquals(bytes, content); true },
            { _, _, _, _, _, _ -> error("Unexpected track write") })
        assertNull(writtenPath)
        assertEquals(true, action())
        assertEquals(path, writtenPath)
    }

    @Test
    fun `track mode forwards import target and overwrite intent and returns saved URI`() {
        val bytes = byteArrayOf(1)
        val action = trackSubtitleWriteAction(arguments(mapOf(
            "trackPath" to "content://audio", "groupKey" to "content://tree", "extension" to ".srt",
            "bytes" to bytes, "sourcePath" to "content://source", "overwrite" to true)),
            { _, _ -> error("Unexpected path write") },
            { track, group, extension, content, source, overwrite ->
                assertEquals("content://audio", track); assertEquals("content://tree", group)
                assertEquals(".srt", extension); assertArrayEquals(bytes, content)
                assertEquals("content://source", source); assertTrue(overwrite)
                "content://saved"
            })
        assertEquals("content://saved", action())
    }

    @Test
    fun `track mode defaults overwrite to false`() {
        val action = trackSubtitleWriteAction(arguments(mapOf(
            "trackPath" to "audio", "extension" to ".lrc", "bytes" to byteArrayOf())),
            { _, _ -> error("Unexpected write") },
            { _, group, _, _, source, overwrite -> assertNull(group); assertNull(source); assertFalse(overwrite); "saved" })
        assertEquals("saved", action())
    }

    @Test
    fun `invalid mode arguments fail synchronously`() {
        val bytes = byteArrayOf(1)
        listOf(emptyMap(), mapOf("path" to "content://subtitle"), mapOf("path" to "", "bytes" to bytes),
            mapOf("trackPath" to "audio", "bytes" to bytes),
            mapOf("trackPath" to "audio", "extension" to ".bad", "bytes" to bytes),
            mapOf("trackPath" to "audio", "extension" to ".lrc", "bytes" to bytes, "overwrite" to "yes"),
            mapOf("trackPath" to "audio", "extension" to ".lrc", "bytes" to bytes, "sourcePath" to ""),
            mapOf("folder" to "content://folder", "name" to "track.lrc", "bytes" to bytes)
        ).forEach { input ->
            assertThrows(IllegalArgumentException::class.java) {
                trackSubtitleWriteAction(arguments(input), { _, _ -> true }, { _, _, _, _, _, _ -> "saved" })
            }
        }
    }

    @Test
    fun `loose subtitle matching retains double extension and language suffix ranks`() {
        assertEquals(0, subtitleMatchRank("voice.mp3", "VOICE.srt"))
        assertEquals(0, subtitleMatchRank("voice.mp3", "voice.mp3.srt"))
        assertEquals(1, subtitleMatchRank("voice.mp3", "voice.zh.srt"))
        assertEquals(2, subtitleMatchRank("voice.mp3", "voice_zh.srt"))
        assertEquals(0, subtitleMatchRank("voice.mp3", "voice.txt"))
        assertEquals("voice.txt", subtitleDestinationName("voice.mp3", ".TXT"))
        assertEquals(10, subtitleMatchRank("voice.mp3", "other.srt"))
        assertEquals("voice.mp3.srt", subtitleDestinationName("voice.mp3.mp3", ".SRT"))
    }

    @Test
    fun `local import writes actual nested directory then removes source and current subtitle`() {
        val album = temporary.newFolder("album")
        val nested = File(album, "nested").apply { mkdir() }
        val track = File(nested, "voice.mp3").apply { writeText("audio") }
        val current = File(nested, "voice.zh.srt").apply { writeText("old") }
        val otherLanguage = File(nested, "voice_ja.srt").apply { writeText("keep") }
        val source = temporary.newFile("selected.ass").apply { writeText("new") }
        val saved = saveLocalTrackSubtitle(track.path, ".ass", source.readBytes(), source.path, true)
        assertEquals(File(nested, "voice.ass").path, saved)
        assertEquals("new", File(saved).readText())
        assertFalse(source.exists()); assertFalse(current.exists()); assertTrue(otherLanguage.exists())
        assertFalse(File(album, "voice.ass").exists())
    }

    @Test
    fun `unconfirmed overwrite preserves destination and source`() {
        val track = temporary.newFile("voice.mp3")
        val current = temporary.newFile("voice.lrc").apply { writeText("old") }
        val source = temporary.newFile("selected.srt").apply { writeText("new") }
        assertThrows(SubtitleExistsException::class.java) {
            saveLocalTrackSubtitle(track.path, ".srt", source.readBytes(), source.path, false)
        }
        assertEquals("old", current.readText()); assertTrue(source.exists())
        assertFalse(File(track.parentFile, "voice.srt").exists())
    }

    @Test
    fun `same source and destination import keeps original file without rewriting`() {
        val track = temporary.newFile("voice.mp3")
        val source = temporary.newFile("voice.srt").apply { writeText("original") }
        val saved = saveLocalTrackSubtitle(track.path, ".srt", "unused".toByteArray(), source.path, false,
            { error("Must not delete same source") })
        assertEquals(source.path, saved); assertEquals("original", source.readText())
    }

    @Test
    fun `failed source removal restores previous destination and preserves source`() {
        val track = temporary.newFile("voice.mp3")
        val previous = temporary.newFile("voice.srt").apply { writeText("old") }
        val source = temporary.newFile("selected.srt").apply { writeText("new") }
        assertThrows(IOException::class.java) {
            saveLocalTrackSubtitle(track.path, ".srt", source.readBytes(), source.path, true, { false })
        }
        assertTrue(source.exists()); assertEquals("old", previous.readText())
    }

    @Test
    fun `failed source removal cleans new target and retains different format subtitle`() {
        val track = temporary.newFile("voice.mp3")
        val previous = temporary.newFile("voice.lrc").apply { writeText("old") }
        val source = temporary.newFile("selected.srt").apply { writeText("new") }
        assertThrows(IOException::class.java) {
            saveLocalTrackSubtitle(track.path, ".srt", source.readBytes(), source.path, true, { false })
        }
        assertTrue(source.exists()); assertEquals("old", previous.readText())
        assertFalse(File(track.parentFile, "voice.srt").exists())
    }

    @Test
    fun `content source import to local audio removes URI only after saving`() {
        val track = temporary.newFile("voice.mp3")
        val source = "content://documents/document/selected"
        val saved = saveLocalTrackSubtitle(track.path, ".srt", "new".toByteArray(), source, false,
            { path ->
                assertEquals(source, path)
                assertEquals("new", File(track.parentFile, "voice.srt").readText())
                true
            })
        assertEquals(File(track.parentFile, "voice.srt").path, saved)
    }

    @Test
    fun `generation replaces exact names of different format and preserves unrelated language`() {
        val track = temporary.newFile("voice.mp3")
        val old = temporary.newFile("voice.srt").apply { writeText("old") }
        val language = temporary.newFile("voice.zh.srt").apply { writeText("keep") }
        val saved = saveLocalTrackSubtitle(track.path, ".lrc", "new".toByteArray(), null, false)
        assertEquals("new", File(saved).readText())
        assertFalse(old.exists()); assertTrue(language.exists())
    }

    @Test
    fun `failed target save keeps imported source`() {
        val source = temporary.newFile("selected.srt")
        assertThrows(IOException::class.java) {
            saveLocalTrackSubtitle(File(temporary.root, "missing.mp3").path, ".srt", byteArrayOf(), source.path, false,
                { error("Must not delete source before saving") })
        }
        assertTrue(source.exists())
    }

    private fun arguments(input: Map<String, Any>) = MethodCall(FileCacheMethods.WRITE_TRACK_SUBTITLE, input).argumentReader()
}
