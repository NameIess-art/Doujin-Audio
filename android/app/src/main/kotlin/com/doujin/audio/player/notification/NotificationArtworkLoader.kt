package com.doujin.audio.player.notification

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.FutureTask
import kotlin.math.max
import kotlin.math.roundToInt

internal fun calculateNotificationInSampleSize(
    width: Int,
    height: Int,
    targetSizePx: Int
): Int {
    if (width <= 0 || height <= 0 || targetSizePx <= 0) return 1
    var sampleSize = 1
    while (max(width / (sampleSize * 2), height / (sampleSize * 2)) >= targetSizePx) {
        sampleSize *= 2
    }
    return sampleSize
}

internal fun shouldRefreshNotificationArtwork(
    requestGeneration: Long,
    currentGeneration: Long,
    loadedPath: String,
    currentArtworkPaths: Iterable<String?>
): Boolean {
    if (requestGeneration != currentGeneration) return false
    return currentArtworkPaths.any { it?.trim() == loadedPath }
}

internal class NotificationArtworkLoader(
    private val targetSizePx: Int,
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "doujin-notification-art").apply { isDaemon = true }
    }
) {
    companion object {
        private const val maxCacheSizeKb = 8 * 1024
        private const val fallbackTargetSizePx = 256
        private const val maximumTargetSizePx = 512

        fun create(context: Context): NotificationArtworkLoader {
            val resources = context.resources
            val widthId = resources.getIdentifier(
                "notification_large_icon_width",
                "dimen",
                "android"
            )
            val heightId = resources.getIdentifier(
                "notification_large_icon_height",
                "dimen",
                "android"
            )
            val width = if (widthId == 0) 0 else resources.getDimensionPixelSize(widthId)
            val height = if (heightId == 0) 0 else resources.getDimensionPixelSize(heightId)
            val target = max(width, height)
                .takeIf { it > 0 }
                ?.coerceAtMost(maximumTargetSizePx)
                ?: fallbackTargetSizePx
            return NotificationArtworkLoader(target)
        }
    }

    private val lock = Any()
    private val cache = object : LruCache<String, Bitmap>(maxCacheSizeKb) {
        override fun sizeOf(key: String, value: Bitmap): Int {
            return ((value.allocationByteCount + 1023) / 1024).coerceAtLeast(1)
        }
    }
    private val pending = mutableMapOf<String, PendingArtworkRequest>()
    private var epoch = 0L

    fun cached(path: String?): Bitmap? {
        val value = path?.trim()?.takeIf(String::isNotEmpty) ?: return null
        return cache.get(value)
    }

    fun request(path: String?, onLoaded: (String) -> Unit) {
        val value = path?.trim()?.takeIf(String::isNotEmpty) ?: return
        if (cache.get(value) != null) return

        val task: FutureTask<Unit>
        synchronized(lock) {
            val existing = pending[value]
            if (existing != null) {
                existing.callbacks.add(onLoaded)
                return
            }
            val requestEpoch = epoch
            lateinit var createdTask: FutureTask<Unit>
            createdTask = FutureTask {
                var bitmap: Bitmap? = null
                try {
                    bitmap = decode(value)
                    if (bitmap == null) return@FutureTask
                    val callbacks = synchronized(lock) {
                        if (epoch != requestEpoch) {
                            emptyList()
                        } else {
                            cache.put(value, bitmap)
                            pending[value]?.callbacks?.toList().orEmpty()
                        }
                    }
                    if (callbacks.isNotEmpty()) {
                        callbacks.forEach { callback ->
                            try {
                                callback(value)
                            } catch (_: Exception) {
                                // One listener must not prevent the remaining refreshes.
                            }
                        }
                    } else {
                        bitmap.recycle()
                    }
                } finally {
                    synchronized(lock) {
                        if (pending[value]?.task === createdTask) {
                            pending.remove(value)
                        }
                    }
                }
            }
            task = createdTask
            pending[value] = PendingArtworkRequest(
                task = task,
                callbacks = mutableListOf(onLoaded)
            )
        }
        executor.execute(task)
    }

    fun clear() {
        val tasks: List<FutureTask<Unit>>
        synchronized(lock) {
            epoch += 1
            tasks = pending.values.map { it.task }
            pending.clear()
            cache.evictAll()
        }
        tasks.forEach { it.cancel(false) }
    }

    private data class PendingArtworkRequest(
        val task: FutureTask<Unit>,
        val callbacks: MutableList<(String) -> Unit>
    )

    private fun decode(path: String): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        val options = BitmapFactory.Options().apply {
            inSampleSize = calculateNotificationInSampleSize(
                bounds.outWidth,
                bounds.outHeight,
                targetSizePx
            )
        }
        val decoded = BitmapFactory.decodeFile(path, options) ?: return null
        val longestEdge = max(decoded.width, decoded.height)
        if (longestEdge <= targetSizePx) return decoded

        val scale = targetSizePx.toFloat() / longestEdge.toFloat()
        val scaled = Bitmap.createScaledBitmap(
            decoded,
            (decoded.width * scale).roundToInt().coerceAtLeast(1),
            (decoded.height * scale).roundToInt().coerceAtLeast(1),
            true
        )
        if (scaled !== decoded) decoded.recycle()
        return scaled
    }
}
