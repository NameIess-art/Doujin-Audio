package com.nameless.audio

import android.net.Uri
import java.io.File

internal class FileCacheMediaScanOrchestrator(
    private val resolveContentUri: (String) -> Uri?,
    private val contentUriToFilePath: (String) -> String?,
    private val scanDocumentTree: (
        Uri,
        MutableMap<String, FileCacheOperations.ScannedTrack>
    ) -> Int,
    private val scanFileSystemAsDocumentTree: (
        Uri,
        File,
        MutableMap<String, FileCacheOperations.ScannedTrack>
    ) -> Int,
    private val scanFileSystem: (
        File,
        MutableMap<String, FileCacheOperations.ScannedTrack>
    ) -> Int,
    private val scanMediaStore: (
        String,
        MutableMap<String, FileCacheOperations.ScannedTrack>
    ) -> Int
) {
    fun scanFolder(folder: String): FileCacheOperations.ScanFolderResult {
        val byPath = linkedMapOf<String, FileCacheOperations.ScannedTrack>()
        val folderTrimmed = folder.trim()
        val uri = resolveContentUri(folderTrimmed)
        var failureCount = 0

        if (uri != null) {
            failureCount += scanDocumentTree(uri, byPath)
            if (byPath.isNotEmpty()) return result(byPath, failureCount)

            // Some ROMs keep the renamed directory readable before its SAF URI
            // becomes queryable, so direct scanning remains the compatibility fallback.
            val filePath = contentUriToFilePath(folderTrimmed)
            if (filePath != null) {
                val root = File(filePath)
                if (root.exists() && root.isDirectory) {
                    failureCount += scanFileSystemAsDocumentTree(uri, root, byPath)
                    if (byPath.isNotEmpty()) return result(byPath, failureCount)
                    failureCount += scanMediaStore(filePath, byPath)
                    return result(byPath, failureCount)
                }
            }
            return result(byPath, failureCount)
        }

        val root = File(folderTrimmed)
        if (root.exists() && root.isDirectory) {
            failureCount += scanFileSystem(root, byPath)
            if (byPath.isNotEmpty()) return result(byPath, failureCount)
        } else {
            failureCount++
        }
        failureCount += scanMediaStore(folderTrimmed, byPath)
        return result(byPath, failureCount)
    }

    private fun result(
        tracks: Map<String, FileCacheOperations.ScannedTrack>,
        failureCount: Int
    ): FileCacheOperations.ScanFolderResult {
        return FileCacheOperations.ScanFolderResult(
            tracks = tracks.values.toList(),
            failureCount = failureCount,
            complete = failureCount == 0
        )
    }
}
