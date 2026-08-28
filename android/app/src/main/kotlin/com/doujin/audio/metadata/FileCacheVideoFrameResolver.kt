package com.doujin.audio.metadata

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import java.io.File
import java.io.FileOutputStream
import kotlin.math.abs
import kotlin.math.roundToInt

internal const val VIDEO_FRAME_MAX_EDGE_PX = 1200

internal fun videoFrameCacheKey(trackPath: String, modifiedAtMs: Long?): String =
    "$trackPath|${modifiedAtMs ?: 0L}|v3"

internal data class VideoFrameSize(
    val width: Int,
    val height: Int
)

internal fun calculateVideoFrameSize(
    width: Int,
    height: Int,
    maxEdge: Int = VIDEO_FRAME_MAX_EDGE_PX
): VideoFrameSize? {
    if (width <= 0 || height <= 0 || maxEdge <= 0) return null
    val sourceMaxEdge = maxOf(width, height)
    if (sourceMaxEdge <= maxEdge) {
        return VideoFrameSize(width = width, height = height)
    }
    val scale = maxEdge.toDouble() / sourceMaxEdge
    return VideoFrameSize(
        width = (width * scale).roundToInt().coerceAtLeast(1),
        height = (height * scale).roundToInt().coerceAtLeast(1)
    )
}

internal fun shouldDecodeLegacyVideoFrame(
    width: Int?,
    height: Int?,
    maxEdge: Int = VIDEO_FRAME_MAX_EDGE_PX
): Boolean =
    width != null &&
        height != null &&
        width > 0 &&
        height > 0 &&
        maxOf(width, height) <= maxEdge

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
        val cacheKey = videoFrameCacheKey(trackPath, modifiedAtMs)
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
            val sourceWidth = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull()
            val sourceHeight = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull()
            val frameSize = if (sourceWidth != null && sourceHeight != null) {
                calculateVideoFrameSize(sourceWidth, sourceHeight)
            } else {
                null
            }
            if (frameSize == null) return null
            if (
                Build.VERSION.SDK_INT < Build.VERSION_CODES.O_MR1 &&
                !shouldDecodeLegacyVideoFrame(sourceWidth, sourceHeight)
            ) {
                return null
            }

            val bitmap = selectFrame(retriever, durationMs, frameSize) ?: return null
            try {
                FileOutputStream(outputFile).use { output ->
                    check(bitmap.compress(Bitmap.CompressFormat.JPEG, 88, output)) {
                        "Video frame compression failed."
                    }
                    output.flush()
                }
                check(outputFile.length() > 0L) { "Video frame cache is empty." }
                touchCacheFile(outputFile)
                return outputFile.absolutePath
            } finally {
                bitmap.recycle()
            }
        } catch (_: OutOfMemoryError) {
            outputFile.delete()
            return null
        } catch (_: Exception) {
            outputFile.delete()
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
        durationMs: Long,
        frameSize: VideoFrameSize
    ): Bitmap? {
        if (durationMs > 3000L) {
            val timestampsUs = listOf(
                durationMs * 300L,
                durationMs * 500L,
                durationMs * 700L,
                durationMs * 150L
            )
            for (timestampUs in timestampsUs) {
                val frame = frameAtTime(
                    retriever,
                    timestampUs,
                    MediaMetadataRetriever.OPTION_CLOSEST,
                    frameSize
                ) ?: continue
                if (!isBlankBitmap(frame)) {
                    return frame
                }
                frame.recycle()
            }
        }

        return frameAtTime(
            retriever,
            1_000_000L,
            MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            frameSize
        ) ?: frameAtTime(
            retriever,
            0L,
            MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            frameSize
        )
    }

    private fun frameAtTime(
        retriever: MediaMetadataRetriever,
        timestampUs: Long,
        option: Int,
        frameSize: VideoFrameSize
    ): Bitmap? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            retriever.getScaledFrameAtTime(
                timestampUs,
                option,
                frameSize.width,
                frameSize.height
            )
        } else {
            retriever.getFrameAtTime(timestampUs, option)
        }
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
