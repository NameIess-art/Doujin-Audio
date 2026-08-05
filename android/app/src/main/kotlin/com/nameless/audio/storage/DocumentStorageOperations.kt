package com.nameless.audio.storage

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.documentfile.provider.DocumentFile
import org.json.JSONTokener
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID

internal fun <T> replaceSafDocument(
    targetName: String,
    existing: T?,
    staleBackup: T?,
    createTemp: () -> T?,
    writeTemp: (T) -> Boolean,
    rename: (T, String) -> T?,
    delete: (T) -> Boolean
): Boolean {
    val backupName = "$targetName.nameless.bak"
    var current = existing
    if (current == null && staleBackup != null) {
        current = runCatching { rename(staleBackup, targetName) }.getOrNull()
            ?: return false
    } else if (current != null && staleBackup != null) {
        return false
    }

    val temp = runCatching { createTemp() }.getOrNull() ?: return false
    fun cleanupTemp() {
        runCatching { delete(temp) }
    }
    if (runCatching { writeTemp(temp) }.getOrDefault(false).not()) {
        cleanupTemp()
        return false
    }

    val backup = if (current != null) {
        runCatching { rename(current, backupName) }.getOrNull().also {
            if (it == null) cleanupTemp()
        } ?: return false
    } else {
        null
    }

    val committed = runCatching { rename(temp, targetName) }.getOrNull()
    if (committed == null) {
        if (backup != null) {
            runCatching { rename(backup, targetName) }
        }
        cleanupTemp()
        return false
    }

    if (backup != null) {
        runCatching { delete(backup) }
    }
    return true
}

internal fun <T> createSafDocumentIfAbsent(
    listFiles: () -> List<T>,
    isTarget: (T) -> Boolean,
    sameDocument: (T, T) -> Boolean,
    create: () -> T?,
    write: (T) -> Boolean,
    delete: (T) -> Boolean
): Boolean {
    if (listFiles().any(isTarget)) return false
    val created = runCatching { create() }.getOrNull() ?: return false
    // Some SAF providers return an existing same-name document from
    // createFile(). Never write to or delete that URI.
    if (isTarget(created)) return false
    if (listFiles().any { isTarget(it) && !sameDocument(it, created) }) {
        runCatching { delete(created) }
        return false
    }
    if (!runCatching { write(created) }.getOrDefault(false)) {
        runCatching { delete(created) }
        return false
    }
    return true
}

