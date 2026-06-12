package com.nameless.audio

import android.net.Uri
import java.io.File

internal class FileCacheMediaScanOrchestrator(
    private val resolveContentUri: (String) -> Uri?,
    private val contentUriToFilePath: (String) -> String?,
    private val scanDocumentTree: (
        Uri,
        MutableMap<String, FileCacheOperations.ScannedTrack>
    ) -> Unit,
    private val scanFileSystemAsDocumentTree: (
        Uri,
        File,
        MutableMap<String, FileCacheOperations.ScannedTrack>
    ) -> Unit,
    private val scanFileSystem: (
        File,
        MutableMap<String, FileCacheOperations.ScannedTrack>
    ) -> Unit,
    private val scanMediaStore: (
        String,
        MutableMap<String, FileCacheOperations.ScannedTrack>
    ) -> Unit
) {
    fun scanFolder(folder: String): List<FileCacheOperations.ScannedTrack> {
        val byPath = linkedMapOf<String, FileCacheOperations.ScannedTrack>()
        val folderTrimmed = folder.trim()
        val uri = resolveContentUri(folderTrimmed)

        if (uri != null) {
            scanDocumentTree(uri, byPath)
            if (byPath.isNotEmpty()) return byPath.values.toList()

            // Some ROMs keep the renamed directory readable before its SAF URI
            // becomes queryable, so direct scanning remains the compatibility fallback.
            val filePath = contentUriToFilePath(folderTrimmed)
            if (filePath != null) {
                val root = File(filePath)
                if (root.exists() && root.isDirectory) {
                    scanFileSystemAsDocumentTree(uri, root, byPath)
                    if (byPath.isNotEmpty()) return byPath.values.toList()
                    scanMediaStore(filePath, byPath)
                    return byPath.values.toList()
                }
            }
            return byPath.values.toList()
        }

        val root = File(folderTrimmed)
        if (root.exists() && root.isDirectory) {
            scanFileSystem(root, byPath)
            if (byPath.isNotEmpty()) return byPath.values.toList()
        }
        scanMediaStore(folderTrimmed, byPath)
        return byPath.values.toList()
    }
}
