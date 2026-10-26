package com.doujin.audio

import android.content.ContentProvider
import android.content.ContentValues
import android.content.pm.ProviderInfo
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import com.doujin.audio.metadata.CoverArtworkOperations
import com.doujin.audio.metadata.MediaMetadataOperations
import com.doujin.audio.storage.DocumentStorageOperations
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class CoverArtworkSafDiscoveryTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test
    fun `given sibling works when resolving a track cover then only its subtree is scanned`() {
        val (artwork, provider) = setup()
        val result = artwork.resolve("content://covers.test/document/voice", "$root::work", null)

        assertEquals("cover bytes", File(requireNotNull(result)).readText())
        assertEquals(listOf("root", "work"), provider.directories)
        assertEquals(listOf("work/cover.jpg"), provider.opened)
        assertFalse(provider.directories.contains("other"))
    }

    @Test
    fun `given many SAF candidates when requesting preferred then only one content stream opens`() {
        val (artwork, provider) = setup()
        val images = artwork.discover(root, null, "$root::work", false, preferredOnly = true)

        assertEquals(1, images.size)
        assertEquals(listOf("work/cover.jpg"), provider.opened)
        // The single-image path uses the directory projection for every other candidate.
        assertFalse(provider.documents.any { it.startsWith("work/image") })
        provider.opened.clear()
        val all = artwork.discover(root, null, "$root::work", false)
        assertEquals(41, all.size)
        assertEquals(40, provider.opened.size)
        assertEquals(images.first(), all.first())
    }

    private fun setup(): Pair<CoverArtworkOperations, ImagesProvider> {
        val context = RuntimeEnvironment.getApplication()
        val provider = ImagesProvider(temporary.newFolder())
        provider.attachInfo(context, ProviderInfo().apply { authority = "covers.test" })
        ShadowContentResolver.registerProviderInternal("covers.test", provider)
        val storage = DocumentStorageOperations(context)
        return CoverArtworkOperations(context, storage, MediaMetadataOperations(context, storage)) to provider
    }

    private companion object { const val root = "content://covers.test/tree/root" }

    private class ImagesProvider(folder: File) : ContentProvider() {
        val directories = mutableListOf<String>()
        val documents = mutableListOf<String>()
        val opened = mutableListOf<String>()
        private val files = (listOf("work/cover.jpg", "other/cover.jpg") +
            (0 until 40).map { "work/image$it.jpg" }).associateWith { id ->
            File(folder, id.replace('/', '_')).apply { writeText(if (id == "work/cover.jpg") "cover bytes" else id) }
        }

        override fun onCreate() = true
        override fun getType(uri: Uri) = "image/jpeg"
        override fun insert(uri: Uri, values: ContentValues?): Uri? = null
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
            val id = DocumentsContract.getDocumentId(uri)
            opened += id
            return ParcelFileDescriptor.open(files.getValue(id), ParcelFileDescriptor.MODE_READ_ONLY)
        }

        override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
            selectionArgs: Array<out String>?, sortOrder: String?): MatrixCursor {
            val id = DocumentsContract.getDocumentId(uri)
            val children = uri.lastPathSegment == "children"
            if (children) directories += id else documents += id
            val ids = if (!children) listOf(id) else if (id == "root") listOf("work", "other")
                else files.keys.filter { it.substringBeforeLast('/') == id }
            val columns = projection ?: arrayOf("document_id", "_display_name", "mime_type", "_size", "last_modified", "flags")
            return MatrixCursor(columns).apply {
                for (entry in ids) addRow(columns.map { column ->
                    when (column) {
                        "document_id" -> entry
                        "_display_name" -> entry.substringAfterLast('/')
                        "mime_type" -> if (entry in files) "image/jpeg" else DocumentsContract.Document.MIME_TYPE_DIR
                        "_size" -> files[entry]?.length() ?: 0L
                        "last_modified" -> 1000L
                        "flags" -> 0
                        else -> null
                    }
                })
            }
        }
    }
}
