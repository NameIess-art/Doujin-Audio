package com.doujin.audio.storage

import android.content.Context
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import org.json.JSONTokener
import java.io.IOException
import java.security.MessageDigest
import java.util.Locale

internal class JsonDocumentStorage(
    private val context: Context,
    private val paths: DocumentPathResolver
) {
    private val contentResolver get() = context.contentResolver
    fun readJsonDocument(
        locationKind: String,
        basePath: String,
        name: String
    ): Map<String, Any?> {
        val folder = resolveJsonDocumentFolder(locationKind, basePath)
            ?: return mapOf("status" to "unreadable", "error" to "folder_unavailable")
        return JsonDocumentOperationLocks.withLock(jsonDocumentLockKey(folder, name)) {
            readJsonDocumentLocked(folder, name)
        }
    }

    private fun readJsonDocumentLocked(
        folder: DocumentFile,
        name: String
    ): Map<String, Any?> {
        val recovery = recoverJsonDocument(folder, name, forRead = true).getOrElse {
            return mapOf("status" to "unreadable", "error" to it.toString())
        }
        if (recovery.failed) {
            return mapOf("status" to "unreadable", "error" to "transaction_recovery_failed")
        }
        val target = recovery.document ?: return mapOf("status" to "missing")
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
        val folder = resolveJsonDocumentFolder(locationKind, basePath)
            ?: return jsonWriteConflict("folder_unavailable")
        return JsonDocumentOperationLocks.withLock(jsonDocumentLockKey(folder, name)) {
            writeJsonDocumentLocked(folder, name, bytes, mode, expectedRevision)
        }
    }

    private fun writeJsonDocumentLocked(
        folder: DocumentFile,
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
        val recovery = recoverJsonDocument(folder, name).getOrElse {
            return jsonWriteConflict(it.toString())
        }
        if (recovery.failed) {
            return jsonWriteConflict("transaction_recovery_failed")
        }
        val existing = recovery.document
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

        val temporaryName = "$name.doujin.part"
        val temporary = runCatching {
            folder.createFile("application/octet-stream", temporaryName)
        }.getOrNull() ?: return jsonWriteConflict("staging_create_failed")
        if (temporary.uri == existing?.uri ||
            !paths.sameDocumentName(temporary.name, temporaryName)) {
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

        val current = runCatching {
            findJsonDocument(listReadableDirectoryDocuments(context, folder.uri), name)
        }.getOrElse {
            deleteTemporary()
            return jsonWriteConflict("document_query_failed")
        }
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

        val expectedCommittedRevision = sha256(bytes)
        if (commitSafDocumentReplacement(
            targetName = name,
            current = current,
            temporary = temporary,
            isValidCommitted = { document ->
                paths.sameDocumentName(document.name, name) &&
                    documentRevision(document) == expectedCommittedRevision
            },
            rename = { document, targetName ->
                paths.renameDocumentFile(document, targetName)
            },
            delete = { document -> document.delete() }
        ) == null) return jsonWriteConflict("commit_failed")
        return mapOf(
            "status" to if (mode == "createIfAbsent") "created" else "replaced",
            "revision" to expectedCommittedRevision,
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
        return JsonDocumentOperationLocks.withLock(jsonDocumentLockKey(folder, name)) {
            deleteJsonDocumentLocked(folder, name, expectedRevision)
        }
    }

    private fun deleteJsonDocumentLocked(
        folder: DocumentFile,
        name: String,
        expectedRevision: String
    ): Map<String, Any?> {
        val recovery = recoverJsonDocument(folder, name).getOrElse {
            return mapOf("status" to "conflict", "error" to it.toString())
        }
        if (recovery.failed) {
            return mapOf("status" to "conflict", "error" to "transaction_recovery_failed")
        }
        val target = recovery.document ?: return mapOf("status" to "missing")
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
        "folderChild" -> paths.resolveDocumentFileForFolderPath(basePath)
        "fileSibling" -> paths.resolveParentFolderForFile(basePath)
        else -> throw IllegalArgumentException("Unsupported JSON document location")
    }

    private fun jsonDocumentLockKey(
        folder: DocumentFile,
        name: String
    ): String = buildString {
        append(folder.uri.authority)
        append('\u0000')
        append(DocumentsContract.getDocumentId(folder.uri))
        append('\u0000')
        append(name.lowercase(Locale.US))
    }

    private fun findJsonDocument(documents: List<DirectoryDocument>, name: String): DocumentFile? =
        documents.firstOrNull {
            it.mime != DocumentsContract.Document.MIME_TYPE_DIR && paths.sameDocumentName(it.name, name)
        }?.let {
            DocumentFile.fromSingleUri(context, it.uri)
                ?: throw IOException("Document URI is unavailable: ${it.uri}")
        }

    private fun recoverJsonDocument(
        folder: DocumentFile,
        name: String,
        forRead: Boolean = false
    ): Result<SafDocumentRecovery<DocumentFile>> = runCatching {
        val documents = listReadableDirectoryDocuments(context, folder.uri)
        recoverSafDocument(
            targetName = name,
            existing = findJsonDocument(documents, name),
            staleBackup = findJsonDocument(documents, "$name.doujin.bak"),
            staleTemp = findJsonDocument(documents, "$name.doujin.part"),
            forRead = forRead,
            isValid = { document ->
                contentResolver.openInputStream(document.uri)?.use { input ->
                    isValidJson(input.readBytes())
                } ?: throw IOException("Document cannot be opened: ${document.uri}")
            },
            rename = { document, targetName ->
                paths.renameDocumentFile(document, targetName)
            },
            delete = { document -> document.delete() }
        )
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
}
