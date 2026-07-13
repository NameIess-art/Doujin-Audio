package com.nameless.audio.storage

import com.nameless.audio.common.*
import com.nameless.audio.metadata.*
import com.nameless.audio.scanner.*
import com.nameless.audio.subtitle.*

import android.content.Context
import android.net.Uri

internal class FileCacheOperations(context: Context) {
    internal val documentStorage = DocumentStorageOperations(context)
    private val folderScan = FolderScanOperations(context, documentStorage)
    private val cachePolicy = ApplicationCachePolicy(context)
    private val mediaMetadata = MediaMetadataOperations(context, documentStorage, cachePolicy)
    private val subtitles = SubtitleOperations(context, documentStorage)
    private val covers = CoverArtworkOperations(context, documentStorage, mediaMetadata, cachePolicy)

    val defaultMaxApplicationCacheBytes: Long
        get() = ApplicationCachePolicy.DEFAULT_MAX_BYTES

    fun cacheFromUri(uri: String, name: String, index: Int): String =
        documentStorage.cacheFromUri(uri, name, index)

    fun scanFolder(folder: String, observer: FolderScanObserver = NoopFolderScanObserver): ScanFolderResult =
        folderScan.scanFolder(folder, observer)

    fun listChildFolders(folder: String): List<String> = documentStorage.listChildFolders(folder)

    fun renameDocumentTarget(path: String, name: String): HashMap<String, String> =
        documentStorage.renameDocumentTarget(path, name)

    fun readAudioDetailBackup(folder: String): String? =
        documentStorage.readAudioDetailBackup(folder)

    fun writeAudioDetailBackup(folder: String, json: String): Boolean =
        documentStorage.writeAudioDetailBackup(folder, json)

    internal fun contentUriToFilePath(uri: String): String? =
        documentStorage.contentUriToFilePath(uri)

    fun readSingleFileDetailBackup(path: String): String? =
        documentStorage.readSingleFileDetailBackup(path)

    fun writeSingleFileDetailBackup(path: String, json: String): Boolean =
        documentStorage.writeSingleFileDetailBackup(path, json)

    fun writeFileBytesToFolder(
        folder: String,
        name: String,
        bytes: ByteArray,
        mimeType: String?
    ): String? {
        val savedUri = documentStorage.writeFileBytesToFolder(folder, name, bytes, mimeType)
            ?: return null
        return covers.cacheUri(Uri.parse(savedUri), name, "$folder/$name")
    }

    fun ensureFolderPath(folder: String, relativePath: String, overwrite: Boolean): Boolean =
        documentStorage.ensureFolderPath(folder, relativePath, overwrite)

    fun documentPathExists(path: String): Boolean = documentStorage.documentPathExists(path)

    fun copyFileToFolder(
        sourcePath: String,
        folder: String,
        relativePath: String,
        overwrite: Boolean
    ): Boolean = documentStorage.copyFileToFolder(sourcePath, folder, relativePath, overwrite)

    fun deleteDocumentPath(path: String): Boolean = documentStorage.deleteDocumentPath(path)

    fun resolveTrackSubtitle(path: String, groupKey: String?): HashMap<String, String>? =
        subtitles.resolve(path, groupKey)

    fun resolveMediaDurationMs(source: String): Long? = mediaMetadata.resolveDurationMs(source)

    fun resolveTrackCover(path: String, groupKey: String?, rootFolder: String?): String? =
        covers.resolve(path, groupKey, rootFolder)

    fun resolveVideoFrame(path: String, modifiedAtMs: Long?): String? =
        mediaMetadata.resolveVideoFrame(path, modifiedAtMs)

    fun discoverRootImages(path: String, groupKey: String?, rootFolder: String?): List<String> =
        covers.discover(path, groupKey, rootFolder)

    fun maxApplicationCacheBytes(): Long = cachePolicy.maxBytes()

    fun setMaxApplicationCacheBytes(maxBytes: Long) =
        cachePolicy.setMaxBytes(maxBytes)

    fun clearApplicationCache(): Long = cachePolicy.clear()

    fun enforceApplicationCacheLimit(maxBytes: Long = maxApplicationCacheBytes()) =
        cachePolicy.enforceLimit(maxBytes)
}
