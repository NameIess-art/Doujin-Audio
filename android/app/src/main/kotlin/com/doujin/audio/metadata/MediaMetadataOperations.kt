package com.doujin.audio.metadata

import com.doujin.audio.common.*
import com.doujin.audio.storage.*

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import java.io.File
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
        val bytes = withRetriever(source) { it.embeddedPicture } ?: return null
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
        var retriever: MediaMetadataRetriever? = null
        return try {
            retriever = MediaMetadataRetriever()
            if (source.startsWith("content://")) {
                retriever.setDataSource(context, Uri.parse(source))
            } else {
                retriever.setDataSource(source)
            }
            block(retriever)
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
}
