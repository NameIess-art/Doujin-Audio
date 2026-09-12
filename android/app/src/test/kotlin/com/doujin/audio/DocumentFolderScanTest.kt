package com.doujin.audio

import android.database.Cursor
import android.provider.DocumentsContract
import com.doujin.audio.scanner.NoopFolderScanObserver
import com.doujin.audio.scanner.ScannedDocument
import com.doujin.audio.scanner.scanDocumentChildren
import java.lang.reflect.Proxy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DocumentFolderScanTest {
    @Test
    fun `empty directory is complete but unavailable query is a failure`() {
        val empty = FakeCursor(emptyList())
        assertEquals(0, scanDocumentChildren({ empty.cursor }, NoopFolderScanObserver) {})
        assertTrue(empty.closed)
        assertEquals(1, scanDocumentChildren({ null }, NoopFolderScanObserver) {})
        assertEquals(1, scanDocumentChildren(
            { throw SecurityException("Permission revoked") }, NoopFolderScanObserver
        ) {})
    }

    @Test
    fun `cursor failure after one child preserves discovery and marks scan incomplete`() {
        val cursor = FakeCursor(listOf(audioRow), failAtRow = 1)
        val discovered = mutableListOf<ScannedDocument>()

        val failures = scanDocumentChildren(
            { cursor.cursor }, NoopFolderScanObserver, discovered::add
        )

        assertEquals(1, failures)
        assertEquals(listOf(ScannedDocument("track", "track.mp3", "audio/mpeg", 42L, 1000L)), discovered)
        assertTrue(cursor.closed)
    }

    @Test
    fun `unreadable child metadata marks scan incomplete`() {
        for (column in 0..2) {
            val row = audioRow.toMutableList().apply { this[column] = null }
            val cursor = FakeCursor(listOf(row))
            val discovered = mutableListOf<ScannedDocument>()

            assertEquals(1, scanDocumentChildren(
                { cursor.cursor }, NoopFolderScanObserver, discovered::add
            ))
            assertTrue(discovered.isEmpty())
            assertTrue(cursor.closed)
        }
    }

    @Test
    fun `directory MIME and optional file metadata come from the same query`() {
        val cursor = FakeCursor(listOf(
            listOf("folder", "Folder", DocumentsContract.Document.MIME_TYPE_DIR, null, null),
            audioRow
        ))
        val discovered = mutableListOf<ScannedDocument>()

        assertEquals(0, scanDocumentChildren(
            { cursor.cursor }, NoopFolderScanObserver, discovered::add
        ))
        assertEquals(ScannedDocument("folder", "Folder", DocumentsContract.Document.MIME_TYPE_DIR, null, null), discovered.first())
        assertEquals(2, discovered.size)
        assertTrue(cursor.closed)
    }

    private val audioRow: List<Any?> = listOf("track", "track.mp3", "audio/mpeg", 42L, 1000L)

    // Cursor is an Android interface; a proxy lets JVM tests simulate provider
    // failures during iteration without adding a framework or device dependency.
    private class FakeCursor(
        private val rows: List<List<Any?>>,
        private val failAtRow: Int? = null
    ) {
        var closed = false
        private var row = -1
        private val columns = listOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED
        )
        val cursor = Proxy.newProxyInstance(
            Cursor::class.java.classLoader, arrayOf(Cursor::class.java)
        ) { _, method, args ->
            when (method.name) {
                "getColumnIndexOrThrow" -> columns.indexOf(args!![0]).also { require(it >= 0) }
                "moveToNext" -> {
                    row++
                    check(row != failAtRow) { "Provider failed during enumeration" }
                    row < rows.size
                }
                "getString" -> rows[row][args!![0] as Int] as String?
                "getLong" -> rows[row][args!![0] as Int] as Long? ?: 0L
                "close" -> { closed = true; null }
                else -> error("Unexpected cursor method: ${method.name}")
            }
        } as Cursor
    }
}
