package com.doujin.audio.storage

import android.content.Context
import java.io.File
import java.util.Locale
import android.net.Uri
import android.provider.DocumentsContract
import java.io.IOException

private val supportedWorkDocExtensions = setOf("txt", "md", "pdf")

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

    fun readDocumentBytes(path: String): ByteArray? {
        val trimmed = path.trim()
        return try {
            if (trimmed.startsWith("content://")) {
                contentResolver.openInputStream(Uri.parse(trimmed))?.use { it.readBytes() }
            } else {
                val file = File(trimmed)
                if (file.exists() && file.isFile) file.readBytes() else null
            }
        } catch (_: Exception) {
            null
        }
    }
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
