package com.nameless.audio.scanner

import com.nameless.audio.metadata.*
import com.nameless.audio.storage.*

import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.util.ArrayDeque

internal class FolderScanOperations(
    private val context: Context,
    private val storage: DocumentStorageOperations = DocumentStorageOperations(context)
) {
    private val resolver get() = context.contentResolver
    private val orchestrator = FileCacheMediaScanOrchestrator(
        resolveContentUri = storage::resolveContentUri,
        contentUriToFilePath = storage::contentUriToFilePath,
        scanDocumentTree = ::scanDocumentTree,
        scanFileSystemAsDocumentTree = ::scanFileSystemAsDocumentTree,
        scanFileSystem = ::scanFileSystem,
        scanMediaStore = ::scanMediaStore
    )

    fun scanFolder(
        folder: String,
        observer: FolderScanObserver = NoopFolderScanObserver
    ): ScanFolderResult = orchestrator.scanFolder(folder, observer)

    private fun scanDocumentTree(
        rootUri: Uri,
        tracks: MutableMap<String, ScannedTrack>,
        observer: FolderScanObserver
    ): Int {
        val root = DocumentFile.fromTreeUri(context, rootUri)
            ?: DocumentFile.fromSingleUri(context, rootUri)
            ?: return 1
        if (!root.exists() || !root.isDirectory) return 1
        val rootName = normalized(root.name).ifBlank { "Folder" }
        val pending = ArrayDeque<DocumentNode>()
        pending.add(DocumentNode(root, "", rootName))
        var failures = 0
        while (pending.isNotEmpty() && !observer.isCancelled()) {
            val current = pending.removeFirst()
            val children = try {
                current.directory.listFiles()
            } catch (_: Exception) {
                failures++
                emptyArray()
            }
            for (child in children) {
                if (observer.isCancelled()) break
                observer.onEntryProcessed()
                val name = normalized(child.name).ifBlank { "media_file" }
                if (child.isDirectory) {
                    val relative = joinRelative(current.relative, name)
                    pending.add(DocumentNode(child, relative, name))
                    continue
                }
                if (!child.isFile) continue
                val media = MediaNameMetadata.mediaNameInfoOrNull(name, child.type) ?: continue
                val groupKey = if (current.relative.isBlank()) {
                    rootUri.toString()
                } else {
                    "${rootUri}::${current.relative}"
                }
                remember(
                    tracks,
                    ScannedTrack(
                        path = child.uri.toString(),
                        title = media.title,
                        groupKey = groupKey,
                        groupTitle = current.title,
                        groupSubtitle = if (current.relative.isBlank()) rootName else "$rootName/${current.relative}",
                        isVideo = media.isVideo,
                        fileSizeBytes = child.length().takeIf { it > 0L },
                        modifiedAtMs = child.lastModified().takeIf { it > 0L }
                    ),
                    observer
                )
            }
        }
        return failures
    }

    private fun scanFileSystem(
        root: File,
        tracks: MutableMap<String, ScannedTrack>,
        observer: FolderScanObserver
    ): Int = scanFiles(root, null, tracks, observer)

    private fun scanFileSystemAsDocumentTree(
        rootUri: Uri,
        root: File,
        tracks: MutableMap<String, ScannedTrack>,
        observer: FolderScanObserver
    ): Int = scanFiles(root, rootUri, tracks, observer)

    private fun scanFiles(
        root: File,
        documentRoot: Uri?,
        tracks: MutableMap<String, ScannedTrack>,
        observer: FolderScanObserver
    ): Int {
        if (!root.exists() || !root.isDirectory) return 1
        val rootName = normalized(root.name).ifBlank { "Folder" }
        val pending = ArrayDeque<File>()
        pending.add(root)
        var failures = 0
        while (pending.isNotEmpty() && !observer.isCancelled()) {
            val directory = pending.removeFirst()
            val children = try {
                directory.listFiles()
            } catch (_: Exception) {
                failures++
                null
            } ?: run {
                failures++
                emptyArray()
            }
            val relative = directory.relativeToOrNull(root)?.path
                ?.replace(File.separatorChar, '/')
                .orEmpty()
            for (child in children) {
                if (observer.isCancelled()) break
                observer.onEntryProcessed()
                if (child.isDirectory) {
                    pending.add(child)
                    continue
                }
                if (!child.isFile) continue
                val media = MediaNameMetadata.mediaNameInfoOrNull(child.name) ?: continue
                val groupKey = if (documentRoot == null) {
                    directory.absolutePath
                } else if (relative.isBlank()) {
                    documentRoot.toString()
                } else {
                    "${documentRoot}::$relative"
                }
                remember(
                    tracks,
                    ScannedTrack(
                        path = child.absolutePath,
                        title = media.title,
                        groupKey = groupKey,
                        groupTitle = normalized(directory.name).ifBlank { rootName },
                        groupSubtitle = if (relative.isBlank()) rootName else "$rootName/$relative",
                        isVideo = media.isVideo,
                        fileSizeBytes = child.length().takeIf { it > 0L },
                        modifiedAtMs = child.lastModified().takeIf { it > 0L }
                    ),
                    observer
                )
            }
        }
        return failures
    }

    private fun scanMediaStore(
        folder: String,
        tracks: MutableMap<String, ScannedTrack>,
        observer: FolderScanObserver
    ): Int {
        if (observer.isCancelled()) return 0
        val collection = MediaStore.Files.getContentUri("external")
        val projection = mutableListOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.MIME_TYPE,
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.Files.FileColumns.DATE_MODIFIED
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            projection.add(MediaStore.Files.FileColumns.RELATIVE_PATH)
        } else {
            @Suppress("DEPRECATION")
            projection.add(MediaStore.Files.FileColumns.DATA)
        }
        val normalizedFolder = folder.trim().replace('\\', '/').trimEnd('/')
        return try {
            resolver.query(collection, projection.toTypedArray(), null, null, null)?.use { cursor ->
                val idIndex = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
                val nameIndex = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DISPLAY_NAME)
                val mimeIndex = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MIME_TYPE)
                val sizeIndex = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
                val modifiedIndex = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_MODIFIED)
                val pathColumn = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    MediaStore.Files.FileColumns.RELATIVE_PATH
                } else {
                    MediaStore.Files.FileColumns.DATA
                }
                val pathIndex = cursor.getColumnIndexOrThrow(pathColumn)
                while (cursor.moveToNext() && !observer.isCancelled()) {
                    observer.onEntryProcessed()
                    val name = normalized(cursor.getString(nameIndex))
                    val mime = cursor.getString(mimeIndex)
                    val media = MediaNameMetadata.mediaNameInfoOrNull(name, mime) ?: continue
                    val storedPath = cursor.getString(pathIndex).orEmpty().replace('\\', '/')
                    val directory = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        storedPath.trimEnd('/')
                    } else {
                        File(storedPath).parent.orEmpty().replace('\\', '/')
                    }
                    if (normalizedFolder.isNotBlank() &&
                        !directory.equals(normalizedFolder, ignoreCase = true) &&
                        !directory.startsWith("$normalizedFolder/", ignoreCase = true)
                    ) continue
                    val path = ContentUris.withAppendedId(collection, cursor.getLong(idIndex)).toString()
                    val groupTitle = directory.substringAfterLast('/').ifBlank { "Media" }
                    remember(
                        tracks,
                        ScannedTrack(
                            path = path,
                            title = media.title,
                            groupKey = directory.ifBlank { normalizedFolder },
                            groupTitle = groupTitle,
                            groupSubtitle = directory.ifBlank { groupTitle },
                            isVideo = media.isVideo,
                            fileSizeBytes = cursor.getLong(sizeIndex).takeIf { it > 0L },
                            modifiedAtMs = cursor.getLong(modifiedIndex).takeIf { it > 0L }?.times(1000L)
                        ),
                        observer
                    )
                }
            }
            0
        } catch (_: Exception) {
            1
        }
    }

    private fun remember(
        tracks: MutableMap<String, ScannedTrack>,
        track: ScannedTrack,
        observer: FolderScanObserver
    ) {
        if (tracks.putIfAbsent(track.path, track) == null) observer.onTrack(track)
    }

    private fun normalized(value: String?): String =
        MediaNameMetadata.normalizeDisplayName(value.orEmpty())

    private fun joinRelative(parent: String, child: String): String = when {
        parent.isBlank() -> child
        child.isBlank() -> parent
        else -> "$parent/$child"
    }

    private data class DocumentNode(
        val directory: DocumentFile,
        val relative: String,
        val title: String
    )
}
