package com.nameless.audio.metadata

import com.nameless.audio.common.*
import com.nameless.audio.storage.*

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.io.FileOutputStream
import java.util.ArrayDeque
import java.util.Locale

internal class CoverArtworkOperations(
    private val context: Context,
    private val storage: DocumentStorageOperations,
    private val metadata: MediaMetadataOperations,
    private val cachePolicy: ApplicationCachePolicy
) {
    private val imageExtensions = setOf("jpg", "jpeg", "png", "webp", "bmp", "gif")
    private val preferredNames = listOf("cover", "folder", "front", "album", "artwork", "poster")

    fun resolve(trackPath: String, groupKey: String?, rootFolder: String?): String? {
        if (!rootFolder.isNullOrBlank()) {
            if (rootFolder.startsWith("content://")) {
                val root = storage.resolveDocumentFileForFolderPath(rootFolder)
                val candidate = root?.takeIf { it.exists() }?.let(::preferredDocument)
                if (candidate != null) return cacheDocument(candidate.file, "$rootFolder|${candidate.path}")
                val localRoot = storage.contentUriToFilePath(rootFolder)
                if (localRoot != null) return preferredFile(localRoot, trackPath)
            } else {
                val fileCover = preferredFile(rootFolder, trackPath)
                if (fileCover != null) return fileCover
            }
        }
        if (trackPath.startsWith("content://") && !groupKey.isNullOrBlank()) {
            val root = storage.resolveDocumentFileForFolderPath(groupKey.substringBefore("::"))
            val candidate = root?.let(::preferredDocument)
            if (candidate != null) return cacheDocument(candidate.file, "$trackPath|${candidate.path}")
        }
        return metadata.resolveEmbeddedCover(trackPath)
    }

    fun discover(
        trackPath: String,
        groupKey: String?,
        rootFolder: String?,
        recursive: Boolean
    ): List<Map<String, String>> {
        val documentRoot = when {
            !rootFolder.isNullOrBlank() && rootFolder.startsWith("content://") -> rootFolder
            !groupKey.isNullOrBlank() && groupKey.startsWith("content://") -> groupKey.substringBefore("::")
            else -> null
        }
        if (documentRoot != null) {
            val root = storage.resolveDocumentFileForFolderPath(documentRoot)
            val candidates = root?.let { documentImages(it, recursive) }.orEmpty()
            if (candidates.isNotEmpty()) {
                return candidates.mapNotNull { candidate ->
                    val cachedPath = cacheDocument(
                        candidate.file,
                        "$trackPath|${candidate.path}"
                    ) ?: return@mapNotNull null
                    mapOf(
                        "path" to cachedPath,
                        "sourcePath" to candidate.file.uri.toString()
                    )
                }
            }
            val localRoot = storage.contentUriToFilePath(documentRoot)
            if (localRoot != null) return fileImages(localRoot, trackPath, recursive)
            return emptyList()
        }
        if (!rootFolder.isNullOrBlank()) return fileImages(rootFolder, trackPath, recursive)
        return emptyList()
    }

    internal fun cacheDocument(file: DocumentFile, cacheKey: String): String? =
        cacheUri(file.uri, file.name.orEmpty(), cacheKey)

    internal fun cacheUri(uri: Uri, name: String, cacheKey: String): String? {
        val extension = name.substringAfterLast('.', "").ifBlank { "img" }
        val output = File(coverDirectory(), "cover_${kotlin.math.abs(cacheKey.hashCode())}.$extension")
        if (output.exists() && output.length() > 0L) {
            cachePolicy.touch(output)
            return output.absolutePath
        }
        return try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(output).use { target -> input.copyTo(target) }
            } ?: return null
            cachePolicy.touch(output)
            output.absolutePath
        } catch (_: Exception) {
            output.delete()
            null
        }
    }

    private fun preferredFile(folderPath: String, cacheKey: String): String? {
        val root = File(folderPath)
        if (!root.isDirectory) return null
        val candidate = root.walkTopDown()
            .filter { it.isFile && isImage(it.name, null) }
            .minWithOrNull(compareBy<File>({ priority(it.name) }, { it.absolutePath.lowercase(Locale.US) }))
            ?: return null
        val output = File(coverDirectory(), "cover_${kotlin.math.abs(cacheKey.hashCode())}.jpg")
        if (output.exists() && output.length() > 0L) {
            cachePolicy.touch(output)
            return output.absolutePath
        }
        return try {
            candidate.copyTo(output, overwrite = true)
            cachePolicy.touch(output)
            output.absolutePath
        } catch (_: Exception) {
            output.delete()
            null
        }
    }

    private fun fileImages(
        folderPath: String,
        cacheKey: String,
        recursive: Boolean
    ): List<Map<String, String>> {
        val root = File(folderPath)
        if (!root.isDirectory) return emptyList()
        val files = if (recursive) root.walkTopDown() else root.listFiles().orEmpty().asSequence()
        return files
            .filter { it.isFile && isImage(it.name, null) }
            .sortedWith(compareBy<File>({ priority(it.name) }, { it.absolutePath.lowercase(Locale.US) }))
            .mapNotNull { file ->
                val relative = file.relativeToOrNull(root)?.invariantSeparatorsPath ?: file.name
                val output = File(coverDirectory(), "cover_${kotlin.math.abs("$cacheKey|$relative".hashCode())}.jpg")
                try {
                    if (!output.exists() || output.length() <= 0L) file.copyTo(output, overwrite = true)
                    cachePolicy.touch(output)
                    mapOf(
                        "path" to output.absolutePath,
                        "sourcePath" to file.absolutePath
                    )
                } catch (_: Exception) {
                    output.delete()
                    null
                }
            }.toList()
    }

    private fun preferredDocument(root: DocumentFile): DocumentCandidate? = documentImages(root, true).firstOrNull()

    private fun documentImages(root: DocumentFile, recursive: Boolean): List<DocumentCandidate> {
        data class Node(val folder: DocumentFile, val path: String)
        val found = mutableListOf<DocumentCandidate>()
        try {
            val pending = ArrayDeque<Node>()
            pending += Node(root, "")
            while (pending.isNotEmpty()) {
                val node = pending.removeFirst()
                node.folder.listFiles().forEach { child ->
                    val name = MediaNameMetadata.normalizeDisplayName(child.name.orEmpty())
                    val childPath = listOf(node.path, name).filter(String::isNotBlank).joinToString("/")
                    when {
                        recursive && child.isDirectory -> pending += Node(child, childPath)
                        child.isFile && isImage(name, child.type) -> found += DocumentCandidate(child, childPath)
                    }
                }
            }
        } catch (_: Exception) {
            return emptyList()
        }
        return found.sortedWith(compareBy<DocumentCandidate>({ priority(it.file.name.orEmpty()) }, { it.path.lowercase(Locale.US) }))
    }

    private fun isImage(name: String, mime: String?): Boolean =
        mime?.lowercase(Locale.US)?.startsWith("image/") == true ||
            name.substringAfterLast('.', "").lowercase(Locale.US) in imageExtensions

    private fun priority(rawName: String): Int {
        val name = MediaNameMetadata.normalizeDisplayName(rawName)
            .substringBeforeLast('.', MediaNameMetadata.normalizeDisplayName(rawName))
            .lowercase(Locale.US)
        val exact = preferredNames.indexOf(name)
        if (exact >= 0) return exact
        preferredNames.forEachIndexed { index, preferred ->
            if (name.contains(preferred)) return 100 + index
        }
        return 200
    }

    private fun coverDirectory(): File = File(context.cacheDir, "nameless_audio_covers").also {
        if (!it.exists()) it.mkdirs()
    }

    private data class DocumentCandidate(val file: DocumentFile, val path: String)
}
