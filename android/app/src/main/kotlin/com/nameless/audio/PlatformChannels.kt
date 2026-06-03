package com.nameless.audio

internal object PlatformChannelNames {
    const val FILE_CACHE = "nameless_audio/file_cache"
    const val FILE_CACHE_SCAN_EVENTS = "nameless_audio/file_cache/scan_events"
    const val NATIVE_PLAYBACK = "nameless_audio/native_playback"
    const val NATIVE_PLAYBACK_EVENTS = "nameless_audio/native_playback/events"
    const val NOTIFICATIONS = "nameless_audio/notifications"
    const val POWER = "nameless_audio/power"
    const val SUBTITLE_OVERLAY = "nameless_audio/subtitle_overlay"
    const val UPDATE = "nameless_audio/update"
}

internal object NativePlaybackMethods {
    const val PREPARE_SESSION = "prepareSession"
    const val PLAY = "play"
    const val PAUSE = "pause"
    const val STOP = "stop"
    const val SEEK = "seek"
    const val SET_VOLUME = "setVolume"
    const val SET_SPEED = "setSpeed"
    const val SET_REPEAT_ONE = "setRepeatOne"
    const val SET_CHANNEL_SWAP = "setChannelSwap"
    const val REMOVE_SESSION = "removeSession"
    const val PAUSE_ALL = "pauseAll"
    const val CLEAR_ALL = "clearAll"
    const val SET_FOREGROUND_ENABLED = "setForegroundEnabled"
    const val DISMISS_NOTIFICATIONS = "dismissNotifications"
    const val UNDISMISS_NOTIFICATIONS = "undismissNotifications"
    const val SNAPSHOT = "snapshot"
}

internal object PowerMethods {
    const val CAN_MANAGE_ALL_FILES_ACCESS = "canManageAllFilesAccess"
    const val CAN_SCHEDULE_EXACT_ALARMS = "canScheduleExactAlarms"
    const val EXECUTE_AUTO_RESUME_NOW = "executeAutoResumeNow"
    const val EXECUTE_TIMER_EXPIRED_NOW = "executeTimerExpiredNow"
    const val GET_NATIVE_TIMER_RUNTIME_STATE = "getNativeTimerRuntimeState"
    const val IS_IGNORING_BATTERY_OPTIMIZATIONS = "isIgnoringBatteryOptimizations"
    const val OPEN_BACKGROUND_RUN_SETTINGS = "openBackgroundRunSettings"
    const val OPEN_BATTERY_OPTIMIZATION_SETTINGS = "openBatteryOptimizationSettings"
    const val OPEN_EXACT_ALARM_SETTINGS = "openExactAlarmSettings"
    const val OPEN_MANAGE_ALL_FILES_ACCESS_SETTINGS = "openManageAllFilesAccessSettings"
    const val SET_KEEP_CPU_AWAKE = "setKeepCpuAwake"
    const val STOP_PLAYBACK_KEEP_ALIVE = "stopPlaybackKeepAlive"
    const val SYNC_PLAYBACK_TIMER_ALARMS = "syncPlaybackTimerAlarms"
}

internal object UpdateMethods {
    const val CAN_INSTALL_UNKNOWN_APPS = "canInstallUnknownApps"
    const val GET_APP_VERSION = "getAppVersion"
    const val INSTALL_APK = "installApk"
    const val OPEN_INSTALL_PERMISSION_SETTINGS = "openInstallPermissionSettings"
}

internal object SubtitleOverlayMethods {
    const val CAN_DRAW_OVERLAYS = "canDrawOverlays"
    const val OPEN_OVERLAY_SETTINGS = "openOverlaySettings"
    const val START_OVERLAY = "startOverlay"
    const val STOP_OVERLAY = "stopOverlay"
    const val UPDATE_STYLE = "updateStyle"
    const val UPDATE_SUBTITLE = "updateSubtitle"
}

internal object NotificationsMethods {
    const val ARE_NOTIFICATIONS_ENABLED = "areNotificationsEnabled"
    const val CLEAR_UNIFIED_PLAYBACK_NOTIFICATIONS = "clearUnifiedPlaybackNotifications"
    const val CONSUME_PENDING_NOTIFICATION_SESSION_ID = "consumePendingNotificationSessionId"
    const val OPEN_NOTIFICATION_SETTINGS = "openNotificationSettings"
    const val OPEN_SESSION_FROM_NOTIFICATION = "openSessionFromNotification"
    const val SYNC_UNIFIED_PLAYBACK_NOTIFICATIONS = "syncUnifiedPlaybackNotifications"
}

internal object FileCacheMethods {
    const val CACHE_FROM_URI = "cacheFromUri"
    const val CLEAR_APPLICATION_CACHE = "clearApplicationCache"
    const val COPY_FILE_TO_FOLDER = "copyFileToFolder"
    const val DELETE_DOCUMENT_PATH = "deleteDocumentPath"
    const val DISCOVER_ROOT_IMAGES = "discoverRootImages"
    const val DOCUMENT_PATH_EXISTS = "documentPathExists"
    const val ENFORCE_APPLICATION_CACHE_LIMIT = "enforceApplicationCacheLimit"
    const val ENSURE_FOLDER_PATH = "ensureFolderPath"
    const val LIST_CHILD_FOLDERS = "listChildFolders"
    const val PICK_AUDIO_FILES = "pickAudioFiles"
    const val PICK_AUDIO_FOLDER = "pickAudioFolder"
    const val PICK_AUDIO_SOURCE = "pickAudioSource"
    const val READ_AUDIO_DETAIL_BACKUP = "readAudioDetailBackup"
    const val READ_SINGLE_FILE_DETAIL_BACKUP = "readSingleFileDetailBackup"
    const val RENAME_DOCUMENT = "renameDocument"
    const val RESOLVE_TRACK_COVER = "resolveTrackCover"
    const val RESOLVE_TRACK_SUBTITLE = "resolveTrackSubtitle"
    const val RESOLVE_VIDEO_FRAME = "resolveVideoFrame"
    const val SCAN_FOLDER = "scanFolder"
    const val START_FOLDER_SCAN = "startFolderScan"
    const val CANCEL_FOLDER_SCAN = "cancelFolderScan"
    const val SET_APPLICATION_CACHE_LIMIT = "setApplicationCacheLimit"
    const val WRITE_AUDIO_DETAIL_BACKUP = "writeAudioDetailBackup"
    const val WRITE_FILE_BYTES_TO_FOLDER = "writeFileBytesToFolder"
    const val WRITE_SINGLE_FILE_DETAIL_BACKUP = "writeSingleFileDetailBackup"
}
