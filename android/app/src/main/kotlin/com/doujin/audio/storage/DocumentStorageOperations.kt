package com.doujin.audio.storage

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.Locale

internal class DocumentStorageOperations(
    private val context: Context
) {
    private val contentResolver get() = context.contentResolver
    internal val contentResolverForPermissions get() = contentResolver
    private val filesDir get() = context.filesDir

    private val paths = DocumentPathResolver(context)
    private val jsonDocuments = JsonDocumentStorage(context, paths)
    private val workTexts = WorkTextDocumentReader(context, paths)

    fun readJsonDocument(locationKind: String, basePath: String, name: String) =
        jsonDocuments.readJsonDocument(locationKind, basePath, name)

    fun writeJsonDocument(locationKind: String, basePath: String, name: String,
        bytes: ByteArray, mode: String, expectedRevision: String?) =
        jsonDocuments.writeJsonDocument(locationKind, basePath, name, bytes, mode, expectedRevision)

    fun deleteJsonDocument(locationKind: String, basePath: String, name: String,
        expectedRevision: String) =
        jsonDocuments.deleteJsonDocument(locationKind, basePath, name, expectedRevision)

    fun discoverWorkTexts(folderPath: String) = workTexts.discoverWorkTexts(folderPath)
    fun readDocumentBytes(path: String) = workTexts.readDocumentBytes(path)

    internal fun resolveContentUri(rawFolder: String) = paths.resolveContentUri(rawFolder)
    internal fun contentUriToFilePath(contentUri: String) = paths.contentUriToFilePath(contentUri)
    internal fun resolveDocumentFileForFolderPath(folderPath: String) = paths.resolveDocumentFileForFolderPath(folderPath)
    internal fun documentUriForTreeRoot(rootUri: Uri) = paths.documentUriForTreeRoot(rootUri)
    internal fun resolveDocumentUri(source: String) = paths.resolveDocumentUri(source)
    internal fun treeUriBaseForDocumentUri(uri: Uri) = paths.treeUriBaseForDocumentUri(uri)
    internal fun resolveRelativeDocumentUri(rootUri: Uri, relativePath: String) = paths.resolveRelativeDocumentUri(rootUri, relativePath)

    fun cacheFromUri(uriString: String, name: String, index: Int): String {
        val uri = Uri.parse(uriString)
        val extension = name.substringAfterLast('.', "")
        val safeExt = if (extension.isBlank()) "bin" else extension
        val outDir = File(filesDir, "doujin_audio_imports")
        if (!outDir.exists()) {
            outDir.mkdirs()
        }
        val outFile = File.createTempFile("import_${index}_", ".$safeExt", outDir)
        copyImportedDocumentToFile(outFile) {
            contentResolver.openInputStream(uri)
                ?: throw IllegalStateException("cannot open input stream")
        }
        return outFile.absolutePath
    }

    fun listChildFolders(folder: String): List<String> {
        val folderTrimmed = folder.trim()
        val uri = resolveContentUri(folderTrimmed)

        if (uri != null) {
            paths.listChildFoldersViaDocumentsContract(uri)?.let { return it }
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

    fun renameDocumentTarget(targetPath: String, newName: String): HashMap<String, String> =
        PersistedUriPermissionOperations.withPermissionLock {
            renameDocumentTargetLocked(targetPath, newName)
        }

    private fun renameDocumentTargetLocked(
        targetPath: String,
        newName: String
    ): HashMap<String, String> {
        val target = paths.resolveDocumentRenameTarget(targetPath)
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

        val previousName = DocumentFile.fromSingleUri(context, target.uri)?.name
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
                val documentId = paths.documentIdForUri(renamedUri)
                    ?: throw IllegalStateException("Cannot resolve renamed tree document id.")
                val authority = renamedUri.authority ?: target.rootUri?.authority
                    ?: throw IllegalStateException("Cannot resolve renamed tree authority.")
                val renamedTreeUri = DocumentsContract.buildTreeDocumentUri(authority, documentId)
                renamedPermissionUri = renamedTreeUri
                renamedTreeUri.toString()
            }
            else -> renamedUri.toString()
        }
        val permissionSourceUri = if (shouldMigratePermissionAfterRename(
                hasTreeRootGrant = target.rootUri != null,
                renamingTreeRoot = target.treeRoot
            )
        ) {
            target.rootUri ?: target.uri
        } else {
            null
        }
        try {
            if (permissionSourceUri != null && renamedPermissionUri != null) {
                PersistedUriPermissionOperations.migrateRenamedGrant(
                    contentResolver,
                    permissionSourceUri,
                    renamedPermissionUri
                )
            }
        } catch (error: SecurityException) {
            if (!previousName.isNullOrBlank()) {
                runCatching {
                    DocumentsContract.renameDocument(
                        contentResolver,
                        renamedUri,
                        previousName
                    )
                }
            }
            throw error
        }
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
        val documentId = paths.documentIdForUri(target.uri) ?: return null
        // Document IDs for primary external storage look like "primary:path/to/dir".
        val colonIndex = documentId.indexOf(':')
        if (colonIndex < 0) return null
        val volumeName = documentId.substring(0, colonIndex)
        val relativePath = documentId.substring(colonIndex + 1)
        val volumeRoot = paths.resolveVolumeRoot(volumeName) ?: return null
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
            PersistedUriPermissionOperations.migrateRenamedGrant(
                contentResolver,
                rootUri,
                newTreeUri
            )
        } catch (error: SecurityException) {
            runCatching { newFile.renameTo(oldFile) }
            throw error
        }
        return newTreeUri.toString()
    }

    fun writeFileBytesToFolder(
        folderPath: String,
        name: String,
        bytes: ByteArray,
        mimeType: String?
    ): String? {
        val folder = resolveDocumentFileForFolderPath(folderPath) ?: return null
        val resolvedMimeType = mimeType ?: MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase(Locale.US))
            ?: "application/octet-stream"
        val saved = replaceSafDocumentInFolder(folder, name, resolvedMimeType) { temporary ->
            contentResolver.openOutputStream(temporary.uri, "w")?.use { output ->
                output.write(bytes)
                output.flush()
            } ?: return@replaceSafDocumentInFolder false
            true
        }
        return saved?.uri?.toString()
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
            val relative = trimmed.substring(syntheticIndex + 2).replace("::", "/").trim('/')
            val root = DocumentFile.fromTreeUri(context, Uri.parse(base)) ?: return false
            return paths.resolveRelativeDocument(root, relative)?.exists() == true
        }
        val uri = Uri.parse(trimmed)
        return runCatching {
            if (DocumentsContract.isTreeUri(uri)) {
                val treeDoc = DocumentFile.fromTreeUri(context, uri)
                treeDoc != null && (treeDoc.exists() || treeDoc.canRead() || treeDoc.canWrite())
            } else {
                val singleDoc = DocumentFile.fromSingleUri(context, uri)
                singleDoc != null && (singleDoc.exists() || singleDoc.canRead())
            }
        }.getOrDefault(false)
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

        return replaceSafDocumentInFolder(targetFolder, targetName, mimeType) { temporary ->
            java.io.FileInputStream(source).use { input ->
                contentResolver.openOutputStream(temporary.uri, "w")?.use { output ->
                    input.copyTo(output)
                    output.flush()
                } ?: return@replaceSafDocumentInFolder false
            }
            true
        } != null
    }

    private fun replaceSafDocumentInFolder(
        folder: DocumentFile,
        targetName: String,
        mimeType: String,
        writeTemp: (DocumentFile) -> Boolean
    ): DocumentFile? {
        val documents = folder.listFiles()
        val existing = documents.firstOrNull {
            it.isFile && paths.sameDocumentName(it.name, targetName)
        }
        val backupName = "$targetName.doujin.bak"
        val staleBackup = documents.firstOrNull {
            it.isFile && paths.normalizeDisplayName(it.name?.trim().orEmpty()) == backupName
        }
        val tempName = "$targetName.doujin.part"
        val staleTemp = documents.firstOrNull {
            it.isFile && paths.normalizeDisplayName(it.name?.trim().orEmpty()) == tempName
        }
        if (staleTemp != null && !runCatching { staleTemp.delete() }.getOrDefault(false)) {
            return null
        }

        return replaceSafDocument(
            targetName = targetName,
            existing = existing,
            staleBackup = staleBackup,
            createTemp = { folder.createFile(mimeType, tempName) },
            writeTemp = writeTemp,
            rename = { document, name -> paths.renameDocumentFile(document, name) },
            delete = { document -> document.delete() }
        )
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
        val trimmed = targetPath.trim()
        if (!trimmed.startsWith("content://")) return false
        if (trimmed.contains("::")) {
            val syntheticIndex = trimmed.indexOf("::")
            val base = trimmed.substring(0, syntheticIndex)
            val relative = trimmed.substring(syntheticIndex + 2).replace("::", "/").trim('/')
            val root = DocumentFile.fromTreeUri(context, Uri.parse(base)) ?: return false
            return paths.resolveRelativeDocument(root, relative)?.delete() == true
        }
        val uri = Uri.parse(trimmed)
        val document = DocumentFile.fromSingleUri(context, uri)
        if (document?.exists() == true) return document.delete()
        return DocumentFile.fromTreeUri(context, uri)?.delete() == true
    }

    private fun ensureDocumentFileForFolderPath(
        folderPath: String,
        relativePath: String,
        overwrite: Boolean
    ): DocumentFile? {
        val folder = resolveDocumentFileForFolderPath(folderPath) ?: return null
        return ensureRelativeDocumentDirectory(folder, relativePath, overwrite)
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
                paths.sameDocumentName(it.name, segment)
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

    private fun writeSafDocumentIfAbsent(
        folder: DocumentFile,
        targetName: String,
        mimeType: String,
        write: (DocumentFile) -> Boolean
    ): Boolean {
        return createSafDocumentIfAbsent(
            listFiles = { folder.listFiles().toList() },
            isTarget = { it.isFile && paths.sameDocumentName(it.name, targetName) },
            sameDocument = { first, second -> first.uri == second.uri },
            create = { folder.createFile(mimeType, targetName) },
            write = write,
            delete = { it.delete() }
        )
    }
}

internal fun copyImportedDocumentToFile(outFile: File, openInput: () -> InputStream) {
    try {
        openInput().use { input ->
            FileOutputStream(outFile).use { output ->
                input.copyTo(output, 64 * 1024)
                output.flush()
            }
        }
    } catch (error: Throwable) {
        try {
            if (outFile.exists() && !outFile.delete()) {
                error.addSuppressed(IOException("Cannot remove failed import: ${outFile.absolutePath}"))
            }
        } catch (cleanupError: Exception) {
            error.addSuppressed(cleanupError)
        }
        throw error
    }
}
