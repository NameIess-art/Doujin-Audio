package com.doujin.audio

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.provider.DocumentsContract
import com.doujin.audio.storage.DocumentPathResolver
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class DocumentPathResolverTest {
    private val grant = DocumentsContract.buildTreeDocumentUri("test.documents", "authorized-root")
    private val selected = DocumentsContract.buildDocumentUriUsingTree(grant, "selected-child")
    private lateinit var paths: DocumentPathResolver
    private lateinit var provider: FolderProvider

    @Before
    fun setUp() {
        val context = RuntimeEnvironment.getApplication()
        paths = DocumentPathResolver(context)
        provider = FolderProvider()
        ShadowContentResolver.registerProviderInternal("test.documents", provider)
    }

    @Test
    fun `empty relative path retains selected document and tree grant`() {
        assertEquals(selected, paths.resolveRelativeDocumentUri(selected, ""))
        assertEquals(selected, paths.resolveDocumentUri("$selected::"))
    }

    @Test
    fun `pure tree URI resolves its root document`() {
        val root = DocumentsContract.buildDocumentUriUsingTree(grant, "authorized-root")

        assertEquals(root, paths.resolveDocumentUri(grant.toString()))
        assertEquals(root, paths.resolveRelativeDocumentUri(grant, ""))
    }

    @Test
    fun `relative subtitle and rename stay inside selected child instead of same named root folder`() {
        val subtitle = paths.resolveDocumentUri("$selected::CD1::track.srt")
        val renameTarget = paths.resolveDocumentRenameTarget("$selected::CD1")

        assertEquals(documentUri("child-subtitle"), subtitle)
        assertEquals(documentUri("child-cd"), renameTarget?.uri)
        assertEquals(selected, renameTarget?.rootUri)
        assertEquals(listOf("selected-child", "child-cd", "selected-child"), provider.queriedParents)
    }

    @Test
    fun `relative path from a pure tree still starts at grant root`() {
        assertEquals(documentUri("root-subtitle"), paths.resolveRelativeDocumentUri(grant, "CD1/track.srt"))
        assertEquals(listOf("authorized-root", "root-cd"), provider.queriedParents)
    }

    @Test
    fun `child folder enumeration stays inside selected directory`() {
        assertEquals(listOf(documentUri("child-cd").toString()), paths.listChildFoldersViaDocumentsContract(selected))
        assertEquals(listOf("selected-child"), provider.queriedParents)
    }

    private fun documentUri(id: String) = DocumentsContract.buildDocumentUriUsingTree(grant, id)

    private class FolderProvider : ContentProvider() {
        val queriedParents = mutableListOf<String>()
        private val folders = mapOf(
            "authorized-root" to listOf(listOf("root-cd", "CD1", DocumentsContract.Document.MIME_TYPE_DIR)),
            "selected-child" to listOf(listOf("child-cd", "CD1", DocumentsContract.Document.MIME_TYPE_DIR)),
            "root-cd" to listOf(listOf("root-subtitle", "track.srt", "application/x-subrip")),
            "child-cd" to listOf(listOf("child-subtitle", "track.srt", "application/x-subrip"))
        )

        override fun query(
            uri: Uri,
            projection: Array<out String>?,
            selection: String?,
            selectionArgs: Array<out String>?,
            sortOrder: String?
        ): Cursor {
            val parent = DocumentsContract.getDocumentId(uri)
            queriedParents.add(parent)
            val columns = projection ?: arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE
            )
            return MatrixCursor(columns).apply {
                for (row in folders[parent].orEmpty()) {
                    addRow(columns.map { column ->
                        when (column) {
                            DocumentsContract.Document.COLUMN_DOCUMENT_ID -> row[0]
                            DocumentsContract.Document.COLUMN_DISPLAY_NAME -> row[1]
                            DocumentsContract.Document.COLUMN_MIME_TYPE -> row[2]
                            else -> error("Unexpected document column: $column")
                        }
                    })
                }
            }
        }

        override fun onCreate() = true
        override fun getType(uri: Uri): String? = null
        override fun insert(uri: Uri, values: ContentValues?): Uri? = error("Unexpected insert")
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = error("Unexpected delete")
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = error("Unexpected update")
    }
}
