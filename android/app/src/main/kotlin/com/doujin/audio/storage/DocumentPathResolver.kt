package com.doujin.audio.storage

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import java.util.Locale
import java.io.IOException

internal data class DirectoryDocument(
    val uri: Uri,
    val name: String,
    val mime: String,
    val sizeBytes: Long? = null
)

internal fun listReadableDirectoryDocuments(context: Context, folder: Uri): List<DirectoryDocument> {
    val children = DocumentsContract.buildChildDocumentsUriUsingTree(
        folder, DocumentsContract.getDocumentId(folder)
    )
    // DocumentFile.listFiles catches provider failures and reports an empty directory.
    // Discoveries persisted by Dart must distinguish those failures from success.
    val cursor = context.contentResolver.query(children, arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_SIZE
    ), null, null, null) ?: throw IOException("Document provider query failed: $children")
    return cursor.use {
        val idColumn = it.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
        val nameColumn = it.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        val mimeColumn = it.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
        val sizeColumn = it.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
        buildList {
            while (it.moveToNext()) {
                val id = it.getString(idColumn) ?: throw IOException("Document ID is missing: $children")
                val name = it.getString(nameColumn) ?: throw IOException("Document name is missing: $children")
                val mime = it.getString(mimeColumn) ?: throw IOException("Document type is missing: $children")
                val sizeBytes = if (sizeColumn >= 0 && !it.isNull(sizeColumn)) it.getLong(sizeColumn) else null
                add(DirectoryDocument(DocumentsContract.buildDocumentUriUsingTree(folder, id), name, mime, sizeBytes))
            }
        }
    }
}

internal data class DocumentRenameTarget(
    val uri: Uri,
    val rootUri: Uri?,
    val syntheticBase: String?,
    val syntheticParentRelative: String?,
    val treeRoot: Boolean
    )


internal class DocumentPathResolver(private val context: Context) {
    private val contentResolver get() = context.contentResolver
    internal fun resolveContentUri(rawFolder: String): Uri? {
        if (rawFolder.startsWith("content://")) {
            return Uri.parse(rawFolder)
        }
        if (rawFolder.startsWith("/tree/")) {
            return Uri.parse("content://com.android.externalstorage.documents$rawFolder")
        }
        if (!rawFolder.contains("/") && rawFolder.contains(":")) {
            return DocumentsContract.buildTreeDocumentUri(
                "com.android.externalstorage.documents",
                rawFolder
            )
        }
        return null
    }

