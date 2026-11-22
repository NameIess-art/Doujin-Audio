package com.doujin.audio.metadata

import com.doujin.audio.common.*
import com.doujin.audio.storage.*

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.DocumentsContract
import java.io.File
import java.io.FileInputStream
import java.net.URLDecoder
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import java.security.MessageDigest
import java.util.Locale

internal fun shouldAttemptWavEmbeddedPictureFallback(source: String): Boolean {
    val trimmed = source.trim()
    if (trimmed.isEmpty()) return false
    val withoutQuery = trimmed.substringBefore('?').substringBefore('#')
    val decoded = if (withoutQuery.contains('%')) {
        runCatching { URLDecoder.decode(withoutQuery, Charsets.UTF_8.name()) }
            .getOrDefault(withoutQuery)
    } else {
        withoutQuery
    }
    val fileName = decoded
        .substringAfterLast('/')
        .substringAfterLast('\\')
        .substringAfterLast(':')
    val dotIndex = fileName.lastIndexOf('.')
    if (dotIndex <= 0 || dotIndex == fileName.lastIndex) return true
    val extension = fileName.substring(dotIndex + 1).lowercase(Locale.US)
    return extension == "wav"
}

internal fun embeddedCoverCacheFileName(bytes: ByteArray): String =
    artworkCacheFileName(bytes, "embedded", "image")

internal fun artworkCacheFileName(bytes: ByteArray, prefix: String, extension: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
    val contentKey = digest.joinToString(separator = "") {
        (it.toInt() and 0xff).toString(16).padStart(2, '0')
    }
    return "${prefix}_$contentKey.$extension"
}

