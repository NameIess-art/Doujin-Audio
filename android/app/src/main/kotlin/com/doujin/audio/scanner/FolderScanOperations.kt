package com.doujin.audio.scanner

import com.doujin.audio.metadata.*
import com.doujin.audio.storage.*

import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.util.ArrayDeque

internal data class MediaStoreFolderQuery(
    val selection: String?,
    val selectionArgs: List<String>,
    val directoryFilter: String
)

internal fun mediaStoreFolderQuery(
    sdkInt: Int,
    folder: String,
    primaryExternalStorageRoot: String
): MediaStoreFolderQuery {
    val normalizedFolder = normalizeMediaStorePath(folder)
    if (sdkInt >= Build.VERSION_CODES.Q) {
        val normalizedRoot = normalizeMediaStorePath(primaryExternalStorageRoot)
        val relativeFolder = when {
            normalizedFolder.equals(normalizedRoot, ignoreCase = true) -> ""
            normalizedRoot.isNotEmpty() && normalizedFolder.startsWith(
                "$normalizedRoot/",
                ignoreCase = true
            ) -> normalizedFolder.substring(normalizedRoot.length + 1)
            else -> normalizedFolder.trimStart('/')
        }.trim('/')
        if (relativeFolder.isEmpty()) {
            return MediaStoreFolderQuery(
                selection = null,
                selectionArgs = emptyList(),
                directoryFilter = ""
            )
        }
        val exactPath = "$relativeFolder/"
        val descendantPath = "${escapeSqlLikeArgument(relativeFolder)}/%"
        return MediaStoreFolderQuery(
            selection = "${MediaStore.Files.FileColumns.RELATIVE_PATH} = ? OR " +
                "${MediaStore.Files.FileColumns.RELATIVE_PATH} LIKE ? ESCAPE '\\'",
            selectionArgs = listOf(exactPath, descendantPath),
            directoryFilter = relativeFolder
        )
    }

    if (normalizedFolder.isEmpty()) {
        return MediaStoreFolderQuery(
            selection = null,
            selectionArgs = emptyList(),
            directoryFilter = ""
        )
    }
    @Suppress("DEPRECATION")
    return MediaStoreFolderQuery(
        selection = "${MediaStore.Files.FileColumns.DATA} LIKE ? ESCAPE '\\'",
        selectionArgs = listOf("${escapeSqlLikeArgument(normalizedFolder)}/%"),
        directoryFilter = normalizedFolder
    )
}

internal fun mediaStoreDirectoryMatches(directory: String, folder: String): Boolean {
    if (folder.isBlank()) return true
    val normalizedDirectory = normalizeMediaStorePath(directory)
    val normalizedFolder = normalizeMediaStorePath(folder)
    return normalizedDirectory.equals(normalizedFolder, ignoreCase = true) ||
        normalizedDirectory.startsWith("$normalizedFolder/", ignoreCase = true)
}

private fun normalizeMediaStorePath(value: String): String =
    value.trim().replace('\\', '/').trimEnd('/')

private fun escapeSqlLikeArgument(value: String): String = value
    .replace("\\", "\\\\")
    .replace("%", "\\%")
    .replace("_", "\\_")

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
        observer: FolderScanObserver = NoopFolderScanObserver,
        collectTracks: Boolean = true
    ): ScanFolderResult = orchestrator.scanFolder(folder, observer, collectTracks)

    private fun scanDocumentTree(
        rootUri: Uri,
        tracks: ScanTrackAccumulator,
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
        tracks: ScanTrackAccumulator,
        observer: FolderScanObserver
    ): Int = scanFiles(root, null, tracks, observer)

    private fun scanFileSystemAsDocumentTree(
        rootUri: Uri,
        root: File,
        tracks: ScanTrackAccumulator,
        observer: FolderScanObserver
    ): Int = scanFiles(root, rootUri, tracks, observer)

    private fun scanFiles(
        root: File,
        documentRoot: Uri?,
        tracks: ScanTrackAccumulator,
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
        tracks: ScanTrackAccumulator,
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
        val folderQuery = mediaStoreFolderQuery(
            sdkInt = Build.VERSION.SDK_INT,
            folder = folder,
            primaryExternalStorageRoot = Environment.getExternalStorageDirectory().absolutePath
        )
        return try {
            resolver.query(
                collection,
                projection.toTypedArray(),
                folderQuery.selection,
                folderQuery.selectionArgs.takeIf { it.isNotEmpty() }?.toTypedArray(),
                null
            )?.use { cursor ->
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
                    if (!mediaStoreDirectoryMatches(directory, folderQuery.directoryFilter)) continue
                    val path = ContentUris.withAppendedId(collection, cursor.getLong(idIndex)).toString()
                    val groupTitle = directory.substringAfterLast('/').ifBlank { "Media" }
                    remember(
                        tracks,
                        ScannedTrack(
                            path = path,
                            title = media.title,
                            groupKey = directory.ifBlank { folderQuery.directoryFilter },
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
        tracks: ScanTrackAccumulator,
        track: ScannedTrack,
        observer: FolderScanObserver
    ) {
        tracks.remember(track, observer)
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
