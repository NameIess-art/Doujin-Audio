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
            { _, _, _, _, _, _, _, _ -> error("Unexpected track write") })
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
            { track, group, extension, content, source, overwrite, createNew, suffix ->
                assertEquals("content://audio", track); assertEquals("content://tree", group)
                assertEquals(".srt", extension); assertArrayEquals(bytes, content)
                assertEquals("content://source", source); assertTrue(overwrite)
                assertFalse(createNew); assertNull(suffix)
                "content://saved"
            })
        assertEquals("content://saved", action())
    }

    @Test
    fun `track mode defaults overwrite to false`() {
        val action = trackSubtitleWriteAction(arguments(mapOf(
            "trackPath" to "audio", "extension" to ".lrc", "bytes" to byteArrayOf())),
            { _, _ -> error("Unexpected write") },
            { _, group, _, _, source, overwrite, createNew, suffix ->
                assertNull(group); assertNull(source); assertFalse(overwrite); assertFalse(createNew); assertNull(suffix); "saved" })
        assertEquals("saved", action())
    }

    @Test
    fun `translation mode forwards independent creation and validates its arguments`() {
        val base = mapOf("trackPath" to "audio", "extension" to ".srt", "bytes" to byteArrayOf(1), "createNew" to true)
        val action = trackSubtitleWriteAction(arguments(base + ("fileNameSuffix" to ".translated.zh-CN")),
            { _, _ -> error("Unexpected path write") },
            { _, _, _, _, source, overwrite, createNew, suffix ->
                assertNull(source); assertFalse(overwrite); assertTrue(createNew)
                assertEquals(".translated.zh-CN", suffix); "saved"
            })
        assertEquals("saved", action())
        listOf(base, base + ("fileNameSuffix" to "../unsafe"),
            base + mapOf("fileNameSuffix" to ".translated.en", "sourcePath" to "source"),
            base + mapOf("fileNameSuffix" to ".translated.en", "overwrite" to true)
        ).forEach { input ->
            assertThrows(IllegalArgumentException::class.java) {
                trackSubtitleWriteAction(arguments(input), { _, _ -> true }, { _, _, _, _, _, _, _, _ -> "saved" })
            }
        }
    }

    @Test
    fun `independent translations retain originals and use full audio names and increasing versions`() {
        val track = temporary.newFile("中文 voice.mp3")
        val wav = temporary.newFile("中文 voice.wav")
        val original = temporary.newFile("中文 voice.srt").apply { writeText("original") }
        val other = temporary.newFile("中文 voice.ja.ass").apply { writeText("other") }
        val first = saveNewLocalTrackSubtitle(track.path, ".srt", "first".toByteArray(), ".translated.zh-CN")
        val second = saveNewLocalTrackSubtitle(track.path, ".srt", "second".toByteArray(), ".translated.zh-CN")
        val english = saveNewLocalTrackSubtitle(track.path, ".srt", "english".toByteArray(), ".translated.en")
        val wavResult = saveNewLocalTrackSubtitle(wav.path, ".srt", "wav".toByteArray(), ".translated.zh-CN")
        assertEquals("中文 voice.mp3.translated.zh-CN.srt", File(first).name)
        assertEquals("中文 voice.mp3.translated.zh-CN.2.srt", File(second).name)
        assertEquals("original", original.readText()); assertEquals("other", other.readText())
        assertEquals("first", File(first).readText()); assertEquals("second", File(second).readText())
        val options = listLocalTrackSubtitles(track.path).map { it["sourcePath"] }
        assertTrue(options.containsAll(listOf(original.path, other.path, first, second, english)))
        assertFalse(options.contains(wavResult))
        assertEquals(10, subtitleMatchRank(track.name, File(first).name))
        assertEquals(10, subtitleMatchRank(track.name, File(wavResult).name))
    }

    @Test
    fun `independent translations avoid case insensitive existing names and directory collisions`() {
        val track = temporary.newFile("voice.mp3")
        val previous = temporary.newFile("VOICE.MP3.TRANSLATED.EN.SRT").apply { writeText("keep") }
        temporary.newFolder("voice.mp3.translated.en.2.srt")
        val saved = saveNewLocalTrackSubtitle(track.path, ".srt", "new".toByteArray(), ".translated.en")
        assertEquals("voice.mp3.translated.en.3.srt", File(saved).name)
        assertEquals("keep", previous.readText())
    }

    @Test
    fun `concurrent independent saves never share a destination`() {
        val track = temporary.newFile("voice.mp3")
        val pool = java.util.concurrent.Executors.newFixedThreadPool(2)
        try {
            val tasks = (1..4).map { index -> pool.submit<String> {
                saveNewLocalTrackSubtitle(track.path, ".srt", "version $index".toByteArray(), ".translated.en")
            } }
            val paths = tasks.map { it.get() }
            assertEquals(4, paths.toSet().size)
            assertEquals((1..4).map { "version $it" }.toSet(), paths.map { File(it).readText() }.toSet())
        } finally { pool.shutdownNow() }
    }

    @Test
    fun `SAF independent creation never writes or deletes a provider returned existing URI`() {
        data class Document(val id: Int, val name: String)
        val original = Document(1, "voice.srt")
        assertThrows(IOException::class.java) {
            createNewSubtitleDocument("voice.mp3.translated.en.srt", { listOf(original) }, { it.name },
                { first, second -> first.id == second.id }, { original },
                { error("Must not overwrite original") }, { error("Must not delete original") })
        }
    }

    @Test
    fun `SAF independent creation skips occupied names and saves a verified new document`() {
        data class Document(val id: Int, val name: String)
        val name = "voice.mp3.translated.en.srt"
        val original = Document(1, name)
        assertNull(createNewSubtitleDocument(name, { listOf(original) }, { it.name },
            { first, second -> first.id == second.id }, { error("Occupied name must not be created") },
            { error("Must not write existing document") }, { error("Must not delete existing document") }))
        val created = Document(2, "voice.mp3.translated.en.2.srt")
        var written: Document? = null
        val result = createNewSubtitleDocument(created.name, { listOf(original) }, { it.name },
            { first, second -> first.id == second.id }, { created },
            { written = it; true }, { error("Successful save must not delete anything") })
        assertEquals(created, result); assertEquals(created, written)
    }

    @Test
    fun `SAF independent creation rejects provider renamed documents and cleans only created file`() {
        data class Document(val id: Int, val name: String)
        val original = Document(1, "voice.srt")
        val created = Document(2, "voice.mp3.translated.en (1).srt")
        var deleted: Document? = null
        assertThrows(IOException::class.java) {
            createNewSubtitleDocument("voice.mp3.translated.en.srt", { listOf(original) }, { it.name },
                { first, second -> first.id == second.id }, { created },
                { error("Must verify display name before writing") }, { deleted = it; true })
        }
        assertEquals(created, deleted)
    }

    @Test
    fun `SAF independent creation guards concurrent duplicates and handles failed writes`() {
        data class Document(val id: Int, val name: String)
        val targetName = "voice.mp3.translated.en.srt"
        val created = Document(2, targetName)
        val competing = Document(3, targetName)
        var calls = 0
        var deleted: Document? = null
        assertThrows(IOException::class.java) {
            createNewSubtitleDocument(targetName, { if (calls++ == 0) emptyList() else listOf(created, competing) }, { it.name },
                { first, second -> first.id == second.id }, { created },
                { error("Must not write duplicated document") }, { deleted = it; true })
        }
        assertEquals(created, deleted)
        deleted = null
        assertThrows(IOException::class.java) {
            createNewSubtitleDocument(targetName, { emptyList() }, { it.name },
                { first, second -> first.id == second.id }, { created }, { false }, { deleted = it; true })
        }
        assertEquals(created, deleted)
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
                trackSubtitleWriteAction(arguments(input), { _, _ -> true }, { _, _, _, _, _, _, _, _ -> "saved" })
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
    fun `only generated SRT markers are excluded from automatic subtitle matching`() {
        assertTrue(isTranslatedSubtitle("voice.mp3.translated.zh-CN.srt"))
        assertTrue(isTranslatedSubtitle("VOICE.MP3.TRANSLATED.EN.12.SRT"))
        listOf("voice.translated.en.lrc", "voice.translated.en.ass", "voice.translated.en.srt.backup",
            "voice.translated.en2.srt", "voice.translated.en.notes.srt").forEach { name ->
            assertFalse(isTranslatedSubtitle(name))
        }
        assertEquals(1, subtitleMatchRank("voice.mp3", "voice.translated.en.lrc"))
        assertEquals(1, subtitleMatchRank("voice.mp3", "voice.translated.en.ass"))
        assertThrows(IllegalArgumentException::class.java) {
            translatedSubtitleName("voice.mp3", ".translated.en2", ".srt")
        }
    }

    @Test
    fun `subtitle enumeration requires an existing audio file`() {
        temporary.newFile("missing.srt")
        assertThrows(IOException::class.java) {
            listLocalTrackSubtitles(File(temporary.root, "missing.mp3").path)
        }
        val folder = temporary.newFolder("folder.mp3")
        assertThrows(IOException::class.java) { listLocalTrackSubtitles(folder.path) }
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
        val translation = temporary.newFile("voice.mp3.translated.en.srt").apply { writeText("translation") }
        val saved = saveLocalTrackSubtitle(track.path, ".lrc", "new".toByteArray(), null, false)
        assertEquals("new", File(saved).readText())
        assertFalse(old.exists()); assertTrue(language.exists())
        assertEquals("translation", translation.readText())
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
