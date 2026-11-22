package com.doujin.audio

import android.content.ComponentName
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.IntentFilter
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import com.doujin.audio.storage.DocumentPathResolver
import com.doujin.audio.storage.DocumentStorageOperations
import com.doujin.audio.storage.resolveContainedFilePath
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
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
        registerTestDocumentProvider(context, "test.documents", provider)
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

    @Test
    fun `relative folder lookup uses one projection per segment and ignores file matches`() {
        assertEquals(documentUri("child-disc"), paths.resolveDocumentFileForFolderPath("$selected::cd1/disc")?.uri)
        assertEquals(listOf("selected-child", "child-cd"), provider.queriedParents)
    }

    @Test
    fun `replacement matches stale files from one directory projection`() {
        val storage = DocumentStorageOperations(RuntimeEnvironment.getApplication())

        val result = storage.writeFileBytesToDocumentFolder(selected, "Track.mp3", byteArrayOf(1), "audio/mpeg")

        assertNull(result)
        assertEquals(listOf(documentUri("stale-temp")), provider.attemptedDeletes)
        assertEquals(listOf("selected-child"), provider.queriedParents)
    }

    @Test
    fun `contained file path resolution rejects traversal outside volume root`() {
        val root = java.io.File(RuntimeEnvironment.getApplication().cacheDir, "root_volume")
        val inside = resolveContainedFilePath(root.absolutePath, "Music/Track.mp3")
        assertEquals(java.io.File(root, "Music/Track.mp3").canonicalPath, inside)
        assertEquals(root.canonicalPath, resolveContainedFilePath(root.absolutePath, ""))
        assertNull(resolveContainedFilePath(root.absolutePath, "../root_volume_sibling/Track.mp3"))
        assertNull(resolveContainedFilePath(root.absolutePath, "../../etc/passwd"))
    }

    private fun documentUri(id: String) = DocumentsContract.buildDocumentUriUsingTree(grant, id)

    private class FolderProvider : ContentProvider() {
        val queriedParents = mutableListOf<String>()
        val attemptedDeletes = mutableListOf<Uri?>()
        private val folders = mapOf(
            "authorized-root" to listOf(listOf("root-cd", "CD1", DocumentsContract.Document.MIME_TYPE_DIR)),
            "selected-child" to listOf(
                listOf("child-file", "cd1", "audio/mpeg"),
                listOf("child-cd", "CD1", DocumentsContract.Document.MIME_TYPE_DIR),
                listOf("old-track", "TRACK.mp3", "audio/mpeg"),
                listOf("stale-backup", "Track.mp3.doujin.bak", "audio/mpeg"),
                listOf("stale-temp", "Track.mp3.doujin.part", "audio/mpeg")
            ),
            "root-cd" to listOf(listOf("root-subtitle", "track.srt", "application/x-subrip")),
            "child-cd" to listOf(
                listOf("child-disc", "Disc", DocumentsContract.Document.MIME_TYPE_DIR),
                listOf("child-subtitle", "track.srt", "application/x-subrip")
            )
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
                val rows = if (uri.lastPathSegment == "children") folders[parent].orEmpty()
                    else folders.values.flatten().filter { it[0] == parent }
                for (row in rows) {
                    addRow(columns.map { column ->
                        when (column) {
                            DocumentsContract.Document.COLUMN_DOCUMENT_ID -> row[0]
                            DocumentsContract.Document.COLUMN_DISPLAY_NAME -> row[1]
                            DocumentsContract.Document.COLUMN_MIME_TYPE -> row[2]
                            else -> null
                        }
                    })
                }
            }
        }

        override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
            check(method == "android:deleteDocument") { "Unexpected provider call: $method" }
            attemptedDeletes += extras?.getParcelable("uri", Uri::class.java)
            throw IllegalStateException("Stale temporary document could not be deleted")
        }

        override fun onCreate() = true
        override fun getType(uri: Uri): String? = null
        override fun insert(uri: Uri, values: ContentValues?): Uri? = error("Unexpected insert")
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = error("Unexpected delete")
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = error("Unexpected update")
    }
}

// DocumentFile.fromTreeUri checks PackageManager as well as ContentResolver.
internal fun registerTestDocumentProvider(context: Context, authority: String, provider: ContentProvider) {
    val providerInfo = ProviderInfo().apply {
        this.authority = authority
        name = provider.javaClass.name
        packageName = context.packageName
        applicationInfo = context.applicationInfo
        exported = true
    }
    provider.attachInfo(context, providerInfo)
    shadowOf(context.packageManager).apply {
        addOrUpdateProvider(providerInfo)
        addIntentFilterForProvider(
            ComponentName(providerInfo.packageName, providerInfo.name),
            IntentFilter(DocumentsContract.PROVIDER_INTERFACE)
        )
    }
    ShadowContentResolver.registerProviderInternal(authority, provider)
}
