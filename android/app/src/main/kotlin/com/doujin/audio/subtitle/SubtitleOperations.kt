package com.doujin.audio.subtitle

import com.doujin.audio.metadata.*
import com.doujin.audio.storage.*

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.io.File
import java.nio.charset.StandardCharsets
import java.util.Locale

internal class SubtitleOperations(
    private val context: Context,
    private val storage: DocumentStorageOperations
) {
    private val supportedExtensions = setOf("vtt", "webvtt", "lrc", "srt", "ass", "ssa")
    private val mediaExtensions = setOf(
        "mp3", "aac", "m4a", "ogg", "oga", "opus", "wav", "flac",
        "mp4", "mkv", "webm", "mov", "m4v", "avi", "3gp"
    )

    fun resolve(trackPath: String, groupKey: String?): HashMap<String, String>? {
        if (!trackPath.startsWith("content://")) return resolveFile(trackPath)
        return resolveDocument(trackPath, groupKey)
            ?: storage.contentUriToFilePath(trackPath)?.let(::resolveFile)
    }

    private fun resolveDocument(trackPath: String, groupKey: String?): HashMap<String, String>? {
        val rootString = when {
            !groupKey.isNullOrBlank() && groupKey.contains("::") -> groupKey.substringBefore("::")
            !groupKey.isNullOrBlank() && groupKey.startsWith("content://") -> groupKey
            else -> trackPath.substringBefore("/document/", trackPath)
        }
        val rootUri = Uri.parse(rootString)
        val trackUri = Uri.parse(trackPath)
        val trackId = documentId(trackUri) ?: return null
        val parentId = trackId.substringBeforeLast('/', documentId(rootUri) ?: return null)
        val audioStem = matchStem(trackId.substringAfterLast('/'))
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(rootUri, parentId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE
        )
        val candidates = mutableListOf<SubtitleCandidate>()
        try {
            context.contentResolver.query(children, projection, null, null, null)?.use { cursor ->
                val idColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                if (idColumn < 0 || mimeColumn < 0) return null
                while (cursor.moveToNext()) {
                    val id = cursor.getString(idColumn) ?: continue
                    val mime = cursor.getString(mimeColumn)
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) continue
                    val name = MediaNameMetadata.normalizeDisplayName(
                        if (nameColumn >= 0) cursor.getString(nameColumn).orEmpty() else id.substringAfterLast('/')
                    )
                    if (!isSubtitle(name, mime)) continue
                    candidates += SubtitleCandidate(
                        rank = rank(audioStem, matchStem(name)),
                        name = name,
                        source = DocumentsContract.buildDocumentUriUsingTree(rootUri, id).toString()
                    )
                }
            }
        } catch (_: Exception) {
            return null
        }
        val best = candidates.filter { it.rank < 10 }.minWithOrNull(
            compareBy<SubtitleCandidate> { it.rank }.thenBy { it.name.lowercase(Locale.US) }
        ) ?: return null
        val text = try {
            context.contentResolver.openInputStream(Uri.parse(best.source))
                ?.bufferedReader(StandardCharsets.UTF_8)
                ?.use { it.readText() }
        } catch (_: Exception) {
            null
        } ?: return null
        return result(best.source, best.name, text)
    }

    private fun resolveFile(trackPath: String): HashMap<String, String>? {
        val track = File(trackPath)
        val siblings = track.parentFile?.listFiles() ?: return null
        val audioStem = matchStem(track.name)
        val best = siblings.asSequence()
            .filter { it.isFile && isSubtitle(it.name, null) }
            .map { SubtitleCandidate(rank(audioStem, matchStem(it.name)), it.name, it.absolutePath) }
            .filter { it.rank < 10 }
            .minWithOrNull(compareBy<SubtitleCandidate> { it.rank }.thenBy { it.name.lowercase(Locale.US) })
            ?: return null
        val text = try {
            File(best.source).readText(StandardCharsets.UTF_8)
        } catch (_: Exception) {
            return null
        }
        return result(best.source, best.name, text)
    }

    private fun result(source: String, name: String, text: String): HashMap<String, String>? {
        val extension = name.substringAfterLast('.', "").lowercase(Locale.US)
        if (extension.isBlank()) return null
        return hashMapOf("sourcePath" to source, "extension" to extension, "text" to text)
    }

    private fun documentId(uri: Uri): String? = try {
        when {
            DocumentsContract.isDocumentUri(context, uri) -> DocumentsContract.getDocumentId(uri)
            DocumentsContract.isTreeUri(uri) -> DocumentsContract.getTreeDocumentId(uri)
            else -> null
        }
    } catch (_: Exception) {
        null
    }

    private fun isSubtitle(name: String, mime: String?): Boolean {
        val normalizedMime = mime?.lowercase(Locale.US)
        if (normalizedMime in setOf("text/vtt", "application/x-subrip", "text/plain")) return true
        return name.substringAfterLast('.', "").lowercase(Locale.US) in supportedExtensions
    }

    private fun matchStem(name: String): String {
        var current = MediaNameMetadata.normalizeDisplayName(name).lowercase(Locale.US)
        while (current.contains('.')) {
            val extension = current.substringAfterLast('.')
            if (extension !in supportedExtensions && extension !in mediaExtensions) break
            current = current.substringBeforeLast('.')
        }
        return current
    }

    private fun rank(audioStem: String, subtitleStem: String): Int = when {
        subtitleStem == audioStem -> 0
        subtitleStem.startsWith("$audioStem.") -> 1
        subtitleStem.startsWith("${audioStem}_") -> 2
        subtitleStem.startsWith("$audioStem ") -> 3
        else -> 10
    }

    private data class SubtitleCandidate(val rank: Int, val name: String, val source: String)
}
