package com.doujin.audio.metadata

import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import java.io.ByteArrayOutputStream
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

    private fun decodePercent(value: String): String = decodePercentRfc3986(value)

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
        if (mime?.startsWith("audio/") == true) return false
        if (extension.isBlank()) return false
        if (extension in supportedVideoExtensions) return true
        if (extension in supportedAudioExtensions) return false
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

/**
 * Decodes RFC 3986 `%XX` UTF-8 sequences without turning `+` into space
 * (unlike `URLDecoder`), leaving malformed `%` sequences intact.
 */
internal fun decodePercentRfc3986(value: String): String {
    if ('%' !in value) return value
    val out = StringBuilder(value.length)
    val bytes = ByteArrayOutputStream()
    var i = 0
    val len = value.length
    while (i < len) {
        if (value[i] == '%' && i + 2 < len) {
            val hi = hexDigit(value[i + 1])
            val lo = hexDigit(value[i + 2])
            if (hi >= 0 && lo >= 0) {
                bytes.reset()
                while (i + 2 < len && value[i] == '%') {
                    val h = hexDigit(value[i + 1])
                    val l = hexDigit(value[i + 2])
                    if (h < 0 || l < 0) break
                    bytes.write((h shl 4) or l)
                    i += 3
                }
                out.append(String(bytes.toByteArray(), StandardCharsets.UTF_8))
                continue
            }
        }
        out.append(value[i])
        i++
    }
    return out.toString()
}

private fun hexDigit(c: Char): Int = when (c) {
    in '0'..'9' -> c - '0'
    in 'a'..'f' -> c - 'a' + 10
    in 'A'..'F' -> c - 'A' + 10
    else -> -1
}
