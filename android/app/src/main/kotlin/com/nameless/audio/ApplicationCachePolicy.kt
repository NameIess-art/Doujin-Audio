package com.nameless.audio

import android.content.Context
import java.io.File

internal fun shouldEvictApplicationCacheEntry(
    totalBytes: Long,
    maxBytes: Long,
    remainingFiles: Int
): Boolean {
    return totalBytes > maxBytes && remainingFiles > 1
}

internal class ApplicationCachePolicy(
    private val context: Context
) {
    companion object {
        const val DEFAULT_MAX_BYTES: Long = 300L * 1024L * 1024L

        private const val PREFS_NAME = "app_cache_policy"
        private const val MAX_CACHE_BYTES_KEY = "max_cache_bytes"
    }

    fun maxBytes(): Long {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getLong(MAX_CACHE_BYTES_KEY, DEFAULT_MAX_BYTES)
            .coerceAtLeast(1L)
    }

    fun setMaxBytes(maxBytes: Long) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putLong(MAX_CACHE_BYTES_KEY, maxBytes.coerceAtLeast(1L))
            .apply()
    }

    fun clear(): Long {
        var deletedBytes = 0L
        roots().forEach { root ->
            if (!root.exists()) return@forEach
            root.listFiles()?.forEach { child ->
                deletedBytes += deleteEntity(child)
            }
        }
        return deletedBytes.coerceAtMost(Int.MAX_VALUE.toLong())
    }

    fun enforceLimit(maxBytes: Long = maxBytes()) {
        val files = roots()
            .filter(File::exists)
            .flatMap(::collectFiles)
            .distinctBy(File::getAbsolutePath)
        var totalBytes = files.sumOf { file -> file.length().coerceAtLeast(0L) }
        var remainingFiles = files.size
        files.sortedBy(File::lastModified).forEach { file ->
            if (!shouldEvictApplicationCacheEntry(totalBytes, maxBytes, remainingFiles)) {
                return@forEach
            }
            val size = file.length().coerceAtLeast(0L)
            try {
                if (file.delete()) {
                    totalBytes -= size
                    remainingFiles -= 1
                }
            } catch (_: Exception) {
                // Cache eviction is best effort and must not interrupt playback.
            }
        }
        roots().forEach(::deleteEmptyDirectories)
    }

    fun touch(file: File) {
        try {
            file.setLastModified(System.currentTimeMillis())
        } catch (_: Exception) {
            // Cache recency is best effort; the file remains usable without it.
        }
    }

    private fun roots(): List<File> {
        return listOfNotNull(context.cacheDir, context.externalCacheDir)
    }

    private fun collectFiles(root: File): List<File> {
        val children = root.listFiles() ?: return emptyList()
        val result = mutableListOf<File>()
        children.forEach { child ->
            if (child.isDirectory) {
                result.addAll(collectFiles(child))
            } else if (child.isFile) {
                result.add(child)
            }
        }
        return result
    }

    private fun deleteEntity(entity: File): Long {
        val size = entitySize(entity)
        try {
            if (entity.isDirectory) {
                entity.deleteRecursively()
            } else {
                entity.delete()
            }
        } catch (_: Exception) {
            // Clearing cache is best effort and reports only successfully removed bytes.
        }
        return if (entity.exists()) 0L else size
    }

    private fun entitySize(entity: File): Long {
        return try {
            if (entity.isFile) {
                entity.length().coerceAtLeast(0L)
            } else {
                entity.listFiles()?.sumOf(::entitySize) ?: 0L
            }
        } catch (_: Exception) {
            // Unreadable cache entries are ignored during size accounting.
            0L
        }
    }

    private fun deleteEmptyDirectories(root: File) {
        root.listFiles()?.forEach { child ->
            if (child.isDirectory) {
                deleteEmptyDirectories(child)
                if (child.listFiles()?.isEmpty() == true) {
                    try {
                        child.delete()
                    } catch (_: Exception) {
                        // Empty-directory cleanup is best effort.
                    }
                }
            }
        }
    }
}
