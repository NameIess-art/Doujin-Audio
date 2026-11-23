package com.doujin.audio.metadata

import com.doujin.audio.common.*
import com.doujin.audio.storage.*

import android.content.Context
import android.net.Uri
import android.os.SystemClock
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
    private val metadata: MediaMetadataOperations,
    private val clockMs: () -> Long = SystemClock::elapsedRealtime,
    private val resolveLocalFilePath: (String) -> String? = storage::contentUriToFilePath
) {
    private val imageExtensions = setOf("jpg", "jpeg", "png", "webp", "bmp", "gif")
    private val preferredNames = listOf("cover", "folder", "front", "album", "artwork", "poster")

    private data class ReadableLocalDirectory(
        val dir: File,
        val entries: Array<File>
    )

    private data class SafFolderCacheKey(
        val folderUri: String,
        val recursive: Boolean,
        val stopAtRootTopPriority: Boolean
    )

    private data class SafFolderCacheEntry(
        val candidates: List<DocumentCandidate>,
        val expiresAtMs: Long
    )

    private val safFolderCache = object : LinkedHashMap<SafFolderCacheKey, SafFolderCacheEntry>(32, 0.75f, true) {
        override fun removeEldestEntry(
            eldest: MutableMap.MutableEntry<SafFolderCacheKey, SafFolderCacheEntry>?
        ): Boolean = size > MAX_SAF_FOLDER_CACHE_ENTRIES
    }

    fun resolve(trackPath: String, groupKey: String?, rootFolder: String?): String? {
        if (!rootFolder.isNullOrBlank()) {
            if (rootFolder.startsWith("content://")) {
                val localRoot = readableLocalDirectory(resolveLocalFilePath(rootFolder))
                if (localRoot != null) {
                    val fileCover = preferredFile(localRoot.dir.absolutePath, localRoot.entries)
                    if (fileCover != null) return fileCover
                }
                val root = storage.resolveDocumentFileForFolderPath(rootFolder)
                val candidate = root?.let(::preferredDocument)
                if (candidate != null) return cacheCandidate(candidate)
            } else {
                val fileCover = preferredFile(rootFolder)
                if (fileCover != null) return fileCover
            }
        }
        if (trackPath.startsWith("content://") && !groupKey.isNullOrBlank()) {
            val localGroup = readableLocalDirectory(
                if (groupKey.startsWith("content://")) resolveLocalFilePath(groupKey) else groupKey
            )
            if (localGroup != null) {
                val fileCover = preferredFile(localGroup.dir.absolutePath, localGroup.entries)
                if (fileCover != null) return fileCover
            }
            val root = storage.resolveDocumentFileForFolderPath(groupKey)
            val candidate = root?.let(::preferredDocument)
            if (candidate != null) return cacheCandidate(candidate)
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
            val localRoot = readableLocalDirectory(resolveLocalFilePath(documentRoot))
            var localListSucceeded = false
            if (localRoot != null) {
                val localImages = try {
                    fileImages(
                        localRoot.dir.absolutePath,
                        recursive,
                        preferredOnly,
                        localRoot.entries
                    ).also { localListSucceeded = true }
                } catch (_: IOException) {
                    null
                }
                if (!localImages.isNullOrEmpty()) return localImages
            }
            val root = storage.resolveDocumentFileForFolderPath(documentRoot)
            if (root != null) {
                val candidates = documentImages(
                    root,
                    recursive,
                    strict = true,
                    stopAtRootTopPriority = preferredOnly
                )
                return (if (preferredOnly) candidates.take(1) else candidates).map { candidate ->
                    val cachedPath = cacheCandidate(candidate)
                        ?: throw IOException("Unable to cache image: ${candidate.uri}")
                    buildMap {
                        put("path", cachedPath)
                        put("sourcePath", candidate.uri.toString())
                        candidate.sizeBytes?.let { put("fileSizeBytes", it.toString()) }
                    }
                }
            }
            if (localListSucceeded) return emptyList()
            throw IOException("Image directory is unavailable: $documentRoot")
        }
        if (!rootFolder.isNullOrBlank()) return fileImages(rootFolder, recursive, preferredOnly)
        return emptyList()
    }

    private fun readableLocalDirectory(path: String?): ReadableLocalDirectory? {
        if (path.isNullOrBlank()) return null
        val dir = File(path)
        if (!dir.isDirectory || !dir.canRead()) return null
        val entries = dir.listFiles() ?: return null
        return ReadableLocalDirectory(dir, entries)
    }

    private fun cacheCandidate(candidate: DocumentCandidate): String? =
        cacheUri(
            candidate.uri,
            candidate.rawName,
            candidate.uri.toString(),
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
                        input.copyTo(target, bufferSize = SAF_COPY_BUFFER_BYTES)
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

    private fun preferredFile(folderPath: String, prelistedEntries: Array<File>? = null): String? {
        val root = File(folderPath)
        if (prelistedEntries == null && !root.isDirectory) return null
        val entries = prelistedEntries ?: root.listFiles() ?: return null
        val rootTopPriority = entries
            .asSequence()
            .filter { it.isFile && it.canRead() && isImage(it.name, null) && priority(it.name) < preferredNames.size }
            .minWithOrNull(compareBy<File>({ priority(it.name) }, { it.absolutePath.lowercase(Locale.US) }))
        if (rootTopPriority != null) return rootTopPriority.absolutePath
        val candidate = if (entries.none { it.isDirectory }) {
            entries.asSequence()
                .filter { it.isFile && it.canRead() && isImage(it.name, null) }
                .minWithOrNull(compareBy<File>({ priority(it.name) }, { it.absolutePath.lowercase(Locale.US) }))
        } else {
            root.walkTopDown()
                .filter { it.isFile && it.canRead() && isImage(it.name, null) }
                .minWithOrNull(compareBy<File>({ priority(it.name) }, { it.absolutePath.lowercase(Locale.US) }))
        } ?: return null
        return candidate.absolutePath
    }

    private fun fileImages(
        folderPath: String,
        recursive: Boolean,
        preferredOnly: Boolean,
        prelistedEntries: Array<File>? = null
    ): List<Map<String, String>> {
        val root = File(folderPath)
        if (prelistedEntries == null && (!root.isDirectory || !root.canRead())) {
            throw IOException("Image directory is unavailable: $folderPath")
        }
        val rootEntries = prelistedEntries
            ?: if (!recursive || preferredOnly) {
                root.listFiles() ?: throw IOException("Unable to list image directory: $folderPath")
            } else {
                null
            }
        val rootTopPriority = if (recursive && preferredOnly && rootEntries != null) {
            rootEntries.asSequence()
                .filter { it.isFile && it.canRead() && isImage(it.name, null) && priority(it.name) < preferredNames.size }
                .minWithOrNull(compareBy<File>({ priority(it.name) }, { it.absolutePath.lowercase(Locale.US) }))
        } else {
            null
        }
        val selected = if (rootTopPriority != null) {
            sequenceOf(rootTopPriority)
        } else {
            val files = if (recursive && (rootEntries == null || rootEntries.any { it.isDirectory })) {
                root.walkTopDown().onFail { _, error -> throw error }
            } else {
                (rootEntries ?: throw IOException("Unable to list image directory: $folderPath")).asSequence()
            }
            files
                .filter { it.isFile && it.canRead() && isImage(it.name, null) }
                .sortedWith(compareBy<File>({ priority(it.name) }, { it.absolutePath.lowercase(Locale.US) }))
                .let { if (preferredOnly) it.take(1) else it }
        }
        return selected
            .map { file ->
                val filePath = file.absolutePath
                mapOf(
                    "path" to filePath,
                    "sourcePath" to filePath,
                    "fileSizeBytes" to file.length().toString()
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
        val effectiveStopAtRoot = recursive && stopAtRootTopPriority
        val cacheKey = SafFolderCacheKey(
            folderUri = root.uri.toString(),
            recursive = recursive,
            stopAtRootTopPriority = effectiveStopAtRoot
        )
        val nowMs = clockMs()
        synchronized(safFolderCache) {
            val cached = safFolderCache[cacheKey]
            if (cached != null) {
                if (nowMs < cached.expiresAtMs) return cached.candidates
                safFolderCache.remove(cacheKey)
            }
        }
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
                        if (effectiveStopAtRoot && isRoot && priority(name) < preferredNames.size) {
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
        val sorted = found.sortedWith(compareBy<DocumentCandidate>({ priority(it.name) }, { it.path.lowercase(Locale.US) }))
        val expiresAtMs = clockMs() + SAF_FOLDER_CACHE_TTL_MS
        synchronized(safFolderCache) {
            safFolderCache[cacheKey] = SafFolderCacheEntry(sorted, expiresAtMs)
        }
        return sorted
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

    private companion object {
        const val SAF_COPY_BUFFER_BYTES = 64 * 1024
        const val MAX_SAF_FOLDER_CACHE_ENTRIES = 128
        const val SAF_FOLDER_CACHE_TTL_MS = 60_000L
    }
}
