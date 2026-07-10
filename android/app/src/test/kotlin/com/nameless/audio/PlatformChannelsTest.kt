package com.nameless.audio

import org.junit.Assert.assertEquals
import org.junit.Test

class PlatformChannelsTest {
    @Test
    fun `platform channel names stay unique`() {
        val names = listOf(
            PlatformChannelNames.FILE_CACHE,
            PlatformChannelNames.NATIVE_PLAYBACK,
            PlatformChannelNames.NATIVE_PLAYBACK_EVENTS,
            PlatformChannelNames.NOTIFICATIONS,
            PlatformChannelNames.POWER,
            PlatformChannelNames.SUBTITLE_OVERLAY,
            PlatformChannelNames.UPDATE
        )

        assertEquals(names.size, names.toSet().size)
    }

    @Test
    fun `file cache method names stay unique after handler extraction`() {
        val methods = listOf(
            FileCacheMethods.CACHE_FROM_URI,
            FileCacheMethods.CLEAR_APPLICATION_CACHE,
            FileCacheMethods.COPY_FILE_TO_FOLDER,
            FileCacheMethods.DELETE_DOCUMENT_PATH,
            FileCacheMethods.DISCOVER_ROOT_IMAGES,
            FileCacheMethods.DOCUMENT_PATH_EXISTS,
            FileCacheMethods.ENFORCE_APPLICATION_CACHE_LIMIT,
            FileCacheMethods.ENSURE_FOLDER_PATH,
            FileCacheMethods.LIST_CHILD_FOLDERS,
            FileCacheMethods.PICK_AUDIO_FILES,
            FileCacheMethods.PICK_AUDIO_FOLDER,
            FileCacheMethods.PICK_AUDIO_SOURCE,
            FileCacheMethods.READ_AUDIO_DETAIL_BACKUP,
            FileCacheMethods.READ_SINGLE_FILE_DETAIL_BACKUP,
            FileCacheMethods.RENAME_DOCUMENT,
            FileCacheMethods.RESOLVE_TRACK_COVER,
            FileCacheMethods.RESOLVE_TRACK_SUBTITLE,
            FileCacheMethods.RESOLVE_VIDEO_FRAME,
            FileCacheMethods.SCAN_FOLDER,
            FileCacheMethods.START_FOLDER_SCAN,
            FileCacheMethods.CANCEL_FOLDER_SCAN,
            FileCacheMethods.SET_APPLICATION_CACHE_LIMIT,
            FileCacheMethods.WRITE_AUDIO_DETAIL_BACKUP,
            FileCacheMethods.WRITE_FILE_BYTES_TO_FOLDER,
            FileCacheMethods.WRITE_SINGLE_FILE_DETAIL_BACKUP
        )

        assertEquals(methods.size, methods.toSet().size)
    }

    @Test
    fun `critical method names remain protocol compatible`() {
        assertEquals("prepareSession", NativePlaybackMethods.PREPARE_SESSION)
        assertEquals("snapshot", NativePlaybackMethods.SNAPSHOT)
        assertEquals("startFolderScan", FileCacheMethods.START_FOLDER_SCAN)
        assertEquals("cancelFolderScan", FileCacheMethods.CANCEL_FOLDER_SCAN)
        assertEquals(
            "syncUnifiedPlaybackNotifications",
            NotificationsMethods.SYNC_UNIFIED_PLAYBACK_NOTIFICATIONS
        )
        assertEquals("getAppVersion", UpdateMethods.GET_APP_VERSION)
        assertEquals(
            "getBackgroundRunDiagnostics",
            PowerMethods.GET_BACKGROUND_RUN_DIAGNOSTICS
        )
        assertEquals("installApk", UpdateMethods.INSTALL_APK)
        assertEquals("openReleasePage", UpdateMethods.OPEN_RELEASE_PAGE)
    }
}
