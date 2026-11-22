package com.doujin.audio.metadata

import com.doujin.audio.common.*
import com.doujin.audio.storage.*

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.ArrayDeque
import java.util.Locale

internal fun coverBridgeCacheKey(
    sourceKey: String,
    modifiedAtMs: Long?,
    sizeBytes: Long?
): String = "$sourceKey|${modifiedAtMs ?: 0L}|${sizeBytes ?: 0L}|v2"

internal class CoverArtworkOperations(
    private val context: Context,
    private val storage: DocumentStorageOperations,
    private val metadata: MediaMetadataOperations
) {
    private val imageExtensions = setOf("jpg", "jpeg", "png", "webp", "bmp", "gif")
    private val preferredNames = listOf("cover", "folder", "front", "album", "artwork", "poster")

    fun resolve(trackPath: String, groupKey: String?, rootFolder: String?): String? {
        if (!rootFolder.isNullOrBlank()) {
            if (rootFolder.startsWith("content://")) {
                val root = storage.resolveDocumentFileForFolderPath(rootFolder)
                val candidate = root?.takeIf { it.exists() }?.let(::preferredDocument)
                if (candidate != null) return cacheCandidate(candidate, "$rootFolder|${candidate.path}")
                val localRoot = storage.contentUriToFilePath(rootFolder)
                if (localRoot != null) return preferredFile(localRoot, trackPath)
            } else {
                val fileCover = preferredFile(rootFolder, trackPath)
                if (fileCover != null) return fileCover
            }
        }
        if (trackPath.startsWith("content://") && !groupKey.isNullOrBlank()) {
            val root = storage.resolveDocumentFileForFolderPath(groupKey)
            val candidate = root?.let(::preferredDocument)
            if (candidate != null) return cacheCandidate(candidate, "$trackPath|${candidate.path}")
        }
        return metadata.resolveEmbeddedCover(trackPath)
    }

    fun discover(
        trackPath: String,
        groupKey: String?,
        rootFolder: String?,
        recursive: Boolean,
        preferredOnly: Boolean = false
    ): List<Map<String, String>> {
        val documentRoot = when {
            !rootFolder.isNullOrBlank() && rootFolder.startsWith("content://") -> rootFolder
            !groupKey.isNullOrBlank() && groupKey.startsWith("content://") -> groupKey
            else -> null
        }
        if (documentRoot != null) {
            val root = storage.resolveDocumentFileForFolderPath(documentRoot)
            if (root != null && root.exists() && root.isDirectory && root.canRead()) {
                val candidates = documentImages(
                    root,
                    recursive,
                    strict = true,
                    stopAtRootTopPriority = preferredOnly
                )
                return (if (preferredOnly) candidates.take(1) else candidates).map { candidate ->
                    val cachedPath = cacheCandidate(
                        candidate,
                        "$trackPath|${candidate.path}"
                    ) ?: throw IOException("Unable to cache image: ${candidate.uri}")
                    buildMap {
                        put("path", cachedPath)
                        put("sourcePath", candidate.uri.toString())
                        candidate.sizeBytes?.let { put("fileSizeBytes", it.toString()) }
                    }
                }
            }
            val localRoot = storage.contentUriToFilePath(documentRoot)
            if (localRoot != null) return fileImages(localRoot, trackPath, recursive, preferredOnly)
            throw IOException("Image directory is unavailable: $documentRoot")
        }
        if (!rootFolder.isNullOrBlank()) return fileImages(rootFolder, trackPath, recursive, preferredOnly)
        return emptyList()
    }

    private fun cacheCandidate(candidate: DocumentCandidate, cacheKey: String): String? =
        cacheUri(
            candidate.uri,
            candidate.rawName,
            cacheKey,
            candidate.modifiedAtMs,
            candidate.sizeBytes
        )

    internal fun cacheUri(
        uri: Uri,
        name: String,
        cacheKey: String,
        modifiedAtMs: Long? = null,
        sizeBytes: Long? = null
    ): String? {
        val extension = sanitizeCacheExtension(name, "img")
        val document = if (modifiedAtMs == null || sizeBytes == null) {
            runCatching { DocumentFile.fromSingleUri(context, uri) }.getOrNull()
        } else {
            null
        }
        val versionedKey = coverBridgeCacheKey(
            cacheKey,
            modifiedAtMs ?: runCatching { document?.lastModified() }.getOrNull(),
            sizeBytes ?: runCatching { document?.length() }.getOrNull()
        )
        val output = File(coverDirectory(), artworkCacheFileName(versionedKey.toByteArray(Charsets.UTF_8), "cover", extension))
        if (output.exists() && output.length() > 0L) {
            touchCacheFile(output)
            return output.absolutePath
        }
        return try {
            val written = writeFileAtomically(output) { temp ->
                context.contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(temp).use { target ->
                        input.copyTo(target)
                        target.flush()
                    }
                    true
                } ?: false
            }
            if (!written) return null
            touchCacheFile(output)
            output.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun preferredFile(folderPath: String, cacheKey: String): String? {
        val root = File(folderPath)
        if (!root.isDirectory) return null
        val rootTopPriority = root.listFiles()
            ?.asSequence()
            ?.filter { it.isFile && isImage(it.name, null) && priority(it.name) == 0 }
            ?.minWithOrNull(compareBy<File> { it.absolutePath.lowercase(Locale.US) })
        val candidate = rootTopPriority ?: root.walkTopDown()
            .filter { it.isFile && isImage(it.name, null) }
            .minWithOrNull(compareBy<File>({ priority(it.name) }, { it.absolutePath.lowercase(Locale.US) }))
            ?: return null
        val versionedKey = coverBridgeCacheKey(
            "$cacheKey|${candidate.absolutePath}",
            candidate.lastModified(),
            candidate.length()
        )
        val output = File(coverDirectory(), artworkCacheFileName(versionedKey.toByteArray(Charsets.UTF_8), "cover", "jpg"))
        if (output.exists() && output.length() > 0L) {
            touchCacheFile(output)
            return output.absolutePath
        }
        return try {
            val written = writeFileAtomically(output) { temp ->
                candidate.copyTo(temp, overwrite = true)
                true
            }
            if (!written) return null
            touchCacheFile(output)
            output.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun fileImages(
        folderPath: String,
        cacheKey: String,
        recursive: Boolean,
        preferredOnly: Boolean
    ): List<Map<String, String>> {
        val root = File(folderPath)
        if (!root.isDirectory || !root.canRead()) throw IOException("Image directory is unavailable: $folderPath")
        val rootTopPriority = if (recursive && preferredOnly) {
            val rootEntries = root.listFiles()
                ?: throw IOException("Unable to list image directory: $folderPath")
            rootEntries.asSequence()
                .filter { it.isFile && isImage(it.name, null) && priority(it.name) == 0 }
                .minWithOrNull(compareBy<File> { it.absolutePath.lowercase(Locale.US) })
        } else {
            null
        }
        val selected = if (rootTopPriority != null) {
            sequenceOf(rootTopPriority)
        } else {
            val files = if (recursive) root.walkTopDown().onFail { _, error -> throw error }
            else (root.listFiles() ?: throw IOException("Unable to list image directory: $folderPath")).asSequence()
            files
                .filter { it.isFile && isImage(it.name, null) }
                .sortedWith(compareBy<File>({ priority(it.name) }, { it.absolutePath.lowercase(Locale.US) }))
                .let { if (preferredOnly) it.take(1) else it }
        }
        return selected
            .map { file ->
                val relative = file.relativeToOrNull(root)?.invariantSeparatorsPath ?: file.name
                val fileSizeBytes = file.length()
                val versionedKey = coverBridgeCacheKey(
                    "$cacheKey|$relative",
                    file.lastModified(),
                    fileSizeBytes
                )
                val output = File(coverDirectory(), artworkCacheFileName(versionedKey.toByteArray(Charsets.UTF_8), "cover", "jpg"))
                if (!output.exists() || output.length() <= 0L) {
                    val written = writeFileAtomically(output) { temp ->
                        file.copyTo(temp, overwrite = true)
                        true
                    }
                    if (!written) throw IOException("Unable to cache image: ${file.absolutePath}")
                }
                touchCacheFile(output)
                mapOf(
                    "path" to output.absolutePath,
                    "sourcePath" to file.absolutePath,
                    "fileSizeBytes" to fileSizeBytes.toString()
                )
            }.toList()
    }

    private fun preferredDocument(root: DocumentFile): DocumentCandidate? =
        documentImages(root, recursive = true, stopAtRootTopPriority = true).firstOrNull()

    private fun documentImages(
        root: DocumentFile,
        recursive: Boolean,
        strict: Boolean = false,
        stopAtRootTopPriority: Boolean = false
    ): List<DocumentCandidate> {
        data class Node(val folderUri: Uri, val path: String)
        val found = mutableListOf<DocumentCandidate>()
        try {
            val pending = ArrayDeque<Node>()
            pending += Node(root.uri, "")
            while (pending.isNotEmpty()) {
                val node = pending.removeFirst()
                val isRoot = node.path.isEmpty()
                var foundRootTopPriority = false
                for (entry in listReadableDirectoryDocuments(context, node.folderUri)) {
                    val name = MediaNameMetadata.normalizeDisplayName(entry.name)
                    val childPath = listOf(node.path, name).filter(String::isNotBlank).joinToString("/")
                    if (recursive && entry.mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        pending += Node(entry.uri, childPath)
                    } else if (isImage(name, entry.mime)) {
                        if (stopAtRootTopPriority && isRoot && priority(name) == 0) {
                            foundRootTopPriority = true
                        }
                        found += DocumentCandidate(
                            uri = entry.uri,
                            rawName = entry.name,
                            path = childPath,
                            name = name,
                            sizeBytes = entry.sizeBytes,
                            modifiedAtMs = entry.modifiedAtMs
                        )
                    }
                }
                if (foundRootTopPriority) break
            }
        } catch (error: Exception) {
            if (strict) throw error
            return emptyList()
        }
        return found.sortedWith(compareBy<DocumentCandidate>({ priority(it.name) }, { it.path.lowercase(Locale.US) }))
    }

    private fun writeFileAtomically(target: File, write: (File) -> Boolean): Boolean {
        val dir = target.parentFile ?: return false
        val temp = File.createTempFile("cover_", ".tmp", dir)
        var moved = false
        try {
            if (!write(temp) || temp.length() <= 0L) return false
            if (temp.renameTo(target)) {
                moved = true
                return true
            }
            if (target.exists() && target.length() > 0L) {
                return true
            }
            target.delete()
            if (temp.renameTo(target)) {
                moved = true
                return true
            }
            return false
        } finally {
            if (!moved) {
                temp.delete()
            }
        }
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

    private fun coverDirectory(): File = File(context.cacheDir, "doujin_audio_covers").also {
        if (!it.exists()) it.mkdirs()
    }

    private data class DocumentCandidate(
        val uri: Uri,
        val rawName: String,
        val path: String,
        val name: String,
        val sizeBytes: Long? = null,
        val modifiedAtMs: Long? = null
    )
}
