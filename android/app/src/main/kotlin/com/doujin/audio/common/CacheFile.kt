package com.doujin.audio.common

import java.io.File

internal fun touchCacheFile(file: File) {
    try {
        file.setLastModified(System.currentTimeMillis())
    } catch (_: Exception) {
        // Cache recency is best effort; the file remains usable without it.
    }
}
