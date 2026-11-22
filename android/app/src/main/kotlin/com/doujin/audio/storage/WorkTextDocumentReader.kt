package com.doujin.audio.storage

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.Locale

private val supportedWorkDocExtensions = setOf("txt", "md", "pdf", "vtt", "webvtt", "lrc", "srt", "ass", "ssa")

internal const val MAX_INLINE_DOCUMENT_BYTES = 32L * 1024L * 1024L

internal class DocumentTooLargeException(
    val maxBytes: Long,
    val actualBytes: Long? = null
) : IOException(
    if (actualBytes != null) {
        "Document size ($actualBytes bytes) exceeds the $maxBytes byte limit."
    } else {
        "Document exceeds the $maxBytes byte limit."
    }
)

internal class WorkTextDocumentReader(
    private val context: Context,
    private val paths: DocumentPathResolver
) {
    private val contentResolver get() = context.contentResolver

    private fun isSupportedWorkDocName(name: String): Boolean {
        val ext = name.substringAfterLast('.', "").lowercase(Locale.US)
        return ext in supportedWorkDocExtensions
    }

    fun discoverWorkTexts(folderPath: String): List<Map<String, String>> {
        val trimmed = folderPath.trim()
        if (trimmed.startsWith("content://")) {
            val root = paths.resolveDocumentFileForFolderPath(trimmed)
            if (root != null && root.exists() && root.isDirectory && root.canRead()) {
                val results = mutableListOf<Map<String, String>>()
                data class Node(val uri: Uri, val relPath: String)
                val pending = java.util.ArrayDeque<Node>()
                pending += Node(root.uri, "")
                while (pending.isNotEmpty()) {
                    val node = pending.removeFirst()
                    for (child in listReadableDirectoryDocuments(context, node.uri)) {
                        val name = paths.normalizeDisplayName(child.name)
                        val childRel = listOf(node.relPath, name).filter(String::isNotBlank).joinToString("/")
                        if (child.mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                            pending += Node(child.uri, childRel)
                        } else if (isSupportedWorkDocName(name)) {
                            results += buildMap {
                                put("name", name)
                                put("relativePath", childRel)
                                put("path", child.uri.toString())
                                child.sizeBytes?.let { put("fileSizeBytes", it.toString()) }
                            }
                        }
                    }
                }
                return results.sortedWith(compareBy { it["relativePath"]?.lowercase(Locale.US).orEmpty() })
            }
            val localPath = paths.contentUriToFilePath(trimmed)
            if (localPath != null) {
                return discoverLocalWorkTexts(localPath)
            }
            throw IOException("Document directory is unavailable: $trimmed")
        }
        return discoverLocalWorkTexts(trimmed)
    }

    fun readDocumentBytes(
        path: String,
        maxBytes: Long = MAX_INLINE_DOCUMENT_BYTES
    ): ByteArray? {
        val trimmed = path.trim()
        return try {
            if (trimmed.startsWith("content://")) {
                val uri = Uri.parse(trimmed)
                val declaredSize = DocumentFile.fromSingleUri(context, uri)?.length() ?: -1L
                if (declaredSize > maxBytes) {
                    throw DocumentTooLargeException(maxBytes, declaredSize)
                }
                contentResolver.openInputStream(uri)?.use { readBoundedDocumentBytes(it, maxBytes) }
            } else {
                readLocalDocumentBytes(File(trimmed), maxBytes)
            }
        } catch (error: DocumentTooLargeException) {
            throw error
        } catch (_: Exception) {
            null
        }
    }
}

internal fun readLocalDocumentBytes(
    file: File,
    maxBytes: Long = MAX_INLINE_DOCUMENT_BYTES
): ByteArray? {
    if (!file.exists() || !file.isFile) return null
    val declaredSize = file.length()
    if (declaredSize > maxBytes) {
        throw DocumentTooLargeException(maxBytes, declaredSize)
    }
    return file.inputStream().use { readBoundedDocumentBytes(it, maxBytes) }
}

internal fun readBoundedDocumentBytes(
    input: InputStream,
    maxBytes: Long = MAX_INLINE_DOCUMENT_BYTES
): ByteArray {
    require(maxBytes >= 0L) { "maxBytes must be non-negative." }
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(16 * 1024)
    var total = 0L
    while (true) {
        val read = input.read(buffer)
        if (read < 0) break
        total += read
        if (total > maxBytes) {
            throw DocumentTooLargeException(maxBytes)
        }
        output.write(buffer, 0, read)
    }
    return output.toByteArray()
}

internal fun discoverLocalWorkTexts(folderPath: String): List<Map<String, String>> {
    val root = File(folderPath)
    if (!root.isDirectory || !root.canRead()) {
        throw IOException("Document directory is unavailable: $folderPath")
    }
    return root.walkTopDown()
        .onFail { _, error -> throw error }
        .filter { it.isFile && it.extension.lowercase(Locale.US) in supportedWorkDocExtensions }
        .sortedWith(compareBy { it.absolutePath.lowercase(Locale.US) })
        .map { file ->
            mapOf(
                "name" to file.name,
                "relativePath" to file.relativeTo(root).invariantSeparatorsPath,
                "path" to file.absolutePath,
                "fileSizeBytes" to file.length().toString()
            )
        }.toList()
}