internal class DocumentStorageOperations(
    private val context: Context
) {
    private val contentResolver get() = context.contentResolver
    private val filesDir get() = context.filesDir

    private data class DocumentRenameTarget(
        val uri: Uri,
        val rootUri: Uri?,
        val syntheticBase: String?,
        val syntheticParentRelative: String?,
        val treeRoot: Boolean
    )

    fun readJsonDocument(
        locationKind: String,
        basePath: String,
        name: String
    ): Map<String, Any?> {
        val folder = resolveJsonDocumentFolder(locationKind, basePath)
            ?: return mapOf("status" to "unreadable", "error" to "folder_unavailable")
        val target = runCatching { folder.listFiles().firstOrNull {
            it.isFile && sameDocumentName(it.name, name)
        } }.getOrElse {
            return mapOf("status" to "unreadable", "error" to it.toString())
        } ?: return mapOf("status" to "missing")
        return runCatching {
            val bytes = contentResolver.openInputStream(target.uri)?.use { it.readBytes() }
                ?: return mapOf("status" to "unreadable", "error" to "open_failed")
            mapOf(
                "status" to "found",
                "bytes" to bytes,
                "revision" to sha256(bytes)
            )
        }.getOrElse {
            mapOf("status" to "unreadable", "error" to it.toString())
        }
    }

    fun writeJsonDocument(
        locationKind: String,
        basePath: String,
        name: String,
        bytes: ByteArray,
        mode: String,
        expectedRevision: String?
    ): Map<String, Any?> {
        if (!isValidJson(bytes)) {
            return jsonWriteConflict("invalid_json")
        }
        if (mode != "createIfAbsent" && mode != "replaceIfRevision") {
            throw IllegalArgumentException("Unsupported JSON document write mode")
        }
        if (mode == "replaceIfRevision" && expectedRevision.isNullOrBlank()) {
            throw IllegalArgumentException("expectedRevision is required")
        }
        val folder = resolveJsonDocumentFolder(locationKind, basePath)
            ?: return jsonWriteConflict("folder_unavailable")
        val initialDocuments = runCatching { folder.listFiles().toList() }.getOrElse {
            return jsonWriteConflict(it.toString())
        }
        val existing = initialDocuments.firstOrNull {
            it.isFile && sameDocumentName(it.name, name)
        }
        if (mode == "createIfAbsent" && existing != null) {
            return jsonPreserved(existing)
        }
        if (mode == "replaceIfRevision") {
            if (existing == null) return jsonWriteConflict("document_missing")
            val revision = documentRevision(existing)
                ?: return jsonWriteConflict("document_unreadable")
            if (revision != expectedRevision) {
                return jsonWriteConflict("revision_mismatch", revision)
            }
        }

        val token = UUID.randomUUID().toString()
        val temporaryName = ".$name.$token.part"
        val temporary = runCatching {
            folder.createFile("application/octet-stream", temporaryName)
        }.getOrNull() ?: return jsonWriteConflict("staging_create_failed")
        if (temporary.uri == existing?.uri ||
            !sameDocumentName(temporary.name, temporaryName)) {
            return jsonWriteConflict("staging_collided_with_target")
        }
        fun deleteTemporary() {
            runCatching { temporary.delete() }
        }
        val staged = runCatching {
            contentResolver.openOutputStream(temporary.uri, "w")?.use { output ->
                output.write(bytes)
                output.flush()
            } != null
        }.getOrDefault(false)
        if (!staged) {
            deleteTemporary()
            return jsonWriteConflict("staging_write_failed")
        }
        val stagedBytes = runCatching {
            contentResolver.openInputStream(temporary.uri)?.use { it.readBytes() }
        }.getOrNull()
        if (stagedBytes == null || !isValidJson(stagedBytes) || sha256(stagedBytes) != sha256(bytes)) {
            deleteTemporary()
            return jsonWriteConflict("staging_validation_failed")
        }

        val current = runCatching { folder.listFiles().firstOrNull {
            it.isFile && sameDocumentName(it.name, name)
        } }.getOrNull()
        if (mode == "createIfAbsent" && current != null) {
            deleteTemporary()
            return jsonPreserved(current)
        }
        if (mode == "replaceIfRevision") {
            val revision = current?.let(::documentRevision)
            if (revision != expectedRevision) {
                deleteTemporary()
                return jsonWriteConflict("revision_mismatch", revision)
            }
        }

        var backup: DocumentFile? = null
        if (current != null) {
            val backupName = ".$name.$token.bak"
            backup = renameDocumentFile(current, backupName)
            if (backup == null || !sameDocumentName(backup.name, backupName)) {
                deleteTemporary()
                return jsonWriteConflict("backup_rename_failed")
            }
        }
        val committed = renameDocumentFile(temporary, name)
        if (committed == null || !sameDocumentName(committed.name, name)) {
            if (backup != null) runCatching { renameDocumentFile(backup, name) }
            deleteTemporary()
            return jsonWriteConflict("commit_rename_failed")
        }
        val committedRevision = documentRevision(committed)
        if (committedRevision != sha256(bytes)) {
            runCatching { committed.delete() }
            if (backup != null) runCatching { renameDocumentFile(backup, name) }
            return jsonWriteConflict("commit_validation_failed")
        }
        if (backup != null) runCatching { backup.delete() }
        return mapOf(
            "status" to if (mode == "createIfAbsent") "created" else "replaced",
            "revision" to committedRevision,
            "bytesWritten" to bytes.size
        )
    }

    fun deleteJsonDocument(
        locationKind: String,
        basePath: String,
        name: String,
        expectedRevision: String
    ): Map<String, Any?> {
        val folder = resolveJsonDocumentFolder(locationKind, basePath)
            ?: return mapOf("status" to "conflict", "error" to "folder_unavailable")
        val target = runCatching { folder.listFiles().firstOrNull {
            it.isFile && sameDocumentName(it.name, name)
        } }.getOrElse {
            return mapOf("status" to "conflict", "error" to it.toString())
        } ?: return mapOf("status" to "missing")
        val revision = documentRevision(target)
            ?: return mapOf("status" to "conflict", "error" to "document_unreadable")
        if (revision != expectedRevision) {
            return mapOf("status" to "conflict", "error" to "revision_mismatch")
        }
        return if (runCatching { target.delete() }.getOrDefault(false)) {
            mapOf("status" to "deleted")
        } else {
            mapOf("status" to "conflict", "error" to "delete_failed")
        }
    }

    private fun resolveJsonDocumentFolder(
        locationKind: String,
        basePath: String
    ): DocumentFile? = when (locationKind) {
        "folderChild" -> resolveDocumentFileForFolderPath(basePath)
        "fileSibling" -> resolveParentFolderForFile(basePath)
        else -> throw IllegalArgumentException("Unsupported JSON document location")
    }

    private fun documentRevision(document: DocumentFile): String? = runCatching {
        contentResolver.openInputStream(document.uri)?.use { sha256(it.readBytes()) }
    }.getOrNull()

    private fun jsonPreserved(document: DocumentFile): Map<String, Any?> = mapOf(
        "status" to "preserved",
        "revision" to documentRevision(document),
        "bytesWritten" to 0
    )

    private fun jsonWriteConflict(
        error: String,
        revision: String? = null
    ): Map<String, Any?> = mapOf(
        "status" to "conflict",
        "revision" to revision,
        "bytesWritten" to 0,
        "error" to error
    )

    private fun sha256(bytes: ByteArray): String = MessageDigest
        .getInstance("SHA-256")
        .digest(bytes)
        .joinToString("") { "%02x".format(it) }

    private fun isValidJson(bytes: ByteArray): Boolean = runCatching {
        if (bytes.isEmpty()) return false
        val text = bytes.toString(Charsets.UTF_8)
        if (text.isBlank()) return false
        val tokenizer = JSONTokener(text)
        tokenizer.nextValue()
        tokenizer.nextClean() == 0.toChar()
    }.getOrDefault(false)

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

        fun listChildFolders(folder: String): List<String> {
            val folderTrimmed = folder.trim()
            val uri = resolveContentUri(folderTrimmed)

            if (uri != null) {
                listChildFoldersViaDocumentsContract(uri)?.let { return it }
                val treeRoot = DocumentFile.fromTreeUri(context, uri)
                val root = treeRoot ?: DocumentFile.fromSingleUri(context, uri)
                    ?: throw IllegalStateException("Unable to resolve document folder.")
                if (!root.exists()) {
                    throw IllegalStateException("Document folder does not exist.")
                }
                return try {
                    root.listFiles()
                        .filter { it.isDirectory }
                        .map { it.uri.toString() }
                        .sortedBy { it.lowercase(Locale.US) }
                } catch (error: Exception) {
                    throw IllegalStateException("Unable to list document folder.", error)
                }
            }

            val root = File(folderTrimmed)
            if (!root.exists() || !root.isDirectory) {
                throw IllegalStateException("Filesystem folder does not exist.")
            }
            return try {
                root.listFiles()
                    ?.filter { it.isDirectory }
                    ?.map { it.absolutePath }
                    ?.sortedBy { it.lowercase(Locale.US) }
                    ?: throw IllegalStateException("Unable to list filesystem folder.")
            } catch (error: Exception) {
                throw IllegalStateException("Unable to list filesystem folder.", error)
            }
        }

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
                // File rename not available 閳?fall through to SAF rename.
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

            return file.uri.toString()
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
            val trimmed = targetPath.trim()
            if (!trimmed.startsWith("content://")) return false
            if (trimmed.contains("::")) {
                val syntheticIndex = trimmed.indexOf("::")
                val base = trimmed.substring(0, syntheticIndex)
                val relative = trimmed.substring(syntheticIndex + 2).trim('/')
                val root = DocumentFile.fromTreeUri(context, Uri.parse(base)) ?: return false
                return resolveRelativeDocument(root, relative)?.exists() == true
            }
            val uri = Uri.parse(trimmed)
            val document = DocumentFile.fromSingleUri(context, uri)
            val documentExists = document?.exists() == true
            if (documentExists) return true
            return DocumentFile.fromTreeUri(context, uri)?.exists() == true
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
            val documents = targetFolder.listFiles()
            val existing = documents.firstOrNull {
                it.isFile && sameDocumentName(it.name, targetName)
            }
            if (existing != null && !overwrite) return false

            val mimeType = MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(targetName.substringAfterLast('.', "").lowercase(Locale.US))
                ?: "application/octet-stream"
            if (!overwrite) {
                return writeSafDocumentIfAbsent(
                    folder = targetFolder,
                    targetName = targetName,
                    mimeType = mimeType
                ) { target ->
                    java.io.FileInputStream(source).use { input ->
                        contentResolver.openOutputStream(target.uri, "w")?.use { output ->
                            input.copyTo(output)
                            output.flush()
                        } ?: return@writeSafDocumentIfAbsent false
                    }
                    true
                }
            }

            val backupName = "$targetName.nameless.bak"
            val staleBackup = documents.firstOrNull {
                it.isFile && normalizeDisplayName(it.name?.trim().orEmpty()) == backupName
            }
            val tempName = "$targetName.nameless.part"
            val staleTemp = documents.firstOrNull {
                it.isFile && normalizeDisplayName(it.name?.trim().orEmpty()) == tempName
            }
            if (staleTemp != null && !runCatching { staleTemp.delete() }.getOrDefault(false)) {
                return false
            }

            return replaceSafDocument(
                targetName = targetName,
                existing = existing,
                staleBackup = staleBackup,
                createTemp = { targetFolder.createFile(mimeType, tempName) },
                writeTemp = { temp ->
                    java.io.FileInputStream(source).use { input ->
                        contentResolver.openOutputStream(temp.uri, "w")?.use { output ->
                            input.copyTo(output)
                            output.flush()
                        } ?: return@replaceSafDocument false
                    }
                    true
                },
                rename = { document, name -> renameDocumentFile(document, name) },
                delete = { document -> document.delete() }
            )
        }

        private fun renameDocumentFile(document: DocumentFile, name: String): DocumentFile? {
            val renamedUri = DocumentsContract.renameDocument(contentResolver, document.uri, name)
                ?: return null
            return DocumentFile.fromSingleUri(context, renamedUri)
        }

        fun copyFileToUri(sourcePath: String, targetUri: String): Boolean {
            val source = File(sourcePath)
            if (!source.exists() || !source.isFile) {
                throw IllegalArgumentException("source file does not exist")
            }
            val uri = Uri.parse(targetUri)
            java.io.FileInputStream(source).use { input ->
                contentResolver.openOutputStream(uri, "w")?.use { output ->
                    input.copyTo(output, 64 * 1024)
                    output.flush()
                } ?: throw IllegalStateException("cannot open export destination")
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

        internal fun resolveDocumentFileForFolderPath(folderPath: String): DocumentFile? {
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
                    sameDocumentName(it.name, segment)
                }
                current = when {
                    next == null -> current?.createDirectory(segment)
                    next.isDirectory -> next
                    segment.substringAfterLast('.', "")
                        .equals("json", ignoreCase = true) -> return null
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

        internal fun treeUriBaseForDocumentUri(uri: Uri): Uri? {
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

    private fun resolveRelativeDocumentDirectory(
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

    private fun resolveRelativeDocument(
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

    private fun normalizeDisplayName(raw: String): String {
        return raw.replace("%2F", "/", ignoreCase = true)
    }

    private fun sameDocumentName(raw: String?, expected: String): Boolean {
        return normalizeDisplayName(raw?.trim().orEmpty())
            .equals(expected, ignoreCase = true)
    }

    private fun writeSafDocumentIfAbsent(
        folder: DocumentFile,
        targetName: String,
        mimeType: String,
        write: (DocumentFile) -> Boolean
    ): Boolean {
        return createSafDocumentIfAbsent(
            listFiles = { folder.listFiles().toList() },
            isTarget = { it.isFile && sameDocumentName(it.name, targetName) },
            sameDocument = { first, second -> first.uri == second.uri },
            create = { folder.createFile(mimeType, targetName) },
            write = write,
            delete = { it.delete() }
        )
    }

}
