package com.doujin.audio

import com.doujin.audio.scanner.mediaStoreDirectoryMatches
import com.doujin.audio.scanner.mediaStoreFolderQuery

import android.provider.MediaStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaStoreFolderQueryTest {
    @Test
    fun `android q query scopes relative path to exact folder and descendants`() {
        val query = mediaStoreFolderQuery(
            sdkInt = 29,
            folder = "/storage/emulated/0/Music/Albums",
            primaryExternalStorageRoot = "/storage/emulated/0"
        )

        assertEquals(
            "${MediaStore.Files.FileColumns.RELATIVE_PATH} = ? OR " +
                "${MediaStore.Files.FileColumns.RELATIVE_PATH} LIKE ? ESCAPE '\\'",
            query.selection
        )
        assertEquals(listOf("Music/Albums/", "Music/Albums/%"), query.selectionArgs)
        assertEquals("Music/Albums", query.directoryFilter)
    }

    @Test
    fun `legacy query uses a directory boundary and escapes like metacharacters`() {
        val query = mediaStoreFolderQuery(
            sdkInt = 28,
            folder = "/storage/emulated/0/Music/100%_Hits",
            primaryExternalStorageRoot = "/storage/emulated/0"
        )

        assertEquals(
            "${MediaStore.Files.FileColumns.DATA} LIKE ? ESCAPE '\\'",
            query.selection
        )
        assertEquals(
            listOf("/storage/emulated/0/Music/100\\%\\_Hits/%"),
            query.selectionArgs
        )
    }

    @Test
    fun `root relative path intentionally has no provider selection`() {
        val query = mediaStoreFolderQuery(
            sdkInt = 29,
            folder = "/storage/emulated/0",
            primaryExternalStorageRoot = "/storage/emulated/0"
        )

        assertNull(query.selection)
        assertTrue(query.selectionArgs.isEmpty())
        assertEquals("", query.directoryFilter)
    }

    @Test
    fun `cursor directory recheck rejects same prefix siblings`() {
        assertTrue(mediaStoreDirectoryMatches("Music/Albums", "Music/Albums"))
        assertTrue(mediaStoreDirectoryMatches("Music/Albums/Live", "Music/Albums"))
        assertFalse(mediaStoreDirectoryMatches("Music/Albums2", "Music/Albums"))
    }
}
