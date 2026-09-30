package com.doujin.audio.storage

import android.content.Context
import java.io.File
import java.util.Locale
import android.net.Uri
import androidx.documentfile.provider.DocumentFile

internal class WorkTextDocumentReader(
    private val context: Context,
    private val paths: DocumentPathResolver
) {
    private val contentResolver get() = context.contentResolver
    private val supportedWorkDocExtensions = setOf("txt", "md", "pdf")

    private fun isSupportedWorkDocName(name: String): Boolean {
        val ext = name.substringAfterLast('.', "").lowercase(Locale.US)
        return ext in supportedWorkDocExtensions
    }

    fun discoverWorkTexts(folderPath: String): List<Map<String, String>> {
        val trimmed = folderPath.trim()
        if (trimmed.startsWith("content://")) {
            val root = paths.resolveDocumentFileForFolderPath(trimmed)
            if (root != null && root.exists()) {
                val results = mutableListOf<Map<String, String>>()
                data class Node(val folder: DocumentFile, val relPath: String)
                val pending = java.util.ArrayDeque<Node>()
                pending += Node(root, "")
                while (pending.isNotEmpty()) {
                    val node = pending.removeFirst()
                    node.folder.listFiles().forEach { child ->
                        val name = paths.normalizeDisplayName(child.name.orEmpty())
                        val childRel = listOf(node.relPath, name).filter(String::isNotBlank).joinToString("/")
                        when {
                            child.isDirectory -> pending += Node(child, childRel)
                            child.isFile && isSupportedWorkDocName(name) -> {
                                results += mapOf(
                                    "name" to name,
                                    "relativePath" to childRel,
                                    "path" to child.uri.toString()
                                )
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
            return emptyList()
        }
        return discoverLocalWorkTexts(trimmed)
    }

    private fun discoverLocalWorkTexts(folderPath: String): List<Map<String, String>> {
        val root = File(folderPath)
        if (!root.exists() || !root.isDirectory) return emptyList()
        return root.walkTopDown()
            .filter { it.isFile && it.extension.lowercase(Locale.US) in supportedWorkDocExtensions }
            .sortedWith(compareBy { it.absolutePath.lowercase(Locale.US) })
            .map { file ->
                val rel = file.relativeToOrNull(root)?.invariantSeparatorsPath ?: file.name
                mapOf(
                    "name" to file.name,
                    "relativePath" to rel,
                    "path" to file.absolutePath
                )
            }.toList()
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