internal class MediaMetadataOperations(
    private val context: Context,
    private val storage: DocumentStorageOperations
) {
    private data class EmbeddedCoverFingerprint(
        val key: String,
        val lastModifiedMs: Long,
        val lengthBytes: Long
    )

    private data class EmbeddedCoverCacheEntry(
        val coverPath: String?
    )

    private val embeddedCoverWriteLock = Any()
    private val embeddedCoverCache = object : LinkedHashMap<EmbeddedCoverFingerprint, EmbeddedCoverCacheEntry>(
        64,
        0.75f,
        true
    ) {
        override fun removeEldestEntry(
            eldest: MutableMap.MutableEntry<EmbeddedCoverFingerprint, EmbeddedCoverCacheEntry>?
        ): Boolean = size > MAX_EMBEDDED_COVER_CACHE_ENTRIES
    }

    private val videoFrameResolver by lazy {
        FileCacheVideoFrameResolver(
            context = context,
            cacheDir = context.cacheDir,
            touchCacheFile = ::touchCacheFile,
            resolveFilePath = storage::contentUriToFilePath
        )
    }

    fun resolveDurationMs(source: String): Long? = withRetriever(source) { retriever ->
        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
            ?.toLongOrNull()
            ?.takeIf { it > 0L }
    }

    fun resolveEmbeddedCover(source: String): String? {
        val trimmed = source.trim()
        if (trimmed.isEmpty()) return null
        val directPath = if (trimmed.startsWith("content://")) {
            storage.contentUriToFilePath(trimmed)
        } else {
            trimmed
        }
        val fingerprint = embeddedCoverFingerprint(trimmed, directPath)
        if (fingerprint != null) {
            val cached = synchronized(embeddedCoverCache) { embeddedCoverCache[fingerprint] }
            if (cached != null) {
                val cachedPath = cached.coverPath ?: return null
                val cachedFile = File(cachedPath)
                if (cachedFile.exists() && cachedFile.length() > 0L) {
                    touchCacheFile(cachedFile)
                    return cachedPath
                }
            }
        }

        val resolvedPath = extractAndCacheEmbeddedCover(trimmed, directPath)
        if (fingerprint != null) {
            synchronized(embeddedCoverCache) {
                embeddedCoverCache[fingerprint] = EmbeddedCoverCacheEntry(resolvedPath)
            }
        }
        return resolvedPath
    }

    private fun extractAndCacheEmbeddedCover(trimmed: String, directPath: String?): String? {
        val coverDirectory = File(context.cacheDir, "doujin_audio_covers")
        if (!coverDirectory.exists()) coverDirectory.mkdirs()
        val bytes = withRetriever(trimmed, directPath) { it.embeddedPicture }
            ?: run {
                val fallbackTarget = directPath ?: trimmed
                if (shouldAttemptWavEmbeddedPictureFallback(fallbackTarget)) {
                    extractEmbeddedPictureFallback(trimmed, directPath)
                } else {
                    null
                }
            }
            ?: return null
        if (bytes.isEmpty()) return null
        val output = File(coverDirectory, embeddedCoverCacheFileName(bytes))
        synchronized(embeddedCoverWriteLock) {
            if (output.exists() && output.length() > 0L) {
                touchCacheFile(output)
                return output.absolutePath
            }
            return try {
                output.writeBytes(bytes)
                touchCacheFile(output)
                output.absolutePath
            } catch (_: Exception) {
                output.delete()
                null
            }
        }
    }

    private fun embeddedCoverFingerprint(
        trimmed: String,
        directPath: String?
    ): EmbeddedCoverFingerprint? {
        if (directPath != null) {
            val file = File(directPath)
            if (file.exists() && file.canRead()) {
                return EmbeddedCoverFingerprint(
                    key = file.absolutePath,
                    lastModifiedMs = file.lastModified(),
                    lengthBytes = file.length()
                )
            }
        }
        if (trimmed.startsWith("content://")) {
            val resolvedUri = storage.resolveDocumentUri(trimmed)
                ?: Uri.parse(trimmed.substringBefore("::"))
            val projection = arrayOf(
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                DocumentsContract.Document.COLUMN_SIZE
            )
            runCatching {
                context.contentResolver.query(resolvedUri, projection, null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val modified = if (cursor.isNull(0)) 0L else cursor.getLong(0)
                        val size = if (cursor.isNull(1)) 0L else cursor.getLong(1)
                        if (modified > 0L || size > 0L) {
                            return EmbeddedCoverFingerprint(
                                key = resolvedUri.toString(),
                                lastModifiedMs = modified,
                                lengthBytes = size
                            )
                        }
                    }
                }
            }
        }
        return null
    }

    fun resolveVideoFrame(source: String, modifiedAtMs: Long?): String? =
        videoFrameResolver.resolve(source, modifiedAtMs)

    private fun <T> withRetriever(
        source: String,
        preResolvedDirectPath: String? = null,
        block: (MediaMetadataRetriever) -> T?
    ): T? {
        val trimmed = source.trim()
        if (trimmed.isEmpty()) return null

        val directPath = preResolvedDirectPath ?: if (trimmed.startsWith("content://")) {
            storage.contentUriToFilePath(trimmed)
        } else {
            trimmed
        }
        if (directPath != null) {
            val file = File(directPath)
            if (file.exists() && file.canRead()) {
                var retriever: MediaMetadataRetriever? = null
                try {
                    retriever = MediaMetadataRetriever()
                    retriever.setDataSource(file.absolutePath)
                    return block(retriever)
                } catch (_: Exception) {
                    // Direct file access failed; continue to content resolver fallback.
                } finally {
                    try {
                        retriever?.release()
                    } catch (_: Exception) {}
                }
            }
        }

        if (trimmed.startsWith("content://")) {
            val resolvedUri = storage.resolveDocumentUri(trimmed)
                ?: Uri.parse(trimmed.substringBefore("::"))
            var retriever: MediaMetadataRetriever? = null
            return try {
                retriever = MediaMetadataRetriever()
                val pfd = try {
                    context.contentResolver.openFileDescriptor(resolvedUri, "r")
                } catch (_: Exception) {
                    null
                }
                if (pfd != null) {
                    pfd.use {
                        retriever.setDataSource(it.fileDescriptor)
                        block(retriever)
                    }
                } else {
                    retriever.setDataSource(context, resolvedUri)
                    block(retriever)
                }
            } catch (_: Exception) {
                null
            } finally {
                try {
                    retriever?.release()
                } catch (_: Exception) {
                    // Native metadata cleanup is best effort after a failed probe.
                }
            }
        }

        return null
    }

    private fun extractEmbeddedPictureFallback(
        trimmed: String,
        directPath: String?
    ): ByteArray? {
        if (trimmed.isEmpty()) return null

        if (directPath != null) {
            val file = File(directPath)
            if (file.exists() && file.canRead()) {
                try {
                    FileInputStream(file).use { fis ->
                        return extractPictureFromChannel(fis.channel)
                    }
                } catch (_: Exception) {}
            }
        }

        if (trimmed.startsWith("content://")) {
            val resolvedUri = storage.resolveDocumentUri(trimmed)
                ?: Uri.parse(trimmed.substringBefore("::"))
            try {
                val pfd = context.contentResolver.openFileDescriptor(resolvedUri, "r")
                pfd?.use {
                    FileInputStream(it.fileDescriptor).use { fis ->
                        val result = extractPictureFromChannel(fis.channel)
                        if (result != null) return result
                    }
                }
            } catch (_: Exception) {}
        }

        return null
    }

    private fun extractPictureFromChannel(channel: FileChannel): ByteArray? {
        val size = channel.size()
        if (size < 12) return null
        val header = ByteBuffer.allocate(12)
        channel.position(0)
        if (channel.read(header) < 12) return null
        header.flip()

        val b0 = header.get().toInt() and 0xFF
        val b1 = header.get().toInt() and 0xFF
        val b2 = header.get().toInt() and 0xFF
        val b3 = header.get().toInt() and 0xFF

        if (b0 == 'R'.code && b1 == 'I'.code && b2 == 'F'.code && b3 == 'F'.code) {
            header.position(8)
            val w0 = header.get().toInt() and 0xFF
            val w1 = header.get().toInt() and 0xFF
            val w2 = header.get().toInt() and 0xFF
            val w3 = header.get().toInt() and 0xFF
            if (w0 == 'W'.code && w1 == 'A'.code && w2 == 'V'.code && w3 == 'E'.code) {
                return extractRiffId3Picture(channel, size)
            }
        }
        return null
    }

    private fun extractRiffId3Picture(channel: FileChannel, fileSize: Long): ByteArray? {
        var offset = 12L
        val chunkHeader = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
        val chunkIdBytes = ByteArray(4)

        while (offset + 8L <= fileSize) {
            channel.position(offset)
            chunkHeader.clear()
            if (channel.read(chunkHeader) < 8) break
            chunkHeader.flip()
            chunkHeader.get(chunkIdBytes)
            val chunkSize = chunkHeader.int.toLong() and 0xFFFFFFFFL
            val chunkId = String(chunkIdBytes, Charsets.US_ASCII)
            if (chunkId.equals("id3 ", ignoreCase = true)) {
                return extractId3Picture(channel, offset + 8L, chunkSize)
            }
            offset += 8L + chunkSize + (chunkSize % 2L)
            if (chunkSize <= 0L) break
        }
        return null
    }

    private fun extractId3Picture(
        channel: FileChannel,
        startOffset: Long,
        maxChunkBytes: Long
    ): ByteArray? {
        if (maxChunkBytes < 10L) return null
        val headerBuf = ByteBuffer.allocate(10)
        channel.position(startOffset)
        if (channel.read(headerBuf) < 10) return null
        headerBuf.flip()

        if (headerBuf.get() != 0x49.toByte() ||
            headerBuf.get() != 0x44.toByte() ||
            headerBuf.get() != 0x33.toByte()
        ) {
            return null
        }
        val majorVersion = headerBuf.get().toInt() and 0xFF
        if (majorVersion !in 2..4) return null
        headerBuf.get() // revision
        val flags = headerBuf.get().toInt() and 0xFF
        val extHeader = (flags and 0x40) != 0

        val b0 = headerBuf.get().toInt() and 0x7F
        val b1 = headerBuf.get().toInt() and 0x7F
        val b2 = headerBuf.get().toInt() and 0x7F
        val b3 = headerBuf.get().toInt() and 0x7F
        val tagSize = (b0 shl 21) or (b1 shl 14) or (b2 shl 7) or b3
        if (tagSize <= 0 || tagSize > 20 * 1024 * 1024) return null

        val bytesToRead = (maxChunkBytes - 10L).coerceAtMost(tagSize.toLong()).toInt()
        val tagBuf = ByteBuffer.allocate(bytesToRead)
        if (channel.read(tagBuf) <= 0) return null
        tagBuf.flip()
        val tagData = ByteArray(tagBuf.remaining())
        tagBuf.get(tagData)

        return parseId3TagPicture(tagData, majorVersion, extHeader)
    }

    private companion object {
        const val MAX_EMBEDDED_COVER_CACHE_ENTRIES = 512
    }
}

