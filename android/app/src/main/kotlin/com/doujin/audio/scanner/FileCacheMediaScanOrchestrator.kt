package com.doujin.audio.scanner

import android.net.Uri
import java.io.File

internal class ScanTrackAccumulator(
    private val collectTracks: Boolean
) {
    private val tracksByPath = if (collectTracks) {
        linkedMapOf<String, ScannedTrack>()
    } else {
        null
    }
    private val seenPaths = if (collectTracks) null else hashSetOf<String>()

    val isNotEmpty: Boolean
        get() = tracksByPath?.isNotEmpty() ?: seenPaths!!.isNotEmpty()

    fun remember(track: ScannedTrack, observer: FolderScanObserver) {
        val added = if (tracksByPath != null) {
            tracksByPath.putIfAbsent(track.path, track) == null
        } else {
            seenPaths!!.add(track.path)
        }
        if (added) observer.onTrack(track)
    }

    fun resultTracks(): List<ScannedTrack> =
        tracksByPath?.values?.toList() ?: emptyList()
}

internal class FileCacheMediaScanOrchestrator(
    private val resolveContentUri: (String) -> Uri?,
    private val contentUriToFilePath: (String) -> String?,
    private val scanDocumentTree: (
        Uri,
        ScanTrackAccumulator,
        FolderScanObserver
    ) -> Int,
    private val scanFileSystemAsDocumentTree: (
        Uri,
        File,
        ScanTrackAccumulator,
        FolderScanObserver
    ) -> Int,
    private val scanFileSystem: (
        File,
        ScanTrackAccumulator,
        FolderScanObserver
    ) -> Int,
    private val scanMediaStore: (
        String,
        ScanTrackAccumulator,
        FolderScanObserver
    ) -> Int
) {
    fun scanFolder(
        folder: String,
        observer: FolderScanObserver,
        collectTracks: Boolean = true
    ): ScanFolderResult {
        val tracks = ScanTrackAccumulator(collectTracks)
        val folderTrimmed = folder.trim()
        val uri = resolveContentUri(folderTrimmed)
        var failureCount = 0
        observer.onStage("preparing")

        if (uri != null) {
            observer.onStage("enumerating")
            failureCount += scanDocumentTree(uri, tracks, observer)
            if (observer.isCancelled() || tracks.isNotEmpty) {
                return result(tracks, failureCount, observer)
            }

            // Some ROMs keep the renamed directory readable before its SAF URI
            // becomes queryable, so direct scanning remains the compatibility fallback.
            val filePath = contentUriToFilePath(folderTrimmed)
            if (filePath != null) {
                val root = File(filePath)
                if (root.exists() && root.isDirectory) {
                    failureCount += scanFileSystemAsDocumentTree(uri, root, tracks, observer)
                    if (observer.isCancelled() || tracks.isNotEmpty) {
                        return result(tracks, failureCount, observer)
                    }
                    failureCount += scanMediaStore(filePath, tracks, observer)
                    return result(tracks, failureCount, observer)
                }
            }
            return result(tracks, failureCount, observer)
        }

        val root = File(folderTrimmed)
        if (root.exists() && root.isDirectory) {
            observer.onStage("enumerating")
            failureCount += scanFileSystem(root, tracks, observer)
            if (observer.isCancelled() || tracks.isNotEmpty) {
                return result(tracks, failureCount, observer)
            }
        } else {
            failureCount++
        }
        if (!observer.isCancelled()) {
            failureCount += scanMediaStore(folderTrimmed, tracks, observer)
        }
        return result(tracks, failureCount, observer)
    }

    private fun result(
        tracks: ScanTrackAccumulator,
        failureCount: Int,
        observer: FolderScanObserver
    ): ScanFolderResult {
        return ScanFolderResult(
            tracks = tracks.resultTracks(),
            failureCount = failureCount,
            complete = failureCount == 0 && !observer.isCancelled()
        )
    }
}
