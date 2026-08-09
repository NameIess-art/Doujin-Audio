package com.doujin.audio.scanner

import android.net.Uri
import java.io.File

internal class FileCacheMediaScanOrchestrator(
    private val resolveContentUri: (String) -> Uri?,
    private val contentUriToFilePath: (String) -> String?,
    private val scanDocumentTree: (
        Uri,
        MutableMap<String, ScannedTrack>,
        FolderScanObserver
    ) -> Int,
    private val scanFileSystemAsDocumentTree: (
        Uri,
        File,
        MutableMap<String, ScannedTrack>,
        FolderScanObserver
    ) -> Int,
    private val scanFileSystem: (
        File,
        MutableMap<String, ScannedTrack>,
        FolderScanObserver
    ) -> Int,
    private val scanMediaStore: (
        String,
        MutableMap<String, ScannedTrack>,
        FolderScanObserver
    ) -> Int
) {
    fun scanFolder(
        folder: String,
        observer: FolderScanObserver
    ): ScanFolderResult {
        val byPath = linkedMapOf<String, ScannedTrack>()
        val folderTrimmed = folder.trim()
        val uri = resolveContentUri(folderTrimmed)
        var failureCount = 0
        observer.onStage("preparing")

        if (uri != null) {
            observer.onStage("enumerating")
            failureCount += scanDocumentTree(uri, byPath, observer)
            if (observer.isCancelled() || byPath.isNotEmpty()) {
                return result(byPath, failureCount, observer)
            }

            // Some ROMs keep the renamed directory readable before its SAF URI
            // becomes queryable, so direct scanning remains the compatibility fallback.
            val filePath = contentUriToFilePath(folderTrimmed)
            if (filePath != null) {
                val root = File(filePath)
                if (root.exists() && root.isDirectory) {
                    failureCount += scanFileSystemAsDocumentTree(uri, root, byPath, observer)
                    if (observer.isCancelled() || byPath.isNotEmpty()) {
                        return result(byPath, failureCount, observer)
                    }
                    failureCount += scanMediaStore(filePath, byPath, observer)
                    return result(byPath, failureCount, observer)
                }
            }
            return result(byPath, failureCount, observer)
        }

        val root = File(folderTrimmed)
        if (root.exists() && root.isDirectory) {
            observer.onStage("enumerating")
            failureCount += scanFileSystem(root, byPath, observer)
            if (observer.isCancelled() || byPath.isNotEmpty()) {
                return result(byPath, failureCount, observer)
            }
        } else {
            failureCount++
        }
        if (!observer.isCancelled()) {
            failureCount += scanMediaStore(folderTrimmed, byPath, observer)
        }
        return result(byPath, failureCount, observer)
    }

    private fun result(
        tracks: Map<String, ScannedTrack>,
        failureCount: Int,
        observer: FolderScanObserver
    ): ScanFolderResult {
        return ScanFolderResult(
            tracks = tracks.values.toList(),
            failureCount = failureCount,
            complete = failureCount == 0 && !observer.isCancelled()
        )
    }
}
