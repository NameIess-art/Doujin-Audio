package com.nameless.audio

import android.content.Context
import android.content.ContentUris
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.util.ArrayDeque
import java.util.Locale

internal class FileCacheOperations(
    private val context: Context
) {
    private val contentResolver get() = context.contentResolver
    private val filesDir get() = context.filesDir
    private val cacheDir get() = context.cacheDir
    private val externalCacheDir get() = context.externalCacheDir
    private val applicationCachePolicy = ApplicationCachePolicy(context)
    private val mediaScanOrchestrator by lazy {
        FileCacheMediaScanOrchestrator(
            resolveContentUri = ::resolveContentUri,
            contentUriToFilePath = ::contentUriToFilePath,
            scanDocumentTree = ::scanDocumentTree,
            scanFileSystemAsDocumentTree = ::scanFileSystemAsDocumentTree,
            scanFileSystem = ::scanFileSystem,
            scanMediaStore = ::scanMediaStore
        )
    }
    private val videoFrameResolver by lazy {
        FileCacheVideoFrameResolver(
            context = context,
            cacheDir = cacheDir,
            touchCacheFile = ::touchCacheFile,
            enforceApplicationCacheLimit = { enforceApplicationCacheLimit() },
            resolveFilePath = ::contentUriToFilePath
        )
    }
    val defaultMaxApplicationCacheBytes: Long = ApplicationCachePolicy.DEFAULT_MAX_BYTES

    fun cacheFromUri(uriString: String, name: String, index: Int): String {
        val uri = Uri.parse(uriString)
        val extension = name.substringAfterLast('.', "")
        val safeExt = if (extension.isBlank()) "bin" else extension
        val outDir = File(filesDir, "nameless_audio_imports")
        if (!outDir.exists()) {
            outDir.mkdirs()
        }
        val outFile = File(outDir, "${System.currentTimeMillis()}_${index}.$safeExt")
        contentResolver.openInputStream(uri).use { input ->
            if (input == null) {
                throw IllegalStateException("cannot open input stream")
            }
            FileOutputStream(outFile).use { output ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    output.write(buffer, 0, read)
                }
                output.flush()
            }
        }
        return outFile.absolutePath
    }

    private val supportedImageExtensions = setOf(
        "jpg", "jpeg", "png", "webp", "bmp", "gif"
    )

    private val supportedSubtitleExtensions = setOf(
        "vtt", "webvtt", "lrc", "srt", "ass", "ssa"
    )

    private val subtitleMatchMediaExtensions = setOf(
        "mp3", "aac", "m4a", "ogg", "oga", "opus", "wav", "flac",
        "mp4", "mkv", "webm", "mov", "m4v", "avi", "3gp"
    )

    private val preferredCoverBasenames = listOf(
        "cover", "folder", "front", "album", "artwork", "poster"
    )

    private val audioDetailBackupFileName = "nameless-audio.json"
    private val legacyAudioDetailBackupFileName = ".nameless-audio.json"

        data class ScannedTrack(
            val path: String,
            val title: String,
            val groupKey: String,
            val groupTitle: String,
            val groupSubtitle: String,
            val isVideo: Boolean = false,
            val scannedAtMs: Long = System.currentTimeMillis(),
            val fileSizeBytes: Long? = null,
            val modifiedAtMs: Long? = null
        )

        private data class DocumentScanNode(
            val documentId: String,
            val relative: String,
            val groupKey: String,
            val groupTitle: String,
            val groupSubtitle: String
        )

        private data class DocumentFileScanNode(
            val dir: DocumentFile,
            val relative: String,
            val groupKey: String,
            val groupTitle: String,
            val groupSubtitle: String
        )

        private data class FileScanNode(
            val dir: File,
            val groupKey: String,
            val groupTitle: String,
            val groupSubtitle: String
        )

        private data class FileDocumentScanNode(
            val dir: File,
            val relative: String,
            val groupKey: String,
            val groupTitle: String,
            val groupSubtitle: String
        )

        private data class DocumentRenameTarget(
            val uri: Uri,
            val rootUri: Uri?,
            val syntheticBase: String?,
            val syntheticParentRelative: String?,
            val treeRoot: Boolean
        )

        fun scanFolder(folder: String): List<ScannedTrack> {
            return mediaScanOrchestrator.scanFolder(folder)
        }

        fun listChildFolders(folder: String): List<String> {
            val folderTrimmed = folder.trim()
            val uri = resolveContentUri(folderTrimmed)

            if (uri != null) {
                listChildFoldersViaDocumentsContract(uri)?.let { return it }
                val treeRoot = DocumentFile.fromTreeUri(context, uri)
                val root = treeRoot ?: DocumentFile.fromSingleUri(context, uri) ?: return emptyList()
                if (!root.exists()) return emptyList()
                return try {
                    root.listFiles()
                        .filter { it.isDirectory }
                        .map { it.uri.toString() }
                        .sortedBy { it.lowercase(Locale.US) }
                } catch (_: Exception) {
                    emptyList()
                }
            }

            val root = File(folderTrimmed)
            if (!root.exists() || !root.isDirectory) {
                return emptyList()
            }
            return try {
                root.listFiles()
                    ?.filter { it.isDirectory }
                    ?.map { it.absolutePath }
                    ?.sortedBy { it.lowercase(Locale.US) }
                    ?: emptyList()
            } catch (_: Exception) {
                emptyList()
            }
        }

        private fun resolveContentUri(rawFolder: String): Uri? {
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

        fun renameDocumentTarget(targetPath: String, newName: String): HashMap<String, String> {
            val target = resolveDocumentRenameTarget(targetPath)
                ?: throw IllegalArgumentException("Cannot resolve rename target.")

            // For tree-root targets the SAF provider may refuse to rename the
            // directory because the app only holds a grant on that root itself,
            // not on its parent.  Fall back to java.io.File.renameTo which works
            // when the app has MANAGE_EXTERNAL_STORAGE or the path is on primary
            // external storage.
            if (target.treeRoot) {
                val fileRenamedPath = tryRenameTreeRootViaFile(target, newName)
                if (fileRenamedPath != null) {
                    return hashMapOf("path" to fileRenamedPath)
                }
                // File rename not available 鈥?fall through to SAF rename.
            }

            val renamedUri = DocumentsContract.renameDocument(contentResolver, target.uri, newName)
                ?: throw IllegalStateException("Provider did not return renamed document uri.")
            var renamedPermissionUri: Uri? = renamedUri
            val renamedPath = when {
                target.syntheticBase != null -> {
                    renamedPermissionUri = null
                    val parent = target.syntheticParentRelative.orEmpty()
                    if (parent.isBlank()) {
                        "${target.syntheticBase}::$newName"
                    } else {
                        "${target.syntheticBase}::$parent/$newName"
                    }
                }
                target.treeRoot -> {
                    val documentId = documentIdForUri(renamedUri)
                        ?: throw IllegalStateException("Cannot resolve renamed tree document id.")
                    val authority = renamedUri.authority ?: target.rootUri?.authority
                        ?: throw IllegalStateException("Cannot resolve renamed tree authority.")
                    val renamedTreeUri = DocumentsContract.buildTreeDocumentUri(authority, documentId)
                    renamedPermissionUri = renamedTreeUri
                    renamedTreeUri.toString()
                }
                else -> renamedUri.toString()
            }
            renamedPermissionUri?.let { persistRenamedPermission(target.rootUri ?: target.uri, it) }
            return hashMapOf("path" to renamedPath)
        }

        /**
         * Attempts to rename a tree-root directory using [java.io.File].
         * This works when the app has MANAGE_EXTERNAL_STORAGE or the path is on
         * primary external storage and the document ID encodes the relative path
         * (e.g. "primary:Music/MyFolder").
         *
         * Returns the new content URI string on success, or null if the rename
         * could not be performed via this path.
         */
        private fun tryRenameTreeRootViaFile(
            target: DocumentRenameTarget,
            newName: String
        ): String? {
            val rootUri = target.rootUri ?: return null
            val documentId = documentIdForUri(target.uri) ?: return null
            // Document IDs for primary external storage look like "primary:path/to/dir".
            val colonIndex = documentId.indexOf(':')
            if (colonIndex < 0) return null
            val volumeName = documentId.substring(0, colonIndex)
            val relativePath = documentId.substring(colonIndex + 1)
            val volumeRoot = resolveVolumeRoot(volumeName) ?: return null
            val oldFile = java.io.File(volumeRoot, relativePath)
            if (!oldFile.exists() || !oldFile.isDirectory) return null
            val parentFile = oldFile.parentFile ?: return null
            val newFile = java.io.File(parentFile, newName)
            if (!oldFile.renameTo(newFile)) return null

            // Build the new tree URI with the updated document ID.
            val newRelativePath = newFile.absolutePath.removePrefix(volumeRoot).trimStart('/')
            val newDocumentId = "$volumeName:$newRelativePath"
            val authority = rootUri.authority ?: return null
            val newTreeUri = DocumentsContract.buildTreeDocumentUri(authority, newDocumentId)
            try {
                persistRenamedPermission(rootUri, newTreeUri)
            } catch (_: Exception) {
                // Permission migration is best-effort.
            }
            return newTreeUri.toString()
        }

        /**
         * Resolves the root path for a storage volume name.
         * "primary" maps to the primary external storage root.
         */
        private fun resolveVolumeRoot(volumeName: String): String? {
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

        private fun persistRenamedPermission(oldUri: Uri, newUri: Uri) {
            val existing = contentResolver.persistedUriPermissions.firstOrNull {
                it.uri == oldUri
            } ?: return
            var modeFlags = 0
            if (existing.isReadPermission) {
                modeFlags = modeFlags or Intent.FLAG_GRANT_READ_URI_PERMISSION
            }
            if (existing.isWritePermission) {
                modeFlags = modeFlags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            }
            if (modeFlags == 0) return
            try {
                contentResolver.takePersistableUriPermission(newUri, modeFlags)
            } catch (_: Exception) {
                // Some providers keep the old grant alive or do not expose a new persistable grant.
            }
        }

        fun readAudioDetailBackup(folderPath: String): String? {
            val folder = resolveDocumentFileForFolderPath(folderPath)
            if (folder != null && folder.exists()) {
                val backup = folder.listFiles().firstOrNull {
                    it.isFile && it.name == audioDetailBackupFileName
                } ?: folder.listFiles().firstOrNull {
                    it.isFile && it.name == legacyAudioDetailBackupFileName
                }
                if (backup != null) {
                    return contentResolver.openInputStream(backup.uri)?.use { input ->
                        input.bufferedReader(Charsets.UTF_8).readText()
                    }
                }
            }
            // SAF access failed (e.g. after a File.renameTo) 鈥?fall back to File I/O.
            val filePath = contentUriToFilePath(folderPath) ?: return null
            val backupFile = java.io.File(filePath, audioDetailBackupFileName)
            if (backupFile.exists()) return backupFile.readText(Charsets.UTF_8)
            val legacyFile = java.io.File(filePath, legacyAudioDetailBackupFileName)
            if (legacyFile.exists()) return legacyFile.readText(Charsets.UTF_8)
            return null
        }

        fun writeAudioDetailBackup(folderPath: String, json: String): Boolean {
            val folder = resolveDocumentFileForFolderPath(folderPath)
            if (folder != null && folder.exists()) {
                val backup = folder.listFiles().firstOrNull {
                    it.isFile && it.name == audioDetailBackupFileName
                } ?: folder.createFile("application/json", audioDetailBackupFileName)
                if (backup != null) {
                    contentResolver.openOutputStream(backup.uri, "wt")?.use { output ->
                        output.write(json.toByteArray(Charsets.UTF_8))
                        output.flush()
                    } ?: return false
                    return true
                }
            }
            // SAF access failed 鈥?fall back to File I/O.
            val filePath = contentUriToFilePath(folderPath) ?: return false
            return try {
                val backupFile = java.io.File(filePath, audioDetailBackupFileName)
                backupFile.writeText(json, Charsets.UTF_8)
                true
            } catch (_: Exception) {
                false
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
         * Reads the `nameless-audio.json` file from the parent directory of the
         * given single-file content URI.  Returns the raw JSON string, or null if
         * the file does not exist or cannot be read.
         */
        fun readSingleFileDetailBackup(filePath: String): String? {
            val parentFolder = resolveParentFolderForFile(filePath) ?: return null
            val backup = parentFolder.listFiles().firstOrNull {
                it.isFile && it.name == audioDetailBackupFileName
            } ?: return null
            return contentResolver.openInputStream(backup.uri)?.use { input ->
                input.bufferedReader(Charsets.UTF_8).readText()
            }
        }

        /**
         * Writes [json] into `nameless-audio.json` in the parent directory of the
         * given single-file content URI.  Returns true on success.
         */
        fun writeSingleFileDetailBackup(filePath: String, json: String): Boolean {
            val parentFolder = resolveParentFolderForFile(filePath) ?: return false
            val backup = parentFolder.listFiles().firstOrNull {
                it.isFile && it.name == audioDetailBackupFileName
            } ?: parentFolder.createFile("application/json", audioDetailBackupFileName)
                ?: return false
            contentResolver.openOutputStream(backup.uri, "wt")?.use { output ->
                output.write(json.toByteArray(Charsets.UTF_8))
                output.flush()
            } ?: return false
            return true
        }

        /**
         * Resolves the parent [DocumentFile] directory for a single-file content
         * URI.  Supports both tree-based URIs (where the document ID encodes the
         * path) and synthetic `base::relative` URIs used internally.
         */
        private fun resolveParentFolderForFile(filePath: String): DocumentFile? {
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
                    // File is at the tree root 鈥?parent is the root itself.
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

        fun writeFileBytesToFolder(
            folderPath: String,
            name: String,
            bytes: ByteArray,
            mimeType: String?
        ): String? {
            val folder = resolveDocumentFileForFolderPath(folderPath) ?: return null
            val file = folder.listFiles().firstOrNull {
                it.isFile && normalizeDisplayName(it.name?.trim().orEmpty()) == name
            } ?: folder.createFile(
                mimeType ?: MimeTypeMap.getSingleton()
                    .getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase(Locale.US))
                    ?: "application/octet-stream",
                name
            ) ?: return null

            contentResolver.openOutputStream(file.uri, "w")?.use { output ->
                output.write(bytes)
                output.flush()
            } ?: return null

            return cacheDocumentCover(file, "$folderPath/$name")
        }

        fun ensureFolderPath(
            folderPath: String,
            relativePath: String,
            overwrite: Boolean
        ): Boolean {
            val folder = ensureDocumentFileForFolderPath(folderPath, relativePath, overwrite)
                ?: return false
            return folder.exists()
        }

        fun documentPathExists(targetPath: String): Boolean {
            val folder = resolveDocumentFileForFolderPath(targetPath) ?: return false
            return folder.exists()
        }

        fun copyFileToFolder(
            sourcePath: String,
            folderPath: String,
            relativePath: String,
            overwrite: Boolean
        ): Boolean {
            val source = java.io.File(sourcePath)
            if (!source.exists() || !source.isFile) return false

            val normalizedRelative = relativePath.trim().replace('\\', '/')
            if (normalizedRelative.isBlank()) return false

            val folder = resolveDocumentFileForFolderPath(folderPath) ?: return false
            val targetFolder = ensureRelativeDocumentDirectory(
                folder,
                normalizedRelative.substringBeforeLast('/', missingDelimiterValue = ""),
                overwrite
            ) ?: return false

            val targetName = normalizedRelative.substringAfterLast('/')
            var existing = targetFolder.listFiles().firstOrNull {
                it.isFile && normalizeDisplayName(it.name?.trim().orEmpty()) == targetName
            }
            if (existing != null) {
                if (!overwrite) return false
                if (!existing.delete()) return false
                existing = null
            }

            val mimeType = MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(targetName.substringAfterLast('.', "").lowercase(Locale.US))
                ?: "application/octet-stream"
            val target = existing ?: targetFolder.createFile(mimeType, targetName) ?: return false
            java.io.FileInputStream(source).use { input ->
                contentResolver.openOutputStream(target.uri, "w")?.use { output ->
                    input.copyTo(output)
                    output.flush()
                } ?: return false
            }
            return true
        }

        fun deleteDocumentPath(targetPath: String): Boolean {
            val target = resolveDocumentFileForFolderPath(targetPath) ?: return false
            return target.delete()
        }

        private fun ensureDocumentFileForFolderPath(
            folderPath: String,
            relativePath: String,
            overwrite: Boolean
        ): DocumentFile? {
            val folder = resolveDocumentFileForFolderPath(folderPath) ?: return null
            return ensureRelativeDocumentDirectory(folder, relativePath, overwrite)
        }

        private fun resolveDocumentFileForFolderPath(folderPath: String): DocumentFile? {
            val trimmed = folderPath.trim()
            if (!trimmed.startsWith("content://")) return null
            val syntheticIndex = trimmed.indexOf("::")
            if (syntheticIndex >= 0) {
                val base = trimmed.substring(0, syntheticIndex)
                val relative = trimmed.substring(syntheticIndex + 2).trim('/')
                val root = DocumentFile.fromTreeUri(context, Uri.parse(base)) ?: return null
                return resolveRelativeDocumentDirectory(root, relative)
            }
            val uri = Uri.parse(trimmed)
            return DocumentFile.fromTreeUri(context, uri)
                ?: DocumentFile.fromSingleUri(context, uri)?.takeIf { it.isDirectory }
        }

        private fun ensureRelativeDocumentDirectory(
            root: DocumentFile,
            relativeDirectory: String,
            overwrite: Boolean
        ): DocumentFile? {
            if (relativeDirectory.isBlank()) return root
            var current: DocumentFile? = root
            for (segment in relativeDirectory.split('/')) {
                if (segment.isBlank()) continue
                val next = current?.listFiles()?.firstOrNull {
                    normalizeDisplayName(it.name?.trim().orEmpty()) == segment
                }
                current = when {
                    next == null -> current?.createDirectory(segment)
                    next.isDirectory -> next
                    overwrite -> {
                        if (!next.delete()) return null
                        current?.createDirectory(segment)
                    }
                    else -> return null
                } ?: return null
            }
            return current
        }

        private fun resolveDocumentRenameTarget(targetPath: String): DocumentRenameTarget? {
            val trimmed = targetPath.trim()
            if (!trimmed.startsWith("content://")) return null

            val syntheticIndex = trimmed.indexOf("::")
            if (syntheticIndex >= 0) {
                val base = trimmed.substring(0, syntheticIndex)
                val relative = trimmed.substring(syntheticIndex + 2).trim('/')
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

        private fun documentUriForTreeRoot(rootUri: Uri): Uri? {
            val documentId = startDocumentIdForTreeUri(rootUri) ?: return null
            return DocumentsContract.buildDocumentUriUsingTree(rootUri, documentId)
        }

        private fun treeUriBaseForDocumentUri(uri: Uri): Uri? {
            return try {
                val treeDocumentId = DocumentsContract.getTreeDocumentId(uri)
                val authority = uri.authority ?: return null
                DocumentsContract.buildTreeDocumentUri(authority, treeDocumentId)
            } catch (_: Exception) {
                null
            }
        }

        private fun documentIdForUri(uri: Uri): String? {
            return try {
                DocumentsContract.getDocumentId(uri)
            } catch (_: Exception) {
                startDocumentIdForTreeUri(uri)
            }
        }

        private fun resolveRelativeDocumentUri(rootUri: Uri, relativePath: String): Uri? {
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

        private fun listChildFoldersViaDocumentsContract(rootUri: Uri): List<String>? {
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

        private fun scanDocumentTree(rootUri: Uri, output: MutableMap<String, ScannedTrack>) {
            if (scanDocumentTreeViaDocumentsContract(rootUri, output)) return

            val treeRoot = DocumentFile.fromTreeUri(context, rootUri)
            val root = treeRoot ?: DocumentFile.fromSingleUri(context, rootUri) ?: return
            if (!root.exists()) return

            val rootName = normalizeDisplayName(root.name?.ifBlank { "Folder" } ?: "Folder")
            val rootUriString = root.uri.toString()
            val pending = ArrayDeque<DocumentFileScanNode>()
            pending.add(
                DocumentFileScanNode(
                    dir = root,
                    relative = "",
                    groupKey = rootUriString,
                    groupTitle = rootName,
                    groupSubtitle = rootName
                )
            )

            while (pending.isNotEmpty()) {
                val current = pending.removeFirst()
                val children = try {
                    current.dir.listFiles()
                } catch (_: Exception) {
                    emptyArray()
                }
                for (child in children) {
                    val childName = normalizeDisplayName(child.name?.trim().orEmpty())
                    if (child.isDirectory) {
                        val nextRelative = when {
                            current.relative.isEmpty() -> childName
                            childName.isEmpty() -> current.relative
                            else -> "${current.relative}/$childName"
                        }
                        val nextTitle = if (nextRelative.isEmpty()) {
                            rootName
                        } else {
                            nextRelative.substringAfterLast('/')
                        }
                        pending.add(
                            DocumentFileScanNode(
                                dir = child,
                                relative = nextRelative,
                                groupKey = if (nextRelative.isEmpty()) {
                                    rootUriString
                                } else {
                                    "$rootUriString::$nextRelative"
                                },
                                groupTitle = nextTitle.ifBlank { rootName },
                                groupSubtitle = if (nextRelative.isEmpty()) {
                                    rootName
                                } else {
                                    "$rootName/$nextRelative"
                                }
                            )
                        )
                        continue
                    }
                    if (!child.isFile) continue
                    val safeName = childName.ifEmpty {
                        normalizeDisplayName(child.uri.lastPathSegment ?: "audio_file")
                    }
                    val media = mediaNameInfoOrNull(safeName, child.type) ?: continue
                    val childUri = child.uri.toString()
                    output.putIfAbsent(
                        childUri,
                        ScannedTrack(
                            path = childUri,
                            title = media.title,
                            groupKey = current.groupKey,
                            groupTitle = current.groupTitle,
                            groupSubtitle = current.groupSubtitle,
                            isVideo = media.isVideo,
                            fileSizeBytes = child.length().takeIf { it >= 0 },
                            modifiedAtMs = child.lastModified().takeIf { it > 0 }
                        )
                    )
                }
            }
        }

        private fun scanDocumentTreeViaDocumentsContract(
            rootUri: Uri,
            output: MutableMap<String, ScannedTrack>
        ): Boolean {
            val startDocumentId = startDocumentIdForTreeUri(rootUri) ?: return false
            val rootName = normalizeDisplayName(
                startDocumentId.substringAfterLast(':')
                    .substringAfterLast('/')
                    .ifBlank { "Folder" }
            )
            val rootUriString = rootUri.toString()
            val pending = ArrayDeque<DocumentScanNode>()
            pending.add(
                DocumentScanNode(
                    documentId = startDocumentId,
                    relative = "",
                    groupKey = rootUriString,
                    groupTitle = rootName,
                    groupSubtitle = rootName
                )
            )
            val projection = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED
            )

            return try {
                while (pending.isNotEmpty()) {
                    val current = pending.removeFirst()
                    val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                        rootUri,
                        current.documentId
                    )
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
                        val sizeIndex = cursor.getColumnIndex(
                            DocumentsContract.Document.COLUMN_SIZE
                        )
                        val modifiedIndex = cursor.getColumnIndex(
                            DocumentsContract.Document.COLUMN_LAST_MODIFIED
                        )
                        if (documentIdIndex < 0 || mimeIndex < 0) return false

                        while (cursor.moveToNext()) {
                            val documentId = cursor.getString(documentIdIndex) ?: continue
                            val mime = cursor.getString(mimeIndex)
                            val displayName = normalizeDisplayName(
                                if (nameIndex >= 0) {
                                    cursor.getString(nameIndex)?.trim().orEmpty()
                                } else {
                                    ""
                                }
                            ).ifBlank {
                                normalizeDisplayName(documentId.substringAfterLast('/'))
                            }

                            if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                                val nextRelative = when {
                                    current.relative.isEmpty() -> displayName
                                    displayName.isEmpty() -> current.relative
                                    else -> "${current.relative}/$displayName"
                                }
                                val nextTitle = if (nextRelative.isEmpty()) {
                                    rootName
                                } else {
                                    nextRelative.substringAfterLast('/')
                                }
                                pending.add(
                                    DocumentScanNode(
                                        documentId = documentId,
                                        relative = nextRelative,
                                        groupKey = if (nextRelative.isEmpty()) {
                                            rootUriString
                                        } else {
                                            "$rootUriString::$nextRelative"
                                        },
                                        groupTitle = nextTitle.ifBlank { rootName },
                                        groupSubtitle = if (nextRelative.isEmpty()) {
                                            rootName
                                        } else {
                                            "$rootName/$nextRelative"
                                        }
                                    )
                                )
                                continue
                            }
                            val media = mediaNameInfoOrNull(displayName, mime) ?: continue

                            val documentUri = DocumentsContract
                                .buildDocumentUriUsingTree(rootUri, documentId)
                                .toString()
                            val fileSizeBytes = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                                cursor.getLong(sizeIndex).takeIf { it >= 0 }
                            } else {
                                null
                            }
                            val modifiedAtMs = if (
                                modifiedIndex >= 0 &&
                                !cursor.isNull(modifiedIndex)
                            ) {
                                cursor.getLong(modifiedIndex).takeIf { it > 0 }
                            } else {
                                null
                            }

                            output.putIfAbsent(
                                documentUri,
                                ScannedTrack(
                                    path = documentUri,
                                    title = media.title,
                                    groupKey = current.groupKey,
                                    groupTitle = current.groupTitle,
                                    groupSubtitle = current.groupSubtitle,
                                    isVideo = media.isVideo,
                                    fileSizeBytes = fileSizeBytes,
                                    modifiedAtMs = modifiedAtMs
                                )
                            )
                        }
                    }
                }
                true
            } catch (_: Exception) {
                false
            }
        }

        private fun startDocumentIdForTreeUri(uri: Uri): String? {
            return try {
                val segments = uri.pathSegments
                val documentIndex = segments.indexOf("document")
                if (documentIndex >= 0 && documentIndex + 1 < segments.size) {
                    segments[documentIndex + 1]
                } else {
                    DocumentsContract.getTreeDocumentId(uri)
                }
            } catch (_: Exception) {
                null
            }
        }

        fun resolveTrackSubtitle(
            trackPath: String,
            groupKey: String?
        ): HashMap<String, String>? {
            if (!trackPath.startsWith("content://")) return null
            val rootUriString = when {
                !groupKey.isNullOrBlank() && groupKey.contains("::") ->
                    groupKey.substringBefore("::")
                !groupKey.isNullOrBlank() && groupKey.startsWith("content://") -> groupKey
                else -> trackPath.substringBefore("/document/", missingDelimiterValue = trackPath)
            }
            val rootUri = Uri.parse(rootUriString)
            val trackUri = Uri.parse(trackPath)
            val trackDocumentId = startDocumentIdForTreeUri(trackUri) ?: return null
            val rootDocumentId = startDocumentIdForTreeUri(rootUri) ?: return null
            val parentDocumentId = if (trackDocumentId.contains('/')) {
                trackDocumentId.substringBeforeLast('/')
            } else {
                rootDocumentId
            }
            val audioStem = normalizeSubtitleMatchStem(
                trackDocumentId.substringAfterLast('/')
            )
            val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                rootUri,
                parentDocumentId
            )
            val projection = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE
            )
            val candidates = mutableListOf<Triple<Int, String, Uri>>()

            try {
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
                        val documentId = cursor.getString(documentIdIndex) ?: continue
                        val mime = cursor.getString(mimeIndex)
                        if (mime == DocumentsContract.Document.MIME_TYPE_DIR) continue
                        val name = normalizeDisplayName(
                            if (nameIndex >= 0) {
                                cursor.getString(nameIndex)?.trim().orEmpty()
                            } else {
                                ""
                            }
                        ).ifBlank {
                            normalizeDisplayName(documentId.substringAfterLast('/'))
                        }
                        if (!isSupportedSubtitleEntry(name, mime)) continue
                        val stem = normalizeSubtitleMatchStem(name)
                        val rank = when {
                            stem == audioStem -> 0
                            stem.startsWith("$audioStem.") -> 1
                            stem.startsWith("${audioStem}_") -> 2
                            stem.startsWith("$audioStem ") -> 3
                            else -> 10
                        }
                        candidates.add(
                            Triple(
                                rank,
                                name.lowercase(Locale.US),
                                DocumentsContract.buildDocumentUriUsingTree(rootUri, documentId)
                            )
                        )
                    }
                }
            } catch (_: Exception) {
                return null
            }

            val best = candidates
                .filter { it.first < 10 }
                .sortedWith(compareBy<Triple<Int, String, Uri>> { it.first }.thenBy { it.second })
                .firstOrNull() ?: return null
            val subtitleUri = best.third
            val subtitleName = best.second
            val text = readDocumentText(subtitleUri) ?: return null
            val extension = subtitleName.substringAfterLast('.', "")
            if (extension.isBlank()) return null
            return hashMapOf(
                "sourcePath" to subtitleUri.toString(),
                "extension" to extension,
                "text" to text
            )
        }

        private fun readDocumentText(uri: Uri): String? {
            return try {
                contentResolver.openInputStream(uri)?.bufferedReader(
                    StandardCharsets.UTF_8
                )?.use { reader -> reader.readText() }
            } catch (_: Exception) {
                null
            }
        }

        private fun scanFileSystem(root: File, output: MutableMap<String, ScannedTrack>) {
            val rootPath = root.absolutePath
            val pending = ArrayDeque<FileScanNode>()
            pending.add(
                FileScanNode(
                    dir = root,
                    groupKey = rootPath,
                    groupTitle = root.name.ifBlank { rootPath },
                    groupSubtitle = rootPath
                )
            )

            while (pending.isNotEmpty()) {
                val current = pending.removeFirst()
                val children = try {
                    current.dir.listFiles()
                } catch (_: Exception) {
                    null
                } ?: continue

                for (child in children) {
                    if (child.isDirectory) {
                        val childPath = child.absolutePath
                        pending.add(
                            FileScanNode(
                                dir = child,
                                groupKey = childPath,
                                groupTitle = child.name.ifBlank { childPath },
                                groupSubtitle = childPath
                            )
                        )
                        continue
                    }
                    if (!child.isFile) continue
                    val media = mediaNameInfoOrNull(child.name) ?: continue
                    val childPath = child.absolutePath
                    output.putIfAbsent(
                        childPath,
                        ScannedTrack(
                            path = childPath,
                            title = media.title,
                            groupKey = current.groupKey,
                            groupTitle = current.groupTitle,
                            groupSubtitle = current.groupSubtitle,
                            isVideo = media.isVideo,
                            fileSizeBytes = child.length().takeIf { it >= 0 },
                            modifiedAtMs = child.lastModified().takeIf { it > 0 }
                        )
                    )
                }
            }
        }

        private fun scanFileSystemAsDocumentTree(
            rootUri: Uri,
            root: File,
            output: MutableMap<String, ScannedTrack>
        ) {
            val rootDocumentId = startDocumentIdForTreeUri(rootUri) ?: return
            val rootName = normalizeDisplayName(root.name.ifBlank { "Folder" })
            val rootUriString = rootUri.toString()
            val pending = ArrayDeque<FileDocumentScanNode>()
            pending.add(
                FileDocumentScanNode(
                    dir = root,
                    relative = "",
                    groupKey = rootUriString,
                    groupTitle = rootName,
                    groupSubtitle = rootName
                )
            )

            while (pending.isNotEmpty()) {
                val current = pending.removeFirst()
                val children = try {
                    current.dir.listFiles()
                } catch (_: Exception) {
                    null
                } ?: continue

                for (child in children) {
                    if (child.isDirectory) {
                        val childName = child.name.ifBlank { "Folder" }
                        val nextRelative = when {
                            current.relative.isEmpty() -> childName
                            childName.isEmpty() -> current.relative
                            else -> "${current.relative}/$childName"
                        }
                        val nextTitle = if (nextRelative.isEmpty()) {
                            rootName
                        } else {
                            nextRelative.substringAfterLast('/')
                        }
                        pending.add(
                            FileDocumentScanNode(
                                dir = child,
                                relative = nextRelative,
                                groupKey = if (nextRelative.isEmpty()) {
                                    rootUriString
                                } else {
                                    "$rootUriString::$nextRelative"
                                },
                                groupTitle = nextTitle.ifBlank { rootName },
                                groupSubtitle = if (nextRelative.isEmpty()) {
                                    rootName
                                } else {
                                    "$rootName/$nextRelative"
                                }
                            )
                        )
                        continue
                    }
                    if (!child.isFile) continue
                    val safeName = normalizeDisplayName(child.name.ifBlank { "audio_file" })
                    val media = mediaNameInfoOrNull(safeName) ?: continue
                    val relativePath = if (current.relative.isEmpty()) {
                        child.name
                    } else {
                        "${current.relative}/${child.name}"
                    }
                    if (relativePath.isBlank()) continue
                    val documentId = "$rootDocumentId/$relativePath"
                    val documentUri = DocumentsContract.buildDocumentUriUsingTree(
                        rootUri,
                        documentId
                    ).toString()
                    output.putIfAbsent(
                        documentUri,
                        ScannedTrack(
                            path = documentUri,
                            title = media.title,
                            groupKey = current.groupKey,
                            groupTitle = current.groupTitle,
                            groupSubtitle = current.groupSubtitle,
                            isVideo = media.isVideo,
                            fileSizeBytes = child.length().takeIf { it >= 0 },
                            modifiedAtMs = child.lastModified().takeIf { it > 0 }
                        )
                    )
                }
            }
        }

        private fun scanMediaStore(folderPath: String, output: MutableMap<String, ScannedTrack>) {
            val normalized = folderPath
                .replace('\\', '/')
                .trimEnd('/')
            if (normalized.isBlank()) return

            val projection = mutableListOf(
                MediaStore.Audio.Media._ID,
                MediaStore.Audio.Media.DISPLAY_NAME,
                MediaStore.Audio.Media.RELATIVE_PATH,
                MediaStore.Audio.Media.SIZE,
                MediaStore.Audio.Media.DATE_MODIFIED
            )
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                projection.add(MediaStore.Audio.Media.DATA)
            }

            val basePath = if (normalized.startsWith("/storage/emulated/0/")) {
                normalized.removePrefix("/storage/emulated/0/")
            } else if (normalized.startsWith("/sdcard/")) {
                normalized.removePrefix("/sdcard/")
            } else {
                null
            }?.trim('/')

            val relPrefix = basePath?.let {
                if (it.isEmpty()) null else "$it/"
            } ?: return

            val selection = "${MediaStore.Audio.Media.RELATIVE_PATH} LIKE ?"
            val selectionArgs = arrayOf("$relPrefix%")
            val audioUri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI

            contentResolver.query(
                audioUri,
                projection.toTypedArray(),
                selection,
                selectionArgs,
                null
            )?.use { cursor ->
                val idIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                val displayNameIndex =
                    cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
                val relativeIndex =
                    cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.RELATIVE_PATH)
                val sizeIndex = cursor.getColumnIndex(MediaStore.Audio.Media.SIZE)
                val dateModifiedIndex =
                    cursor.getColumnIndex(MediaStore.Audio.Media.DATE_MODIFIED)
                val dataIndex = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    cursor.getColumnIndex(MediaStore.Audio.Media.DATA)
                } else {
                    -1
                }

                while (cursor.moveToNext()) {
                    val id = cursor.getLong(idIndex)
                    val displayName = normalizeDisplayName(cursor.getString(displayNameIndex) ?: "audio_file")
                    val media = mediaNameInfoOrNull(displayName) ?: continue
                    val relative = normalizeDisplayName(cursor.getString(relativeIndex)?.trimEnd('/') ?: "")
                    val fullPath = if (dataIndex >= 0) cursor.getString(dataIndex) else null
                    val contentPath = ContentUris.withAppendedId(audioUri, id).toString()
                    val fileSizeBytes = if (sizeIndex >= 0) cursor.getLong(sizeIndex) else null
                    val modifiedAtMs = if (dateModifiedIndex >= 0) {
                        cursor.getLong(dateModifiedIndex).takeIf { it > 0 }?.times(1000L)
                    } else {
                        null
                    }

                    val groupTitle = relative.substringAfterLast('/', missingDelimiterValue = relative)
                        .ifBlank { relPrefix.trimEnd('/').substringAfterLast('/') }
                    val groupSubtitle = relative.ifBlank { relPrefix.trimEnd('/') }
                    val groupKey = "ms:${relative.ifBlank { relPrefix }}"
                    val playablePath = fullPath?.takeIf { it.isNotBlank() } ?: contentPath

                    output.putIfAbsent(
                        playablePath,
                        ScannedTrack(
                            path = playablePath,
                            title = media.title,
                            groupKey = groupKey,
                            groupTitle = groupTitle.ifBlank { "Folder" },
                            groupSubtitle = groupSubtitle,
                            isVideo = media.isVideo,
                            fileSizeBytes = fileSizeBytes,
                            modifiedAtMs = modifiedAtMs
                        )
                    )
                }
            }
        }

        private fun normalizeDisplayName(raw: String): String {
            return MediaNameMetadata.normalizeDisplayName(raw)
        }

        private fun mediaNameInfoOrNull(
            name: String,
            mime: String? = null
        ): MediaNameInfo? {
            return MediaNameMetadata.mediaNameInfoOrNull(name, mime)
        }

        private data class DocumentImageCandidate(
            val uri: Uri,
            val name: String,
            val sortPath: String
        )

        fun resolveTrackCover(
            trackPath: String,
            groupKey: String?,
            rootFolder: String?
        ): String? {
            if (!trackPath.startsWith("content://")) {
                return null
            }

            if (!rootFolder.isNullOrBlank() && rootFolder.startsWith("content://")) {
                val coverDirectory = resolveDocumentFileForFolderPath(rootFolder)
                if (coverDirectory != null && coverDirectory.exists()) {
                    val cover = findPreferredCoverInDocumentTree(coverDirectory)
                    if (cover != null) return cacheDocumentCover(cover, rootFolder)
                }
                // SAF fallback via File I/O.
                val filePath = contentUriToFilePath(rootFolder)
                if (filePath != null) {
                    return findPreferredCoverViaFile(filePath, trackPath)
                }
                return null
            }

            val rootTreeUri = when {
                groupKey.isNullOrBlank() -> null
                groupKey.contains("::") -> groupKey.substringBefore("::")
                else -> groupKey
            }?.takeIf { it.startsWith("content://") } ?: return null

            val relativeDirectory = when {
                groupKey.isNullOrBlank() -> ""
                groupKey.contains("::") -> groupKey.substringAfter("::", "")
                else -> ""
            }

            val treeRoot = DocumentFile.fromTreeUri(context, Uri.parse(rootTreeUri))
                ?: DocumentFile.fromSingleUri(context, Uri.parse(rootTreeUri))
            if (treeRoot != null && treeRoot.exists()) {
                val candidateDirectories = resolveCandidateDocumentDirectories(
                    treeRoot,
                    relativeDirectory
                )
                candidateDirectories.forEach { directory ->
                    val cover = findPreferredCoverInDocumentDirectory(directory) ?: return@forEach
                    return cacheDocumentCover(cover, trackPath)
                }
                return null
            }

            // SAF access failed (e.g. after a File.renameTo) 鈥?fall back to File I/O.
            val folderPath = if (relativeDirectory.isBlank()) {
                contentUriToFilePath(rootTreeUri)
            } else {
                val base = contentUriToFilePath(rootTreeUri) ?: return null
                java.io.File(base, relativeDirectory).absolutePath
            } ?: return null
            return findPreferredCoverViaFile(folderPath, trackPath)
        }

        fun maxApplicationCacheBytes(): Long {
            return applicationCachePolicy.maxBytes()
        }

        fun setMaxApplicationCacheBytes(maxBytes: Long) {
            applicationCachePolicy.setMaxBytes(maxBytes)
        }

        fun clearApplicationCache(): Long {
            return applicationCachePolicy.clear()
        }

        fun enforceApplicationCacheLimit(
            maxBytes: Long = maxApplicationCacheBytes()
        ) {
            applicationCachePolicy.enforceLimit(maxBytes)
        }

        private fun touchCacheFile(file: File) {
            applicationCachePolicy.touch(file)
        }

        /**
         * Finds the preferred cover image in [folderPath] using File I/O and
         * caches it, returning the cached path.
         */
        private fun findPreferredCoverViaFile(folderPath: String, cacheKey: String): String? {
            val dir = java.io.File(folderPath)
            if (!dir.exists() || !dir.isDirectory) return null
            val files = dir.listFiles() ?: return null
            val imageExtensions = setOf("jpg", "jpeg", "png", "webp")
            val preferredNames = listOf("cover", "folder", "front", "album", "artwork", "poster")
            // Preferred names first, then any image.
            val preferred = files.firstOrNull { f ->
                val ext = f.extension.lowercase(Locale.US)
                if (!imageExtensions.contains(ext)) return@firstOrNull false
                val stem = f.nameWithoutExtension.lowercase(Locale.US)
                preferredNames.any { stem == it || stem.startsWith(it) }
            } ?: files.firstOrNull { f ->
                imageExtensions.contains(f.extension.lowercase(Locale.US))
            } ?: return null
            return cacheFileAsCover(preferred, cacheKey)
        }

        /**
         * Copies [imageFile] into the cover cache and returns the cached path.
         */
        private fun cacheFileAsCover(imageFile: java.io.File, cacheKey: String): String? {
            val coverCacheDir = java.io.File(cacheDir, "nameless_audio_covers")
            if (!coverCacheDir.exists()) coverCacheDir.mkdirs()
            val outputFile = java.io.File(
                coverCacheDir,
                "cover_${kotlin.math.abs(cacheKey.hashCode())}.jpg"
            )
            if (outputFile.exists() && outputFile.length() > 0) {
                touchCacheFile(outputFile)
                return outputFile.absolutePath
            }
            return try {
                imageFile.copyTo(outputFile, overwrite = true)
                touchCacheFile(outputFile)
                enforceApplicationCacheLimit()
                outputFile.absolutePath
            } catch (_: Exception) {
                null
            }
        }

        fun resolveVideoFrame(
            trackPath: String,
            modifiedAtMs: Long?
        ): String? {
            return videoFrameResolver.resolve(trackPath, modifiedAtMs)
        }

        fun discoverRootImages(
            trackPath: String,
            groupKey: String?,
            rootFolder: String?
        ): List<String> {
            if (!rootFolder.isNullOrBlank() && rootFolder.startsWith("content://")) {
                val root = resolveDocumentFileForFolderPath(rootFolder)
                if (root != null && root.exists() && root.canRead()) {
                    val candidates = collectImageDocumentsRecursively(root)
                    if (candidates.isNotEmpty()) {
                        return candidates.mapNotNull { candidate ->
                            cacheDocumentCover(candidate.file, "$trackPath|${candidate.sortPath}")
                        }
                    }
                }
                
                val filePath = contentUriToFilePath(rootFolder)
                if (filePath != null) {
                    val dir = java.io.File(filePath)
                    if (dir.exists() && dir.isDirectory) {
                        val candidates = dir.walkTopDown().filter {
                            it.isFile && isSupportedImageEntry(it.name, null)
                        }.toList()
                        if (candidates.isNotEmpty()) {
                            return candidates.mapNotNull { f ->
                                val relativePath = f.absolutePath.removePrefix(dir.absolutePath).trim('/')
                                cacheFileAsCover(f, "$trackPath|${relativePath.ifEmpty { f.name }}")
                            }
                        }
                    }
                }
                return emptyList()
            }

            val rootUriString = when {
                !groupKey.isNullOrBlank() && groupKey.contains("::") ->
                    groupKey.substringBefore("::")
                !groupKey.isNullOrBlank() && groupKey.startsWith("content://") -> groupKey
                else -> null
            } ?: return emptyList()
            val rootUri = Uri.parse(rootUriString)
            val candidates = collectImageDocumentsViaDocumentsContract(rootUri)
            if (candidates.isEmpty()) return emptyList()
            return candidates.mapNotNull { candidate ->
                cacheDocumentImage(
                    uri = candidate.uri,
                    name = candidate.name,
                    cacheKey = "$trackPath|${candidate.uri}"
                )
            }
        }

        private fun collectImageDocumentsViaDocumentsContract(
            rootUri: Uri
        ): List<DocumentImageCandidate> {
            val startDocumentId = startDocumentIdForTreeUri(rootUri) ?: return emptyList()
            data class Node(val documentId: String, val relative: String)
            val pending = ArrayDeque<Node>()
            pending.add(Node(startDocumentId, ""))
            val images = mutableListOf<DocumentImageCandidate>()
            val projection = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE
            )

            try {
                while (pending.isNotEmpty()) {
                    val current = pending.removeFirst()
                    val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                        rootUri,
                        current.documentId
                    )
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
                        if (documentIdIndex < 0 || mimeIndex < 0) return emptyList()

                        while (cursor.moveToNext()) {
                            val documentId = cursor.getString(documentIdIndex) ?: continue
                            val mime = cursor.getString(mimeIndex)
                            val name = normalizeDisplayName(
                                if (nameIndex >= 0) {
                                    cursor.getString(nameIndex)?.trim().orEmpty()
                                } else {
                                    ""
                                }
                            ).ifBlank {
                                normalizeDisplayName(documentId.substringAfterLast('/'))
                            }

                            if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                                val nextRelative = when {
                                    current.relative.isEmpty() -> name
                                    name.isEmpty() -> current.relative
                                    else -> "${current.relative}/$name"
                                }
                                pending.add(Node(documentId, nextRelative))
                                continue
                            }
                            if (!isSupportedImageEntry(name, mime)) continue
                            val documentUri = DocumentsContract
                                .buildDocumentUriUsingTree(rootUri, documentId)
                            val sortPath = if (current.relative.isEmpty()) {
                                name
                            } else {
                                "${current.relative}/$name"
                            }
                            images.add(DocumentImageCandidate(documentUri, name, sortPath))
                        }
                    }
                }
            } catch (_: Exception) {
                return emptyList()
            }

            return images.sortedWith { left, right ->
                val priority = compareCoverNames(left.name, right.name)
                if (priority != 0) priority else left.sortPath.lowercase(Locale.US)
                    .compareTo(right.sortPath.lowercase(Locale.US))
            }
        }

        private fun resolveCandidateDocumentDirectories(
            root: DocumentFile,
            relativeDirectory: String
        ): List<DocumentFile> {
            val visited = mutableListOf<DocumentFile>()
            var current: DocumentFile = root
            visited.add(current)
            if (relativeDirectory.isBlank()) {
                return visited.asReversed()
            }
            for (segment in relativeDirectory.split('/')) {
                if (segment.isBlank()) continue
                val next = current.listFiles().firstOrNull {
                    it.isDirectory && normalizeDisplayName(it.name?.trim().orEmpty()) == segment
                } ?: break
                current = next
                visited.add(current)
            }
            return visited.asReversed()
        }

        private fun resolveRelativeDocumentDirectory(
            root: DocumentFile,
            relativeDirectory: String
        ): DocumentFile? {
            if (relativeDirectory.isBlank()) return root
            var current: DocumentFile? = root
            for (segment in relativeDirectory.split('/')) {
                if (segment.isBlank()) continue
                current = current?.listFiles()?.firstOrNull {
                    it.isDirectory && normalizeDisplayName(it.name?.trim().orEmpty()) == segment
                } ?: return null
            }
            return current
        }

        private fun findPreferredCoverInDocumentDirectory(directory: DocumentFile): DocumentFile? {
            val images = collectImageDocuments(directory)
            if (images.isEmpty()) return null
            return images.sortedWith { left, right ->
                compareCoverNames(
                    normalizeDisplayName(left.name ?: left.uri.lastPathSegment ?: ""),
                    normalizeDisplayName(right.name ?: right.uri.lastPathSegment ?: "")
                )
            }.firstOrNull()
        }

        private data class DocumentCoverCandidate(
            val file: DocumentFile,
            val sortPath: String
        )

        private fun findPreferredCoverInDocumentTree(directory: DocumentFile): DocumentFile? {
            val images = collectImageDocumentsRecursively(directory)
            if (images.isEmpty()) return null
            return images.sortedWith { left, right ->
                val leftName = normalizeDisplayName(left.file.name ?: left.file.uri.lastPathSegment ?: "")
                val rightName = normalizeDisplayName(right.file.name ?: right.file.uri.lastPathSegment ?: "")
                val priority = compareCoverNames(leftName, rightName)
                if (priority != 0) priority else left.sortPath.lowercase(Locale.US)
                    .compareTo(right.sortPath.lowercase(Locale.US))
            }.firstOrNull()?.file
        }

        private fun collectImageDocuments(directory: DocumentFile): List<DocumentFile> {
            return try {
                val images = mutableListOf<DocumentFile>()
                for (child in directory.listFiles()) {
                    if (child.isFile && isSupportedImageDocument(child)) {
                        images.add(child)
                    }
                }
                images
            } catch (_: Exception) {
                emptyList()
            }
        }

        private fun collectImageDocumentsRecursively(directory: DocumentFile): List<DocumentCoverCandidate> {
            data class Node(val folder: DocumentFile, val relative: String)

            return try {
                val pending = ArrayDeque<Node>()
                val images = mutableListOf<DocumentCoverCandidate>()
                pending.add(Node(directory, ""))

                while (pending.isNotEmpty()) {
                    val current = pending.removeFirst()
                    for (child in current.folder.listFiles()) {
                        val name = normalizeDisplayName(child.name?.trim().orEmpty()).ifBlank {
                            normalizeDisplayName(child.uri.lastPathSegment ?: "")
                        }
                        if (child.isDirectory) {
                            val nextRelative = when {
                                current.relative.isEmpty() -> name
                                name.isEmpty() -> current.relative
                                else -> "${current.relative}/$name"
                            }
                            pending.add(Node(child, nextRelative))
                            continue
                        }
                        if (!child.isFile || !isSupportedImageDocument(child)) continue
                        val sortPath = if (current.relative.isEmpty()) {
                            name
                        } else {
                            "${current.relative}/$name"
                        }
                        images.add(DocumentCoverCandidate(file = child, sortPath = sortPath))
                    }
                }

                images
            } catch (_: Exception) {
                emptyList()
            }
        }

        private fun isSupportedImageDocument(file: DocumentFile): Boolean {
            val mime = file.type?.lowercase(Locale.US)
            if (mime != null && mime.startsWith("image/")) {
                return true
            }
            val extension = file.name
                ?.substringAfterLast('.', "")
                ?.lowercase(Locale.US)
                .orEmpty()
            return extension in supportedImageExtensions
        }

        private fun isSupportedImageEntry(name: String, mime: String?): Boolean {
            val normalizedMime = mime?.lowercase(Locale.US)
            if (normalizedMime != null && normalizedMime.startsWith("image/")) {
                return true
            }
            val extension = name.substringAfterLast('.', "").lowercase(Locale.US)
            return extension in supportedImageExtensions
        }

        private fun isSupportedSubtitleEntry(name: String, mime: String?): Boolean {
            val normalizedMime = mime?.lowercase(Locale.US)
            if (normalizedMime == "text/vtt" ||
                normalizedMime == "application/x-subrip" ||
                normalizedMime == "text/plain"
            ) {
                return true
            }
            val extension = name.substringAfterLast('.', "").lowercase(Locale.US)
            return extension in supportedSubtitleExtensions
        }

        private fun normalizeSubtitleMatchStem(name: String): String {
            var current = normalizeDisplayName(name).lowercase(Locale.US)
            while (current.isNotEmpty()) {
                val extension = current.substringAfterLast('.', "")
                if (extension.isEmpty()) {
                    break
                }
                if (extension !in supportedSubtitleExtensions &&
                    extension !in subtitleMatchMediaExtensions
                ) {
                    break
                }
                current = current.substringBeforeLast('.')
            }
            return current
        }

        private fun compareCoverNames(leftNameRaw: String, rightNameRaw: String): Int {
            val leftName = leftNameRaw.substringBeforeLast('.', leftNameRaw).lowercase(Locale.US)
            val rightName = rightNameRaw.substringBeforeLast('.', rightNameRaw).lowercase(Locale.US)
            val scoreCompare = coverPriority(leftName).compareTo(coverPriority(rightName))
            if (scoreCompare != 0) return scoreCompare
            val nameCompare = leftName.compareTo(rightName)
            if (nameCompare != 0) return nameCompare
            return leftNameRaw.lowercase(Locale.US).compareTo(rightNameRaw.lowercase(Locale.US))
        }

        private fun coverPriority(baseName: String): Int {
            val exactMatchIndex = preferredCoverBasenames.indexOf(baseName)
            if (exactMatchIndex >= 0) {
                return exactMatchIndex
            }
            for (i in preferredCoverBasenames.indices) {
                if (baseName.contains(preferredCoverBasenames[i])) {
                    return 100 + i
                }
            }
            return 200
        }

        private fun cacheDocumentCover(file: DocumentFile, trackPath: String): String? {
            val extension = file.name
                ?.substringAfterLast('.', "")
                ?.ifBlank { "img" }
                ?: "img"
            val coverDir = File(cacheDir, "nameless_audio_covers")
            if (!coverDir.exists()) {
                coverDir.mkdirs()
            }
            val outputFile = File(
                coverDir,
                "cover_${kotlin.math.abs(trackPath.hashCode())}.$extension"
            )
            if (outputFile.exists() && outputFile.length() > 0) {
                touchCacheFile(outputFile)
                return outputFile.absolutePath
            }

            return try {
                contentResolver.openInputStream(file.uri)?.use { input ->
                    FileOutputStream(outputFile).use { output ->
                        input.copyTo(output)
                        output.flush()
                    }
                } ?: return null
                touchCacheFile(outputFile)
                enforceApplicationCacheLimit()
                outputFile.absolutePath
            } catch (_: Exception) {
                if (outputFile.exists()) {
                    outputFile.delete()
                }
                null
            }
        }

        private fun cacheDocumentImage(uri: Uri, name: String, cacheKey: String): String? {
            val extension = name.substringAfterLast('.', "").ifBlank { "img" }
            val coverDir = File(cacheDir, "nameless_audio_covers")
            if (!coverDir.exists()) {
                coverDir.mkdirs()
            }
            val outputFile = File(
                coverDir,
                "cover_${kotlin.math.abs(cacheKey.hashCode())}.$extension"
            )
            if (outputFile.exists() && outputFile.length() > 0) {
                touchCacheFile(outputFile)
                return outputFile.absolutePath
            }

            return try {
                contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(outputFile).use { output ->
                        input.copyTo(output)
                        output.flush()
                    }
                } ?: return null
                touchCacheFile(outputFile)
                enforceApplicationCacheLimit()
                outputFile.absolutePath
            } catch (_: Exception) {
                if (outputFile.exists()) {
                    outputFile.delete()
                }
                null
            }
        }
}
