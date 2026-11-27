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
import com.doujin.audio.subtitle.SubtitleOperations
import com.doujin.audio.subtitle.SubtitleExistsException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
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

        val result = storage.writeFileBytesToDocumentFolder(selected, "Track.mp3", byteArrayOf(1))

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

    @Test
    fun `percent encoded subfolder resolves by raw segment and normalized fallback`() {
        assertEquals(documentUri("percent-dir"), paths.resolveDocumentUri("$selected::CD1::100%20Pure"))
        assertEquals(documentUri("percent-dir"), paths.resolveDocumentUri("$selected::CD1::100 Pure"))
    }

    @Test
    fun `SAF subtitle creation and staging temp files use octet stream mime type`() {
        val context = RuntimeEnvironment.getApplication()
        val storage = DocumentStorageOperations(context)
        val subtitles = SubtitleOperations(context, storage)

        val createdUri = subtitles.write(
            trackPath = documentUri("child-audio").toString(),
            groupKey = documentUri("child-cd").toString(),
            extension = ".srt",
            bytes = "1\n00:00:00,000 --> 00:00:01,000\nHi\n".toByteArray(),
            sourcePath = null,
            overwrite = false,
            createNew = true,
            fileNameSuffix = ".translated.zh-CN"
        )
        assertTrue(createdUri.startsWith("content://test.documents/"))
        assertEquals(listOf("application/octet-stream"), provider.createdMimeTypes)

        provider.createdMimeTypes.clear()
        val replacedUri = storage.writeFileBytesToDocumentFolder(
            documentUri("child-cd"),
            "voice.srt",
            "updated".toByteArray()
        )
        assertTrue(replacedUri != null)
        assertEquals(listOf("application/octet-stream"), provider.createdMimeTypes)
    }

    @Test
    fun `SAF transcription replaces only the confirmed primary and preserves occupied SRT`() {
        val context = RuntimeEnvironment.getApplication()
        val subtitles = SubtitleOperations(context, DocumentStorageOperations(context))
        val track = documentUri("child-audio").toString()
        val folder = documentUri("child-cd").toString()
        val primary = documentUri("primary").toString()
        val original = "original primary"
        val revision = java.security.MessageDigest.getInstance("SHA-256")
            .digest(original.toByteArray()).joinToString("") { "%02x".format(it) }
        provider.allowDelete = true
        provider.addSubtitle("primary", "voice.lrc", original)
        provider.addSubtitle("alternate", "voice.srt", "alternate subtitle")
        provider.addSubtitle("translation", "voice.mp3.translated.en.srt", "translation")

        provider.addSubtitle("primary", "voice.lrc", "changed primary")
        assertThrows(SubtitleExistsException::class.java) {
            subtitles.writeTranscription(track, folder, byteArrayOf(1), primary, revision)
        }
        assertTrue(provider.attemptedDeletes.isEmpty())

        provider.addSubtitle("primary", "voice.lrc", original)
        val saved = subtitles.writeTranscription(track, folder, byteArrayOf(1), primary, revision)
        val options = subtitles.list(track, folder).associate { it["name"] to it["sourcePath"] }
        assertEquals(saved, options["voice.asr.srt"])
        assertEquals(documentUri("alternate").toString(), options["voice.srt"])
        assertEquals(documentUri("translation").toString(), options["voice.mp3.translated.en.srt"])
        assertEquals(listOf(documentUri("primary")), provider.attemptedDeletes)
    }

    @Test
    fun `copyFileToUri opens destination with wt mode and falls back to w when wt is unsupported`() {
        val context = RuntimeEnvironment.getApplication()
        val storage = DocumentStorageOperations(context)
        val sourceFile = java.io.File(context.cacheDir, "export_source.txt").apply {
            writeText("short")
        }
        try {
            assertTrue(storage.copyFileToUri(sourceFile.absolutePath, documentUri("export-target").toString()))
            assertEquals(listOf("wt"), provider.openedModes)

            provider.openedModes.clear()
            provider.rejectWtMode = true
            assertTrue(storage.copyFileToUri(sourceFile.absolutePath, documentUri("export-target").toString()))
            assertEquals(listOf("wt", "w"), provider.openedModes)
        } finally {
            sourceFile.delete()
        }
    }

    private fun documentUri(id: String) = DocumentsContract.buildDocumentUriUsingTree(grant, id)

    private class FolderProvider : ContentProvider() {
        val queriedParents = mutableListOf<String>()
        val attemptedDeletes = mutableListOf<Uri?>()
        val createdMimeTypes = mutableListOf<String?>()
        val openedModes = mutableListOf<String>()
        var rejectWtMode = false
        var allowDelete = false
        private var nextCreatedId = 1
        private val documentFiles = mutableMapOf<String, java.io.File>()
        private val folders = linkedMapOf(
            "authorized-root" to mutableListOf(listOf("root-cd", "CD1", DocumentsContract.Document.MIME_TYPE_DIR)),
            "selected-child" to mutableListOf(
                listOf("child-file", "cd1", "audio/mpeg"),
                listOf("child-cd", "CD1", DocumentsContract.Document.MIME_TYPE_DIR),
                listOf("old-track", "TRACK.mp3", "audio/mpeg"),
                listOf("stale-backup", "Track.mp3.doujin.bak", "audio/mpeg"),
                listOf("stale-temp", "Track.mp3.doujin.part", "audio/mpeg")
            ),
            "root-cd" to mutableListOf(listOf("root-subtitle", "track.srt", "application/x-subrip")),
            "child-cd" to mutableListOf(
                listOf("child-disc", "Disc", DocumentsContract.Document.MIME_TYPE_DIR),
                listOf("percent-dir", "100%20Pure", DocumentsContract.Document.MIME_TYPE_DIR),
                listOf("child-audio", "voice.mp3", "audio/mpeg"),
                listOf("child-subtitle", "track.srt", "application/x-subrip")
            )
        )

        fun addSubtitle(id: String, name: String, content: String) {
            val rows = folders.getValue("child-cd")
            rows.removeAll { it[0] == id }
            rows.add(listOf(id, name, "application/octet-stream"))
            fileForDocument(id).writeText(content)
        }

        private fun fileForDocument(id: String) = documentFiles.getOrPut(id) {
            java.io.File.createTempFile("saf_test_", ".bin", context!!.cacheDir).apply { deleteOnExit() }
        }

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
            return when (method) {
                "android:deleteDocument" -> {
                    val uri = extras?.getParcelable("uri", Uri::class.java)
                    attemptedDeletes += uri
                    if (!allowDelete) throw IllegalStateException("Stale temporary document could not be deleted")
                    val id = DocumentsContract.getDocumentId(requireNotNull(uri))
                    folders.values.forEach { rows -> rows.removeAll { it[0] == id } }
                    documentFiles.remove(id)?.delete()
                    Bundle()
                }
                "android:createDocument" -> {
                    val parentUri = extras?.getParcelable("uri", Uri::class.java)!!
                    val parentId = DocumentsContract.getDocumentId(parentUri)
                    val mime = extras.getString(DocumentsContract.Document.COLUMN_MIME_TYPE)
                    val displayName = extras.getString(DocumentsContract.Document.COLUMN_DISPLAY_NAME)!!
                    createdMimeTypes += mime
                    val newId = "created-${nextCreatedId++}"
                    folders.getOrPut(parentId) { mutableListOf() }.add(
                        listOf(newId, displayName, mime ?: "application/octet-stream")
                    )
                    Bundle().apply {
                        putParcelable("uri", DocumentsContract.buildDocumentUriUsingTree(parentUri, newId))
                    }
                }
                "android:renameDocument" -> {
                    val targetUri = extras?.getParcelable("uri", Uri::class.java)!!
                    val targetId = DocumentsContract.getDocumentId(targetUri)
                    val newName = extras.getString(DocumentsContract.Document.COLUMN_DISPLAY_NAME)!!
                    folders.values.forEach { rows ->
                        val idx = rows.indexOfFirst { it[0] == targetId }
                        if (idx >= 0) {
                            rows[idx] = listOf(rows[idx][0], newName, rows[idx][2])
                        }
                    }
                    Bundle().apply {
                        putParcelable("uri", targetUri)
                    }
                }
                else -> error("Unexpected provider call: $method")
            }
        }

        override fun openFile(uri: Uri, mode: String): android.os.ParcelFileDescriptor {
            openedModes += mode
            if (rejectWtMode && mode == "wt") {
                throw IllegalArgumentException("wt unsupported")
            }
            val file = fileForDocument(DocumentsContract.getDocumentId(uri))
            val flags = if (mode == "r") android.os.ParcelFileDescriptor.MODE_READ_ONLY
                else android.os.ParcelFileDescriptor.MODE_READ_WRITE or android.os.ParcelFileDescriptor.MODE_TRUNCATE
            return android.os.ParcelFileDescriptor.open(
                file,
                flags
            )
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
