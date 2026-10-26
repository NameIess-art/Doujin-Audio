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
    fun `preferred discovery copies only the highest priority image and full discovery keeps all candidates`() {
        val folder = temporaryFolder.newFolder()
        File(folder, "a.jpg").writeText("other")
        File(folder, "cover.jpg").writeText("preferred")
        File(folder, "folder.jpg").writeText("folder")
        val context = RuntimeEnvironment.getApplication()
        val storage = DocumentStorageOperations(context)
        val artwork = CoverArtworkOperations(context, storage, MediaMetadataOperations(context, storage))
        val cache = File(context.cacheDir, "doujin_audio_covers")
        val before = cache.listFiles().orEmpty().map { it.name }.toSet()

        val preferred = artwork.discover("first-only", null, folder.absolutePath,
            recursive = false, preferredOnly = true)

        assertEquals(1, preferred.size)
        assertEquals("preferred", File(preferred.single().getValue("path")).readText())
        assertEquals(1, cache.listFiles().orEmpty().count { it.name !in before })
        val all = artwork.discover("first-only", null, folder.absolutePath, recursive = false)
        assertEquals(listOf("preferred", "folder", "other"), all.map { File(it.getValue("path")).readText() })
    }

    @Test
    fun `colliding Java path hashes retain distinct image files and contents`() {
        val folder = temporaryFolder.newFolder()
        File(folder, "Aa.jpg").apply { writeText("first"); setLastModified(100_000L) }
        File(folder, "BB.jpg").apply { writeText("other"); setLastModified(100_000L) }
        val context = RuntimeEnvironment.getApplication()
        val storage = DocumentStorageOperations(context)
        val artwork = CoverArtworkOperations(context, storage, MediaMetadataOperations(context, storage))
        val images = artwork.discover("collision", null, folder.absolutePath, recursive = false)

        assertEquals(2, images.size)
        assertNotEquals(images[0]["path"], images[1]["path"])
        assertEquals(listOf("first", "other"), images.map { File(it.getValue("path")).readText() })
        val changed = File(folder, "Aa.jpg").apply { writeText("third"); setLastModified(101_000L) }
        val updated = artwork.discover("collision", null, folder.absolutePath, recursive = false)
        assertNotEquals(images[0]["path"], updated[0]["path"])
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
