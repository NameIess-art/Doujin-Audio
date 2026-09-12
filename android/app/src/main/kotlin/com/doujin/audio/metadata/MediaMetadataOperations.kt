package com.doujin.audio.metadata

import com.doujin.audio.common.*
import com.doujin.audio.storage.*

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import java.security.MessageDigest

internal fun embeddedCoverCacheFileName(bytes: ByteArray): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
    val contentKey = digest.joinToString(separator = "") {
        (it.toInt() and 0xff).toString(16).padStart(2, '0')
    }
    return "embedded_$contentKey.image"
}

internal class MediaMetadataOperations(
    private val context: Context,
    private val storage: DocumentStorageOperations,
    private val cachePolicy: ApplicationCachePolicy
) {
    private val embeddedCoverWriteLock = Any()

    private val videoFrameResolver by lazy {
        FileCacheVideoFrameResolver(
            context = context,
            cacheDir = context.cacheDir,
            touchCacheFile = cachePolicy::touch,
            resolveFilePath = storage::contentUriToFilePath
        )
    }

    fun resolveDurationMs(source: String): Long? = withRetriever(source) { retriever ->
        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
            ?.toLongOrNull()
            ?.takeIf { it > 0L }
    }

    fun resolveEmbeddedCover(source: String): String? {
        val coverDirectory = File(context.cacheDir, "doujin_audio_covers")
        if (!coverDirectory.exists()) coverDirectory.mkdirs()
        val bytes = withRetriever(source) { it.embeddedPicture }
            ?: extractEmbeddedPictureFallback(source)
            ?: return null
        if (bytes.isEmpty()) return null
        val output = File(coverDirectory, embeddedCoverCacheFileName(bytes))
        synchronized(embeddedCoverWriteLock) {
            if (output.exists() && output.length() > 0L) {
                cachePolicy.touch(output)
                return output.absolutePath
            }
            return try {
                output.writeBytes(bytes)
                cachePolicy.touch(output)
                output.absolutePath
            } catch (_: Exception) {
                output.delete()
                null
            }
        }
    }

    fun resolveVideoFrame(source: String, modifiedAtMs: Long?): String? =
        videoFrameResolver.resolve(source, modifiedAtMs)

    private fun <T> withRetriever(source: String, block: (MediaMetadataRetriever) -> T?): T? {
        val trimmed = source.trim()
        if (trimmed.isEmpty()) return null

        val directPath = if (trimmed.startsWith("content://")) {
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
                    val result = block(retriever)
                    if (result != null) return result
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

    private fun extractEmbeddedPictureFallback(source: String): ByteArray? {
        val trimmed = source.trim()
        if (trimmed.isEmpty()) return null

        val directPath = if (trimmed.startsWith("content://")) {
            storage.contentUriToFilePath(trimmed)
        } else {
            trimmed
        }
        if (directPath != null) {
            val file = File(directPath)
            if (file.exists() && file.canRead()) {
                try {
                    FileInputStream(file).use { fis ->
                        val result = extractPictureFromChannel(fis.channel)
                        if (result != null) return result
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

    private fun parseId3TagPicture(
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
                offset += extSize
            } else if (majorVersion == 4) {
                if (offset + 4 > tagData.size) return null
                val extSize = ((tagData[offset].toInt() and 0x7F) shl 21) or
                        ((tagData[offset + 1].toInt() and 0x7F) shl 14) or
                        ((tagData[offset + 2].toInt() and 0x7F) shl 7) or
                        (tagData[offset + 3].toInt() and 0x7F)
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
            offset += flagsLength
            if (frameSize <= 0 || offset + frameSize > tagData.size) {
                offset += frameSize
                continue
            }

            if (frameId == "APIC" || frameId == "PIC") {
                var frameOffset = offset
                val encoding = tagData[frameOffset].toInt() and 0xFF
                frameOffset++

                if (majorVersion == 2) {
                    frameOffset += 3
                } else {
                    while (frameOffset < offset + frameSize && tagData[frameOffset] != 0.toByte()) {
                        frameOffset++
                    }
                    frameOffset++
                }

                frameOffset++ // picture type

                if (encoding == 1 || encoding == 2) {
                    while (frameOffset < offset + frameSize - 1) {
                        if (tagData[frameOffset] == 0.toByte() && tagData[frameOffset + 1] == 0.toByte()) {
                            frameOffset += 2
                            break
                        }
                        frameOffset++
                    }
                } else {
                    while (frameOffset < offset + frameSize && tagData[frameOffset] != 0.toByte()) {
                        frameOffset++
                    }
                    frameOffset++
                }

                val pictureLength = (offset + frameSize) - frameOffset
                if (pictureLength > 0 && frameOffset + pictureLength <= tagData.size) {
                    return tagData.copyOfRange(frameOffset, frameOffset + pictureLength)
                }
            }
            offset += frameSize
        }
        return null
    }
}
