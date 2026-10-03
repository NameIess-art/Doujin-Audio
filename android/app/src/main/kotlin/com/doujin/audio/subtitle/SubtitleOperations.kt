package com.doujin.audio.subtitle

import com.doujin.audio.metadata.MediaNameMetadata
import com.doujin.audio.storage.*
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.io.File
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.util.Locale

private val subtitleExtensions = setOf("vtt", "webvtt", "lrc", "srt", "ass", "ssa", "txt")
private val mediaExtensions = setOf(
    "mp3", "aac", "m4a", "ogg", "oga", "opus", "wav", "flac",
    "mp4", "mkv", "webm", "mov", "m4v", "avi", "3gp"
)

internal class SubtitleExistsException : IOException("A subtitle already exists for this track.")

private fun subtitleStem(name: String): String {
    var current = MediaNameMetadata.normalizeDisplayName(name).lowercase(Locale.US)
    while (current.contains('.')) {
        val extension = current.substringAfterLast('.')
        if (extension !in subtitleExtensions && extension !in mediaExtensions) break
        current = current.substringBeforeLast('.')
    }
    return current
}

internal fun subtitleMatchRank(audioName: String, subtitleName: String): Int {
    if (subtitleName.substringAfterLast('.', "").lowercase(Locale.US) !in subtitleExtensions) return 10
    val audioStem = subtitleStem(audioName)
    val subtitleStem = subtitleStem(subtitleName)
    return when {
        subtitleStem == audioStem -> 0
        subtitleStem.startsWith("$audioStem.") -> 1
        subtitleStem.startsWith("${audioStem}_") -> 2
        subtitleStem.startsWith("$audioStem ") -> 3
        else -> 10
    }
}

internal fun subtitleDestinationName(audioName: String, extension: String): String {
    require(extension.startsWith('.') && extension.drop(1).lowercase(Locale.US) in subtitleExtensions) {
        "Unsupported subtitle extension: $extension"
    }
    return audioName.substringBeforeLast('.', audioName) + extension.lowercase(Locale.US)
}

internal fun saveLocalTrackSubtitle(
    trackPath: String, extension: String, bytes: ByteArray, sourcePath: String?, overwrite: Boolean,
    deleteSource: (String) -> Boolean = { File(it).delete() },
    sameSource: (String, String) -> Boolean = { first, second ->
        !first.startsWith("content://") && !second.startsWith("content://") &&
            File(first).canonicalFile == File(second).canonicalFile
    }
): String {
    val track = File(trackPath)
    if (!track.isFile) throw IOException("Audio file does not exist: $trackPath")
    val siblings = track.parentFile?.listFiles()?.filter { it.isFile }
        ?: throw IOException("Cannot read audio directory")
    val matching = siblings.filter { subtitleMatchRank(track.name, it.name) < 10 }
        .sortedWith(compareBy<File> { subtitleMatchRank(track.name, it.name) }.thenBy { it.name.lowercase(Locale.US) })
    val name = subtitleDestinationName(track.name, extension)
    val target = siblings.firstOrNull { it.name.equals(name, ignoreCase = true) } ?: File(track.parentFile, name)
    if (sourcePath != null && sameSource(sourcePath, target.absolutePath)) {
        return target.absolutePath
    }
    if (sourcePath != null && matching.isNotEmpty() && !overwrite) throw SubtitleExistsException()
    val saved = replaceSafDocument(
        targetName = target.name, existing = target.takeIf { it.exists() }, staleBackup = null,
        createTemp = { File.createTempFile("subtitle_", ".part", track.parentFile) },
        writeTemp = { it.writeBytes(bytes); true },
        isValidCommitted = { sourcePath == null || deleteSource(sourcePath) },
        rename = { file, newName -> File(file.parentFile, newName).takeIf { file.renameTo(it) } },
        delete = { it.delete() }
    ) ?: throw IOException("Cannot save subtitle")
    val replaced = matching.take(1) + matching.filter { subtitleMatchRank(track.name, it.name) == 0 }
    for (old in replaced.distinct()) {
        if (old.canonicalFile == saved.canonicalFile || (sourcePath != null && sameSource(old.absolutePath, sourcePath))) continue
        if (!old.delete()) throw IOException("Cannot remove replaced subtitle: ${old.name}")
    }
    return saved.absolutePath
}

internal class SubtitleOperations(private val context: Context, private val storage: DocumentStorageOperations) {
    fun resolve(trackPath: String, groupKey: String?): HashMap<String, String>? {
        if (!trackPath.startsWith("content://")) return resolveFile(trackPath)
        return try { resolveDocument(trackPath, groupKey) } catch (_: Exception) { null }
            ?: storage.contentUriToFilePath(trackPath)?.let(::resolveFile)
    }

