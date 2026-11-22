package com.doujin.audio

import com.doujin.audio.metadata.coverBridgeCacheKey
import com.doujin.audio.metadata.CoverArtworkOperations
import com.doujin.audio.metadata.MediaMetadataOperations
import com.doujin.audio.storage.DocumentStorageOperations
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class CoverArtworkSourceFingerprintTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun `local discovery and resolve return original paths without copying into cover cache`() {
        val folder = temporaryFolder.newFolder()
        val otherFile = File(folder, "a.jpg").apply { writeText("other") }
        val coverFile = File(folder, "cover.jpg").apply { writeText("preferred") }
        val folderFile = File(folder, "folder.jpg").apply { writeText("folder") }
        val context = RuntimeEnvironment.getApplication()
        val storage = DocumentStorageOperations(context)
        val artwork = CoverArtworkOperations(context, storage, MediaMetadataOperations(context, storage))
        val cache = File(context.cacheDir, "doujin_audio_covers")
        val before = cache.listFiles().orEmpty().map { it.name }.toSet()

        val resolved = artwork.resolve("track-1", null, folder.absolutePath)
        assertEquals(coverFile.absolutePath, resolved)

        val preferred = artwork.discover("first-only", null, folder.absolutePath,
            recursive = false, preferredOnly = true)

        assertEquals(1, preferred.size)
        assertEquals(coverFile.absolutePath, preferred.single().getValue("path"))
        assertEquals(coverFile.absolutePath, preferred.single().getValue("sourcePath"))
        assertEquals(coverFile.length().toString(), preferred.single().getValue("fileSizeBytes"))
        assertEquals(0, cache.listFiles().orEmpty().count { it.name !in before })

        val all = artwork.discover("first-only", null, folder.absolutePath, recursive = false)
        assertEquals(
            listOf(coverFile.absolutePath, folderFile.absolutePath, otherFile.absolutePath),
            all.map { it.getValue("path") }
        )
        assertEquals(
            listOf("preferred", "folder", "other"),
            all.map { File(it.getValue("path")).readText() }
        )
        assertEquals(0, cache.listFiles().orEmpty().count { it.name !in before })
    }

    @Test
    fun `local files retain distinct paths and reflect in-place updates directly`() {
        val folder = temporaryFolder.newFolder()
        val firstFile = File(folder, "Aa.jpg").apply { writeText("first"); setLastModified(100_000L) }
        val secondFile = File(folder, "BB.jpg").apply { writeText("other"); setLastModified(100_000L) }
        val context = RuntimeEnvironment.getApplication()
        val storage = DocumentStorageOperations(context)
        val artwork = CoverArtworkOperations(context, storage, MediaMetadataOperations(context, storage))
        val images = artwork.discover("collision", null, folder.absolutePath, recursive = false)

        assertEquals(2, images.size)
        assertEquals(firstFile.absolutePath, images[0]["path"])
        assertEquals(secondFile.absolutePath, images[1]["path"])
        assertNotEquals(images[0]["path"], images[1]["path"])
        assertEquals(listOf("first", "other"), images.map { File(it.getValue("path")).readText() })

        val changed = File(folder, "Aa.jpg").apply { writeText("third-updated"); setLastModified(101_000L) }
        val updated = artwork.discover("collision", null, folder.absolutePath, recursive = false)
        assertEquals(changed.absolutePath, updated[0]["path"])
        assertEquals(changed.length().toString(), updated[0]["fileSizeBytes"])
        assertEquals(changed.readText(), File(updated[0].getValue("path")).readText())
    }

    @Test
    fun `unchanged SAF source keeps the same bridge key`() {
        assertEquals(
            coverBridgeCacheKey("content://tree/cover.jpg", 100L, 200L),
            coverBridgeCacheKey("content://tree/cover.jpg", 100L, 200L)
        )
    }

    @Test
    fun `changed source metadata creates a new bridge key`() {
        val original = coverBridgeCacheKey("content://tree/cover.jpg", 100L, 200L)

        assertNotEquals(
            original,
            coverBridgeCacheKey("content://tree/cover.jpg", 101L, 200L)
        )
        assertNotEquals(
            original,
            coverBridgeCacheKey("content://tree/cover.jpg", 100L, 201L)
        )
    }
}
