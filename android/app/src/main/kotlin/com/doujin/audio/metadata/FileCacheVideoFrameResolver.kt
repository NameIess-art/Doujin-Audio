package com.doujin.audio.metadata

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import java.io.File
import java.io.FileOutputStream
import kotlin.math.abs

internal class FileCacheVideoFrameResolver(
    private val context: Context,
    private val cacheDir: File,
    private val touchCacheFile: (File) -> Unit,
    private val resolveFilePath: (String) -> String?
) {
    fun resolve(trackPath: String, modifiedAtMs: Long?): String? {
        val coverCacheDir = File(cacheDir, "doujin_audio_covers")
        if (!coverCacheDir.exists()) {
            coverCacheDir.mkdirs()
        }
        val cacheKey = buildString {
            append(trackPath)
            if (modifiedAtMs != null) {
                append('|')
                append(modifiedAtMs)
            }
            append("|v2")
        }
        val outputFile = File(
            coverCacheDir,
            "video_frame_${abs(cacheKey.hashCode())}.jpg"
        )
        if (outputFile.exists() && outputFile.length() > 0) {
            touchCacheFile(outputFile)
            return outputFile.absolutePath
        }

        var retriever: MediaMetadataRetriever? = null
        try {
            retriever = MediaMetadataRetriever()
            if (trackPath.startsWith("content://")) {
                try {
                    retriever.setDataSource(context, Uri.parse(trackPath))
                } catch (e: Exception) {
                    val filePath = resolveFilePath(trackPath)
                    if (filePath != null) {
                        retriever.setDataSource(filePath)
                    } else {
                        throw e
                    }
                }
            } else {
                retriever.setDataSource(trackPath)
            }

            val durationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
                ?: 0L
            val bitmap = selectFrame(retriever, durationMs) ?: return null

            FileOutputStream(outputFile).use { output ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 88, output)
                output.flush()
            }
            touchCacheFile(outputFile)
            bitmap.recycle()
            return outputFile.absolutePath
        } catch (_: Exception) {
            if (outputFile.exists()) {
                outputFile.delete()
            }
            return null
        } finally {
            try {
                retriever?.release()
            } catch (_: Exception) {
                // Releasing a failed native retriever is best effort.
            }
        }
    }

    private fun selectFrame(
        retriever: MediaMetadataRetriever,
        durationMs: Long
    ): Bitmap? {
        if (durationMs > 3000L) {
            val timestampsUs = listOf(
                durationMs * 300L,
                durationMs * 500L,
                durationMs * 700L,
                durationMs * 150L
            )
            for (timestampUs in timestampsUs) {
                val frame = retriever.getFrameAtTime(
                    timestampUs,
                    MediaMetadataRetriever.OPTION_CLOSEST
                ) ?: continue
                if (!isBlankBitmap(frame)) {
                    return frame
                }
                frame.recycle()
            }
        }

        return retriever.getFrameAtTime(
            1_000_000L,
            MediaMetadataRetriever.OPTION_CLOSEST_SYNC
        ) ?: retriever.frameAtTime
    }

    private fun isBlankBitmap(bitmap: Bitmap): Boolean {
        val width = bitmap.width
        val height = bitmap.height
        if (width == 0 || height == 0) return true

        val stepX = (width / 10).coerceAtLeast(1)
        val stepY = (height / 10).coerceAtLeast(1)
        var darkPixels = 0
        var lightPixels = 0
        var totalSamples = 0

        for (y in 0 until height step stepY) {
            for (x in 0 until width step stepX) {
                val pixel = bitmap.getPixel(x, y)
                val red = (pixel shr 16) and 0xFF
                val green = (pixel shr 8) and 0xFF
                val blue = pixel and 0xFF
                val luminance = (0.299 * red + 0.587 * green + 0.114 * blue).toInt()
                if (luminance < 20) darkPixels++
                if (luminance > 235) lightPixels++
                totalSamples++
            }
        }

        return totalSamples == 0 ||
            darkPixels > totalSamples * 0.95 ||
            lightPixels > totalSamples * 0.95
    }
}