internal fun parseId3TagPicture(
    tagData: ByteArray,
    majorVersion: Int,
    extHeader: Boolean
): ByteArray? {
    var offset = 0
    if (extHeader) {
        if (majorVersion == 3) {
            if (offset + 4 > tagData.size) return null
            val extSize = ((tagData[offset].toInt() and 0xFF) shl 24) or
                ((tagData[offset + 1].toInt() and 0xFF) shl 16) or
                ((tagData[offset + 2].toInt() and 0xFF) shl 8) or
                (tagData[offset + 3].toInt() and 0xFF)
            if (extSize < 0 || extSize > tagData.size - (offset + 4)) return null
            offset += 4 + extSize
        } else if (majorVersion == 4) {
            if (offset + 4 > tagData.size) return null
            val extSize = ((tagData[offset].toInt() and 0x7F) shl 21) or
                ((tagData[offset + 1].toInt() and 0x7F) shl 14) or
                ((tagData[offset + 2].toInt() and 0x7F) shl 7) or
                (tagData[offset + 3].toInt() and 0x7F)
            if (extSize < 4 || extSize > tagData.size - offset) return null
            offset += extSize
        }
    }

    while (offset < tagData.size) {
        val idLength = if (majorVersion == 2) 3 else 4
        if (offset + idLength > tagData.size) break
        val frameId = String(tagData, offset, idLength, Charsets.US_ASCII)
        offset += idLength
        if (frameId.any { it == '\u0000' }) break

        val frameSize = when (majorVersion) {
            2 -> {
                if (offset + 3 > tagData.size) break
                val s = ((tagData[offset].toInt() and 0xFF) shl 16) or
                    ((tagData[offset + 1].toInt() and 0xFF) shl 8) or
                    (tagData[offset + 2].toInt() and 0xFF)
                offset += 3
                s
            }
            3 -> {
                if (offset + 4 > tagData.size) break
                val s = ((tagData[offset].toInt() and 0xFF) shl 24) or
                    ((tagData[offset + 1].toInt() and 0xFF) shl 16) or
                    ((tagData[offset + 2].toInt() and 0xFF) shl 8) or
                    (tagData[offset + 3].toInt() and 0xFF)
                offset += 4
                s
            }
            else -> {
                if (offset + 4 > tagData.size) break
                val s = ((tagData[offset].toInt() and 0x7F) shl 21) or
                    ((tagData[offset + 1].toInt() and 0x7F) shl 14) or
                    ((tagData[offset + 2].toInt() and 0x7F) shl 7) or
                    (tagData[offset + 3].toInt() and 0x7F)
                offset += 4
                s
            }
        }

        val flagsLength = if (majorVersion == 2) 0 else 2
        if (offset + flagsLength > tagData.size) break
        offset += flagsLength
        if (frameSize <= 0 || frameSize > tagData.size - offset) break

        val frameEnd = offset + frameSize
        if (frameId == "APIC" || frameId == "PIC") {
            var frameOffset = offset
            if (frameOffset >= frameEnd) {
                offset = frameEnd
                continue
            }
            val encoding = tagData[frameOffset].toInt() and 0xFF
            frameOffset++

            if (majorVersion == 2) {
                if (frameOffset + 3 > frameEnd) {
                    offset = frameEnd
                    continue
                }
                frameOffset += 3
            } else {
                while (frameOffset < frameEnd && tagData[frameOffset] != 0.toByte()) {
                    frameOffset++
                }
                if (frameOffset >= frameEnd) {
                    offset = frameEnd
                    continue
                }
                frameOffset++
            }

            if (frameOffset >= frameEnd) {
                offset = frameEnd
                continue
            }
            frameOffset++ // picture type

            if (encoding == 1 || encoding == 2) {
                var foundTerminator = false
                while (frameOffset < frameEnd - 1) {
                    if (tagData[frameOffset] == 0.toByte() && tagData[frameOffset + 1] == 0.toByte()) {
                        frameOffset += 2
                        foundTerminator = true
                        break
                    }
                    frameOffset += 2
                }
                if (!foundTerminator) {
                    offset = frameEnd
                    continue
                }
            } else {
                while (frameOffset < frameEnd && tagData[frameOffset] != 0.toByte()) {
                    frameOffset++
                }
                if (frameOffset >= frameEnd) {
                    offset = frameEnd
                    continue
                }
                frameOffset++
            }

            if (frameOffset < frameEnd) {
                return tagData.copyOfRange(frameOffset, frameEnd)
            }
        }
        offset = frameEnd
    }
    return null
}