    private fun documentTrackFolder(trackPath: String, groupKey: String?): Pair<Uri, String> {
        val rootString = when {
            !groupKey.isNullOrBlank() && groupKey.startsWith("content://") -> groupKey.substringBefore("::")
            else -> trackPath.substringBefore("/document/", trackPath)
        }
        val rootUri = Uri.parse(rootString)
        val trackUri = storage.resolveDocumentUri(trackPath) ?: throw IOException("Cannot resolve audio document")
        val trackId = DocumentsContract.getDocumentId(trackUri)
        val parentId = trackId.substringBeforeLast('/', DocumentsContract.getTreeDocumentId(rootUri))
        val parent = DocumentsContract.buildDocumentUriUsingTree(rootUri, parentId)
        // Verify the inferred parent; opaque IDs outside the root cannot be guessed safely.
        if (listReadableDirectoryDocuments(context, parent).none { DocumentsContract.getDocumentId(it.uri) == trackId }) {
            throw IOException("Cannot locate audio parent directory")
        }
        val projection = arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        val name = context.contentResolver.query(trackUri, projection, null, null, null)?.use {
            if (!it.moveToFirst()) null else it.getString(it.getColumnIndexOrThrow(projection[0]))
        } ?: throw IOException("Cannot read audio document name")
        return parent to name
    }

    private fun matches(folder: Uri, audioName: String): List<DirectoryDocument> =
        listReadableDirectoryDocuments(context, folder)
            .filter { it.mime != DocumentsContract.Document.MIME_TYPE_DIR && subtitleMatchRank(audioName, it.name) < 10 }
            .sortedWith(compareBy<DirectoryDocument> { subtitleMatchRank(audioName, it.name) }.thenBy { it.name.lowercase(Locale.US) })

    private fun resolveDocument(trackPath: String, groupKey: String?): HashMap<String, String>? {
        val (folder, audioName) = documentTrackFolder(trackPath, groupKey)
        val best = matches(folder, audioName).firstOrNull() ?: return null
        val text = context.contentResolver.openInputStream(best.uri)
            ?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() } ?: return null
        return result(best.uri.toString(), best.name, text)
    }

    private fun resolveFile(trackPath: String): HashMap<String, String>? {
        val track = File(trackPath)
        val best = track.parentFile?.listFiles()?.filter { it.isFile && subtitleMatchRank(track.name, it.name) < 10 }
            ?.minWithOrNull(compareBy<File> { subtitleMatchRank(track.name, it.name) }.thenBy { it.name.lowercase(Locale.US) })
            ?: return null
        val text = try { best.readText(StandardCharsets.UTF_8) } catch (_: Exception) { return null }
        return result(best.absolutePath, best.name, text)
    }

    fun write(trackPath: String, groupKey: String?, extension: String, bytes: ByteArray, sourcePath: String?, overwrite: Boolean): String {
        if (!trackPath.startsWith("content://")) {
            return saveLocalTrackSubtitle(trackPath, extension, bytes, sourcePath, overwrite, ::deleteSource, ::sameDocument)
        }
        val (folder, audioName) = documentTrackFolder(trackPath, groupKey)
        val matching = matches(folder, audioName)
        val name = subtitleDestinationName(audioName, extension)
        val existing = matching.firstOrNull { it.name.equals(name, ignoreCase = true) }
        if (sourcePath != null && existing != null && sameDocument(sourcePath, existing.uri.toString())) {
            return existing.uri.toString()
        }
        if (sourcePath != null && matching.isNotEmpty() && !overwrite) throw SubtitleExistsException()
        val saved = storage.writeFileBytesToDocumentFolder(folder, existing?.name ?: name, bytes, "text/plain") {
            sourcePath == null || sameDocument(sourcePath, it) || deleteSource(sourcePath)
        }
            ?: throw IOException("Cannot save subtitle")
        val replaced = matching.take(1) + matching.filter { subtitleMatchRank(audioName, it.name) == 0 }
        for (old in replaced.distinctBy { it.uri }) {
            val oldPath = old.uri.toString()
            if (sameDocument(oldPath, saved) || old == existing || (sourcePath != null && sameDocument(oldPath, sourcePath))) continue
            if (!storage.deleteDocumentPath(oldPath)) throw IOException("Cannot remove replaced subtitle")
        }
        return saved
    }

    private fun deleteSource(path: String): Boolean =
        if (path.startsWith("content://")) storage.deleteDocumentPath(path) else File(path).delete()

    private fun sameDocument(first: String, second: String): Boolean {
        if (first == second) return true
        if (!first.startsWith("content://") || !second.startsWith("content://")) {
            val firstPath = if (first.startsWith("content://")) storage.contentUriToFilePath(first) ?: return false else first
            val secondPath = if (second.startsWith("content://")) storage.contentUriToFilePath(second) ?: return false else second
            return File(firstPath).canonicalFile == File(secondPath).canonicalFile
        }
        val firstUri = Uri.parse(first)
        val secondUri = Uri.parse(second)
        if (!DocumentsContract.isDocumentUri(context, firstUri) || !DocumentsContract.isDocumentUri(context, secondUri)) return false
        return firstUri.authority == secondUri.authority &&
            DocumentsContract.getDocumentId(firstUri) == DocumentsContract.getDocumentId(secondUri)
    }

    private fun result(source: String, name: String, text: String): HashMap<String, String> =
        hashMapOf("sourcePath" to source, "extension" to name.substringAfterLast('.').lowercase(Locale.US), "text" to text)
}
