package com.doujin.audio.metadata

import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.Locale

internal data class MediaNameInfo(
    val title: String,
    val isVideo: Boolean
)

internal object MediaNameMetadata {
    private val blockedExtensions = setOf(
        "vtt", "srt", "ass", "ssa", "lrc", "txt", "md", "json", "xml",
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif",
        "pdf", "zip", "rar", "7z", "tar", "gz", "doc", "docx"
    )

    private val supportedAudioExtensions = setOf(
        "flac", "wav", "mp3", "m4a", "aac", "ogg", "opus", "3gp",
        "wma", "ape", "wv", "mka", "m4b", "oga", "aiff", "aif"
    )

    private val supportedVideoExtensions = setOf(
        "mp4", "mkv", "webm", "mov", "m4v", "avi", "3gp"
    )

    fun normalizeDisplayName(raw: String): String {
        var text = raw.trim()
        if (text.isEmpty()) return text
        text = decodePercent(text)
        if (looksLikeMojibake(text)) {
            val maybeFixed = latin1ToUtf8(text)
            if (!looksLikeMojibake(maybeFixed)) {
                text = maybeFixed
            }
        }
        return text.trim()
    }

    fun mediaNameInfoOrNull(name: String, mime: String? = null): MediaNameInfo? {
        val displayName = name.trim()
        if (displayName.isEmpty()) return null
        val dotIndex = displayName.lastIndexOf('.')
        val extension = if (dotIndex > 0 && dotIndex < displayName.length - 1) {
            displayName.substring(dotIndex + 1).lowercase(Locale.US)
        } else {
            ""
        }
        val normalizedMime = mime?.trim()?.lowercase(Locale.US)
        if (!isSupportedMediaName(extension, normalizedMime)) return null
        val title = if (dotIndex > 0) displayName.substring(0, dotIndex) else displayName
        return MediaNameInfo(
            title = title,
            isVideo = isVideoMediaName(extension, normalizedMime)
        )
    }

    private fun decodePercent(value: String): String {
        if (!value.contains('%')) return value
        return try {
            URLDecoder.decode(value, StandardCharsets.UTF_8.name())
        } catch (_: Exception) {
            value
        }
    }

    private fun latin1ToUtf8(value: String): String {
        return try {
            String(value.toByteArray(Charsets.ISO_8859_1), Charsets.UTF_8)
        } catch (_: Exception) {
            value
        }
    }

    private fun looksLikeMojibake(value: String): Boolean {
        if (value.isEmpty()) return false
        if (value.any { it == '\uFFFD' || it == '\u951F' }) return true
        return value.count { it.code in 0x00C0..0x00FF } >= 2
    }

    private fun isSupportedMediaName(extension: String, mime: String?): Boolean {
        if (mime != null) {
            if (mime == DocumentsContract.Document.MIME_TYPE_DIR) return false
            if (isSupportedMediaMime(mime)) return true
        }
        if (extension.isBlank()) return false
        if (blockedExtensions.contains(extension)) return false
        if (extension in supportedAudioExtensions || extension in supportedVideoExtensions) {
            return true
        }
        val extensionMime = mimeTypeFromExtension(extension)
        return extensionMime != null && isSupportedMediaMime(extensionMime)
    }

    private fun isSupportedMediaMime(mime: String): Boolean {
        return mime.startsWith("audio/") ||
            mime.startsWith("video/") ||
            mime == "application/ogg"
    }

    private fun isVideoMediaName(extension: String, mime: String?): Boolean {
        if (mime?.startsWith("video/") == true) return true
        if (extension.isBlank()) return false
        if (extension in supportedVideoExtensions) return true
        return mimeTypeFromExtension(extension)?.startsWith("video/") == true
    }

    private fun mimeTypeFromExtension(extension: String): String? {
        return try {
            MimeTypeMap.getSingleton()?.getMimeTypeFromExtension(extension)?.lowercase(Locale.US)
        } catch (_: RuntimeException) {
            null
        }
    }
}
