package com.nameless.audio.scanner

internal interface FolderScanObserver {
    fun isCancelled(): Boolean = false
    fun onStage(stage: String) = Unit
    fun onEntryProcessed(total: Int? = null) = Unit
    fun onTrack(track: ScannedTrack) = Unit
}

internal object NoopFolderScanObserver : FolderScanObserver

internal data class ScannedTrack(
    val path: String,
    val title: String,
    val groupKey: String,
    val groupTitle: String,
    val groupSubtitle: String,
    val isVideo: Boolean = false,
    val scannedAtMs: Long = System.currentTimeMillis(),
    val fileSizeBytes: Long? = null,
    val modifiedAtMs: Long? = null
)

internal data class ScanFolderResult(
    val tracks: List<ScannedTrack>,
    val failureCount: Int,
    val complete: Boolean
)
