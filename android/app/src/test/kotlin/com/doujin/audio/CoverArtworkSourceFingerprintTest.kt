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
