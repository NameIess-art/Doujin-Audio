package com.doujin.audio.scanner

internal fun ScannedTrack.toScanPayload(): HashMap<String, Any?> {
    return hashMapOf(
        "path" to path,
        "title" to title,
        "groupKey" to groupKey,
        "groupTitle" to groupTitle,
        "groupSubtitle" to groupSubtitle,
        "isVideo" to isVideo,
        "scannedAtMs" to scannedAtMs,
        "fileSizeBytes" to fileSizeBytes,
        "modifiedAtMs" to modifiedAtMs
    )
}