    internal fun resolveVolumeRoot(volumeName: String): String? {
        if (volumeName.equals("primary", ignoreCase = true)) {
            return Environment.getExternalStorageDirectory().absolutePath
        }
        // For secondary volumes, try to find the mount point via StorageManager.
        return try {
            val storageManager = context.getSystemService(Context.STORAGE_SERVICE)
                as? android.os.storage.StorageManager ?: return null
            val volumes: List<android.os.storage.StorageVolume> =
                storageManager.storageVolumes
            val volume = volumes.firstOrNull { v ->
                v.uuid?.equals(volumeName, ignoreCase = true) == true
            } ?: return null
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                volume.directory?.absolutePath
            } else {
                @Suppress("DiscouragedPrivateApi")
                val method = volume.javaClass.getDeclaredMethod("getPath")
                method.isAccessible = true
                method.invoke(volume) as? String
            }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Converts a content URI (tree or document) to an actual file-system path
     * by parsing the document ID (e.g. "primary:Music/MyFolder").
     * Returns null if the URI cannot be resolved to a file path.
     */
    internal fun contentUriToFilePath(contentUri: String): String? {
        val trimmed = contentUri.trim()
        if (!trimmed.startsWith("content://")) return null

        val syntheticIndex = trimmed.indexOf("::")
        if (syntheticIndex >= 0) {
            val base = trimmed.substring(0, syntheticIndex)
            val relative = trimmed.substring(syntheticIndex + 2).trim('/')
            val basePath = contentUriToFilePath(base) ?: return null
            return if (relative.isEmpty()) basePath else java.io.File(basePath, relative).absolutePath
        }

        val uri = Uri.parse(trimmed)
        val documentId = try {
            if (DocumentsContract.isDocumentUri(context, uri)) {
                DocumentsContract.getDocumentId(uri)
            } else {
                DocumentsContract.getTreeDocumentId(uri)
            }
        } catch (_: Exception) {
            return null
        } ?: return null
        val colonIndex = documentId.indexOf(':')
        if (colonIndex < 0) return null
        val volumeName = documentId.substring(0, colonIndex)
        val relativePath = documentId.substring(colonIndex + 1)
        val volumeRoot = resolveVolumeRoot(volumeName) ?: return null
        return java.io.File(volumeRoot, relativePath).absolutePath
    }

    /**
     * Resolves the parent [DocumentFile] directory for a single-file content
     * URI.  Supports both tree-based URIs (where the document ID encodes the
     * path) and synthetic `base::relative` URIs used internally.
     */

    internal fun resolveParentFolderForFile(filePath: String): DocumentFile? {
        val trimmed = filePath.trim()
        if (!trimmed.startsWith("content://")) return null

        // Synthetic URI: "content://authority/tree/rootId::relative/path/file.mp3"
        val syntheticIndex = trimmed.indexOf("::")
        if (syntheticIndex >= 0) {
            val base = trimmed.substring(0, syntheticIndex)
            val relative = trimmed.substring(syntheticIndex + 2).trim('/')
            val parentRelative = relative.substringBeforeLast('/', missingDelimiterValue = "")
            val root = DocumentFile.fromTreeUri(context, Uri.parse(base)) ?: return null
            return if (parentRelative.isEmpty()) {
                root
            } else {
                resolveRelativeDocumentDirectory(root, parentRelative)
            }
        }

        // Standard tree document URI: extract parent document ID from the
        // document ID by stripping the last path segment.
        val uri = Uri.parse(trimmed)
        val treeBase = treeUriBaseForDocumentUri(uri)
        val documentId = documentIdForUri(uri)
        if (treeBase != null && documentId != null) {
            val parentDocumentId = if (documentId.contains('/')) {
                documentId.substringBeforeLast('/')
            } else {
                // File is at the tree root 閳?parent is the root itself.
                startDocumentIdForTreeUri(treeBase) ?: return null
            }
            val parentUri = DocumentsContract.buildDocumentUriUsingTree(
                treeBase,
                parentDocumentId
            )
            return DocumentFile.fromTreeUri(context, parentUri)
                ?: DocumentFile.fromSingleUri(context, parentUri)
        }

        return null
    }

    internal fun renameDocumentFile(document: DocumentFile, name: String): DocumentFile? {
        val renamedUri = DocumentsContract.renameDocument(contentResolver, document.uri, name)
            ?: return null
        return DocumentFile.fromSingleUri(context, renamedUri)
    }

    internal fun resolveDocumentFileForFolderPath(folderPath: String): DocumentFile? {
        val trimmed = folderPath.trim()
        if (!trimmed.startsWith("content://")) return null
        val syntheticIndex = trimmed.indexOf("::")
        if (syntheticIndex >= 0) {
            val base = trimmed.substring(0, syntheticIndex)
            val relative = trimmed.substring(syntheticIndex + 2).replace("::", "/").trim('/')
            val root = DocumentFile.fromTreeUri(context, Uri.parse(base)) ?: return null
            return resolveRelativeDocumentDirectory(root, relative)
        }
        val uri = Uri.parse(trimmed)
        return DocumentFile.fromTreeUri(context, uri)
            ?: DocumentFile.fromSingleUri(context, uri)?.takeIf { it.isDirectory }
    }

    internal fun resolveDocumentRenameTarget(targetPath: String): DocumentRenameTarget? {
        val trimmed = targetPath.trim()
        if (!trimmed.startsWith("content://")) return null

        val syntheticIndex = trimmed.indexOf("::")
        if (syntheticIndex >= 0) {
            val base = trimmed.substring(0, syntheticIndex)
            val relative = trimmed.substring(syntheticIndex + 2).replace("::", "/").trim('/')
            val rootUri = Uri.parse(base)
            val targetUri = if (relative.isBlank()) {
                documentUriForTreeRoot(rootUri)
            } else {
                resolveRelativeDocumentUri(rootUri, relative)
            } ?: return null
            val parentRelative = relative.substringBeforeLast('/', missingDelimiterValue = "")
            return DocumentRenameTarget(
                uri = targetUri,
                rootUri = rootUri,
                syntheticBase = base,
                syntheticParentRelative = parentRelative,
                treeRoot = false
            )
        }

        val uri = Uri.parse(trimmed)
        if (DocumentsContract.isTreeUri(uri) && trimmed.indexOf("/document/") < 0) {
            val documentUri = documentUriForTreeRoot(uri) ?: return null
            return DocumentRenameTarget(
                uri = documentUri,
                rootUri = uri,
                syntheticBase = null,
                syntheticParentRelative = null,
                treeRoot = true
            )
        }

        return DocumentRenameTarget(
            uri = uri,
            rootUri = treeUriBaseForDocumentUri(uri),
            syntheticBase = null,
            syntheticParentRelative = null,
            treeRoot = false
        )
    }

    internal fun documentUriForTreeRoot(rootUri: Uri): Uri? {
        val documentId = startDocumentIdForTreeUri(rootUri) ?: return null
        return DocumentsContract.buildDocumentUriUsingTree(rootUri, documentId)
    }

    internal fun resolveDocumentUri(source: String): Uri? {
        val trimmed = source.trim()
        if (!trimmed.startsWith("content://")) return null

        val syntheticIndex = trimmed.indexOf("::")
        if (syntheticIndex >= 0) {
            val base = trimmed.substring(0, syntheticIndex)
            val relative = trimmed.substring(syntheticIndex + 2).replace("::", "/").trim('/')
            val rootUri = Uri.parse(base)
            return if (relative.isBlank()) {
                documentUriForTreeRoot(rootUri)
            } else {
                resolveRelativeDocumentUri(rootUri, relative)
            }
        }

        val uri = Uri.parse(trimmed)
        if (DocumentsContract.isTreeUri(uri) && trimmed.indexOf("/document/") < 0) {
            return documentUriForTreeRoot(uri)
        }
        return uri
    }

    internal fun treeUriBaseForDocumentUri(uri: Uri): Uri? {
        return try {
            val treeDocumentId = DocumentsContract.getTreeDocumentId(uri)
            val authority = uri.authority ?: return null
            DocumentsContract.buildTreeDocumentUri(authority, treeDocumentId)
        } catch (_: Exception) {
            null
        }
    }

    internal fun documentIdForUri(uri: Uri): String? {
        return try {
            DocumentsContract.getDocumentId(uri)
        } catch (_: Exception) {
            startDocumentIdForTreeUri(uri)
        }
    }

    internal fun resolveRelativeDocumentUri(rootUri: Uri, relativePath: String): Uri? {
        val startDocumentId = startDocumentIdForTreeUri(rootUri) ?: return null
        var currentDocumentId = startDocumentId
        val segments = relativePath.split('/').filter { it.isNotBlank() }
        if (segments.isEmpty()) {
            return DocumentsContract.buildDocumentUriUsingTree(rootUri, currentDocumentId)
        }
        for (segment in segments) {
            val child = findChildDocumentId(rootUri, currentDocumentId, segment) ?: return null
            currentDocumentId = child
        }
        return DocumentsContract.buildDocumentUriUsingTree(rootUri, currentDocumentId)
    }

    private fun findChildDocumentId(
        rootUri: Uri,
        parentDocumentId: String,
        displayName: String
    ): String? {
        val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            rootUri,
            parentDocumentId
        )
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME
        )
        return try {
            contentResolver.query(childUri, projection, null, null, null)?.use { cursor ->
                val documentIdIndex = cursor.getColumnIndex(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID
                )
                val nameIndex = cursor.getColumnIndex(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME
                )
                if (documentIdIndex < 0 || nameIndex < 0) return null
                while (cursor.moveToNext()) {
                    val name = normalizeDisplayName(cursor.getString(nameIndex)?.trim().orEmpty())
                    if (name != displayName) continue
                    return cursor.getString(documentIdIndex)
                }
                null
            }
        } catch (_: Exception) {
            null
        }
    }

    internal fun listChildFoldersViaDocumentsContract(rootUri: Uri): List<String>? {
        val startDocumentId = startDocumentIdForTreeUri(rootUri) ?: return null
        val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            rootUri,
            startDocumentId
        )
        val folders = mutableListOf<Pair<String, String>>()
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE
        )
        return try {
            contentResolver.query(childUri, projection, null, null, null)?.use { cursor ->
                val documentIdIndex = cursor.getColumnIndex(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID
                )
                val nameIndex = cursor.getColumnIndex(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME
                )
                val mimeIndex = cursor.getColumnIndex(
                    DocumentsContract.Document.COLUMN_MIME_TYPE
                )
                if (documentIdIndex < 0 || mimeIndex < 0) return null
                while (cursor.moveToNext()) {
                    val mime = cursor.getString(mimeIndex)
                    if (mime != DocumentsContract.Document.MIME_TYPE_DIR) continue
                    val documentId = cursor.getString(documentIdIndex) ?: continue
                    val name = if (nameIndex >= 0) cursor.getString(nameIndex) else null
                    val childDocumentUri = DocumentsContract
                        .buildDocumentUriUsingTree(rootUri, documentId)
                        .toString()
                    folders.add(
                        Pair(
                            normalizeDisplayName(name?.trim().orEmpty()).ifBlank {
                                documentId
                            },
                            childDocumentUri
                        )
                    )
                }
            } ?: return null
            folders.sortedBy { it.first.lowercase(Locale.US) }.map { it.second }
        } catch (_: Exception) {
            null
        }
    }

    private fun startDocumentIdForTreeUri(uri: Uri): String? {
        return try {
            if (DocumentsContract.isTreeUri(uri)) {
                DocumentsContract.getTreeDocumentId(uri)
            } else {
                DocumentsContract.getDocumentId(uri)
            }
        } catch (_: Exception) {
            null
        }
    }

    internal fun resolveRelativeDocumentDirectory(
        root: DocumentFile,
        relativePath: String
    ): DocumentFile? {
        var current: DocumentFile = root
        for (segment in relativePath.split('/').filter { it.isNotBlank() }) {
            current = current.listFiles().firstOrNull {
                it.isDirectory && sameDocumentName(it.name, segment)
            } ?: return null
        }
        return current
    }

    internal fun resolveRelativeDocument(
        root: DocumentFile,
        relativePath: String
    ): DocumentFile? {
        if (relativePath.isBlank()) return root
        var current = root
        for (segment in relativePath.split('/').filter { it.isNotBlank() }) {
            current = current.listFiles().firstOrNull {
                sameDocumentName(it.name, segment)
            } ?: return null
        }
        return current
    }

    internal fun normalizeDisplayName(raw: String): String {
        return raw.replace("%2F", "/", ignoreCase = true)
    }

    internal fun sameDocumentName(raw: String?, expected: String): Boolean {
        return normalizeDisplayName(raw?.trim().orEmpty())
            .equals(expected, ignoreCase = true)
    }

}
