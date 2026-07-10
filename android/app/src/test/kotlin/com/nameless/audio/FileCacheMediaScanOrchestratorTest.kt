package com.nameless.audio

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FileCacheMediaScanOrchestratorTest {
    @Test
    fun `filesystem scan forwards discovered tracks to observer`() {
        val root = Files.createTempDirectory("nameless-scan-test").toFile()
        val observed = mutableListOf<String>()
        try {
            val orchestrator = FileCacheMediaScanOrchestrator(
                resolveContentUri = { null },
                contentUriToFilePath = { null },
                scanDocumentTree = { _, _, _ -> error("unexpected document scan") },
                scanFileSystemAsDocumentTree = { _, _, _, _ ->
                    error("unexpected document filesystem scan")
                },
                scanFileSystem = { _, output, observer ->
                    repeat(240) { index ->
                        val track = track("${root.path}/$index.mp3")
                        output[track.path] = track
                        observer.onEntryProcessed()
                        observer.onTrack(track)
                    }
                    0
                },
                scanMediaStore = { _, _, _ -> error("unexpected fallback") }
            )

            val result = orchestrator.scanFolder(
                root.path,
                observer(observed = observed)
            )

            assertEquals(240, observed.size)
            assertEquals(240, result.tracks.size)
            assertTrue(result.complete)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `cancelled filesystem scan does not continue to media store fallback`() {
        val root = Files.createTempDirectory("nameless-scan-cancel").toFile()
        var cancelled = false
        var mediaStoreCalled = false
        try {
            val orchestrator = FileCacheMediaScanOrchestrator(
                resolveContentUri = { null },
                contentUriToFilePath = { null },
                scanDocumentTree = { _, _, _ -> error("unexpected document scan") },
                scanFileSystemAsDocumentTree = { _, _, _, _ ->
                    error("unexpected document filesystem scan")
                },
                scanFileSystem = { _, _, _ ->
                    cancelled = true
                    0
                },
                scanMediaStore = { _, _, _ ->
                    mediaStoreCalled = true
                    0
                }
            )

            val result = orchestrator.scanFolder(
                root.path,
                observer(isCancelled = { cancelled })
            )

            assertFalse(mediaStoreCalled)
            assertFalse(result.complete)
        } finally {
            root.deleteRecursively()
        }
    }

    private fun observer(
        observed: MutableList<String> = mutableListOf(),
        isCancelled: () -> Boolean = { false }
    ): FolderScanObserver = object : FolderScanObserver {
        override fun isCancelled(): Boolean = isCancelled()

        override fun onTrack(track: FileCacheOperations.ScannedTrack) {
            observed.add(track.path)
        }
    }

    private fun track(path: String) = FileCacheOperations.ScannedTrack(
        path = path,
        title = path.substringAfterLast('/'),
        groupKey = path.substringBeforeLast('/'),
        groupTitle = "test",
        groupSubtitle = "test"
    )
}
