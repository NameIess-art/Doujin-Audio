package com.nameless.audio

import android.app.Activity
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.ContentUris
import android.content.Intent
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.PowerManager
import android.os.SystemClock
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.graphics.Bitmap
import android.util.LruCache
import android.webkit.MimeTypeMap
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.documentfile.provider.DocumentFile
import androidx.media.app.NotificationCompat.MediaStyle
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.ArrayDeque
import java.util.Locale

private data class SubtitleOverlayStyle(
    val fontSize: Float,
    val backgroundColor: String,
    val textColor: String
)

private object PlaybackWakeLockController {
    private var wakeLock: PowerManager.WakeLock? = null

    @Synchronized
    fun sync(context: Context, enabled: Boolean) {
        if (enabled) {
            acquire(context.applicationContext)
        } else {
            release()
        }
    }

    private fun acquire(context: Context) {
        if (wakeLock?.isHeld == true) return
        try {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            wakeLock = powerManager?.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "${context.packageName}:playback_keep_alive"
            )?.apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
            wakeLock = null
        }
    }

    private fun release() {
        val currentWakeLock = wakeLock ?: return
        try {
            if (currentWakeLock.isHeld) {
                currentWakeLock.release()
            }
        } catch (_: RuntimeException) {
            // Ignore stale wakelock state.
        } finally {
            wakeLock = null
        }
    }
}

internal object PlaybackKeepAlivePolicy {
    fun shouldRunKeepAliveService(
        keepForegroundServiceAlive: Boolean,
        hasActiveTimer: Boolean,
        hasActivePlayback: Boolean
    ): Boolean {
        return keepForegroundServiceAlive && hasActiveTimer && !hasActivePlayback
    }

    fun shouldHoldKeepAliveWakeLock(
        enabled: Boolean,
        hasActiveTimer: Boolean,
        hasActivePlayback: Boolean
    ): Boolean {
        return enabled && (hasActiveTimer || hasActivePlayback)
    }
}

private val supportedImageExtensions = setOf(
    "jpg", "jpeg", "png", "webp", "bmp", "gif"
)

private val supportedSubtitleExtensions = setOf(
    "vtt", "webvtt", "lrc", "srt", "ass", "ssa"
)

private val subtitleMatchMediaExtensions = setOf(
    "mp3", "aac", "m4a", "ogg", "oga", "opus", "wav", "flac",
    "mp4", "mkv", "webm", "mov", "m4v", "avi", "3gp"
)

private val supportedVideoExtensions = setOf(
    "mp4", "mkv", "webm", "mov", "m4v", "avi", "3gp"
)

private val preferredCoverBasenames = listOf(
    "cover", "folder", "front", "album", "artwork", "poster"
)

private const val audioDetailBackupFileName = "nameless-audio.json"
private const val legacyAudioDetailBackupFileName = ".nameless-audio.json"

class MainActivity : AudioServiceActivity() {
    companion object {
        const val notificationSessionIdExtra = "notificationSessionId"
        const val openSessionFromNotificationAction =
            "com.nameless.audio.OPEN_SESSION_FROM_NOTIFICATION"
    }

    private val fileCacheChannel = "nameless_audio/file_cache"
    private val powerChannel = "nameless_audio/power"
    private val notificationsChannel = "nameless_audio/notifications"
    private val nativePlaybackMethodsChannel = "nameless_audio/native_playback"
    private val nativePlaybackEventsChannel = "nameless_audio/native_playback/events"
    private val updateChannel = "nameless_audio/update"
    private val subtitleOverlayChannel = "nameless_audio/subtitle_overlay"
    private val pickAudioSourceRequestCode = 7001
    private val pickAudioFilesRequestCode = 7002
    private val pickAudioFolderRequestCode = 7003
    private var pendingPickAudioRequest: PendingPickAudioRequest? = null
    private var notificationsMethodChannel: MethodChannel? = null
    private var subtitleOverlayService: SubtitleOverlayService? = null
    private var isSubtitleServiceBound = false
    private var pendingSubtitleOverlayText: String? = null
    private var pendingSubtitleOverlayStyle: SubtitleOverlayStyle? = null
    private var pendingNotificationSessionId: String? = null
    private val audioPickerMimeTypes = arrayOf(
        "audio/*",
        "video/*",
        "application/ogg",
        "audio/ogg",
        "audio/flac",
        "audio/x-flac",
        "audio/wav",
        "audio/x-wav",
        "audio/mpeg",
        "audio/mp4",
        "audio/aac",
        "audio/x-m4a",
        "audio/3gpp",
        "audio/opus",
        "video/mp4",
        "video/x-matroska",
        "video/webm",
        "video/quicktime",
        "video/x-msvideo",
        "video/3gpp"
    )
    private val blockedExtensions = setOf(
        "vtt", "srt", "ass", "ssa", "lrc", "txt", "md", "json", "xml",
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif",
        "pdf", "zip", "rar", "7z", "tar", "gz", "doc", "docx"
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val nativePlaybackBridge = NativePlaybackBridge(applicationContext)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            nativePlaybackMethodsChannel
        ).setMethodCallHandler(nativePlaybackBridge)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            nativePlaybackEventsChannel
        ).setStreamHandler(nativePlaybackBridge)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, powerChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setKeepCpuAwake" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val hasActivePlayback =
                            call.argument<Boolean>("hasActivePlayback") ?: false
                        val hasActiveTimer =
                            call.argument<Boolean>("hasActiveTimer") ?: false
                        val usesUnifiedPlaybackNotifications =
                            call.argument<Boolean>("usesUnifiedPlaybackNotifications") ?: false
                        val keepForegroundServiceAlive =
                            call.argument<Boolean>("keepForegroundServiceAlive") ?: false
                        syncPlaybackKeepAlive(
                            enabled = enabled,
                            hasActivePlayback = hasActivePlayback,
                            hasActiveTimer = hasActiveTimer,
                            usesUnifiedPlaybackNotifications = usesUnifiedPlaybackNotifications,
                            keepForegroundServiceAlive = keepForegroundServiceAlive
                        )
                        result.success(null)
                    }
                    "canManageAllFilesAccess" -> {
                        result.success(canManageAllFilesAccess())
                    }
                    "openManageAllFilesAccessSettings" -> {
                        result.success(openManageAllFilesAccessSettings())
                    }
                    "stopPlaybackKeepAlive" -> {
                        stopPlaybackKeepAliveService()
                        result.success(null)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        result.success(isIgnoringBatteryOptimizations())
                    }
                    "openBatteryOptimizationSettings" -> {
                        result.success(openBatteryOptimizationSettings())
                    }
                    "openBackgroundRunSettings" -> {
                        result.success(openBackgroundRunSettings())
                    }
                    "canScheduleExactAlarms" -> {
                        result.success(canScheduleExactAlarms())
                    }
                    "openExactAlarmSettings" -> {
                        result.success(openExactAlarmSettings())
                    }
                    "getNativeTimerRuntimeState" -> {
                        result.success(getNativeTimerRuntimeState())
                    }
                    "executeTimerExpiredNow" -> {
                        val generation = call.argument<Int>("generation")
                        PlaybackTimerAlarmScheduler.executeNow(
                            applicationContext,
                            PlaybackTimerAlarmScheduler.actionTimerExpired,
                            generation
                        )
                        result.success(true)
                    }
                    "executeAutoResumeNow" -> {
                        val generation = call.argument<Int>("generation")
                        PlaybackTimerAlarmScheduler.executeNow(
                            applicationContext,
                            PlaybackTimerAlarmScheduler.actionAutoResume,
                            generation
                        )
                        result.success(true)
                    }
                    "syncPlaybackTimerAlarms" -> {
                        val timerModeIndex = call.argument<Int>("timerMode")
                        val timerDurationMs =
                            (call.argument<Number>("timerDurationMs"))?.toLong()
                        val timerWaitingForPlayback =
                            call.argument<Boolean>("timerWaitingForPlayback") ?: false
                        val timerEndsAtWallClockMs =
                            call.argument<Long>("timerEndsAtWallClockMs")
                        val autoResumeEnabled =
                            call.argument<Boolean>("autoResumeEnabled") ?: false
                        val autoResumeHour = call.argument<Int>("autoResumeHour") ?: 7
                        val autoResumeMinute = call.argument<Int>("autoResumeMinute") ?: 0
                        val autoResumeAtMs = call.argument<Long>("autoResumeAtMs")
                        val pausedSessionIds =
                            call.argument<List<String>>("pausedSessionIds") ?: emptyList()
                        val generation = call.argument<Int>("generation") ?: 0
                        PlaybackTimerAlarmScheduler.sync(
                            applicationContext,
                            timerModeIndex = timerModeIndex,
                            durationMs = timerDurationMs,
                            waitingForPlayback = timerWaitingForPlayback,
                            timerEndsAtWallClockMs = timerEndsAtWallClockMs,
                            autoResumeEnabled = autoResumeEnabled,
                            autoResumeHour = autoResumeHour,
                            autoResumeMinute = autoResumeMinute,
                            autoResumeAtMs = autoResumeAtMs,
                            pausedSessionIds = pausedSessionIds,
                            generation = generation
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAppVersion" -> {
                        result.success(currentAppVersion())
                    }
                    "installApk" -> {
                        val apkPath = call.argument<String>("path")
                        result.success(installDownloadedApk(apkPath))
                    }
                    "canInstallUnknownApps" -> {
                        result.success(canInstallUnknownApps())
                    }
                    "openInstallPermissionSettings" -> {
                        result.success(openInstallPermissionSettings())
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, subtitleOverlayChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canDrawOverlays" -> {
                        result.success(if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            Settings.canDrawOverlays(this)
                        } else {
                            true
                        })
                    }
                    "openOverlaySettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            ).apply {
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            startActivity(intent)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    "startOverlay" -> {
                        startSubtitleService()
                        result.success(true)
                    }
                    "stopOverlay" -> {
                        stopSubtitleService()
                        result.success(true)
                    }
                    "updateSubtitle" -> {
                        val text = call.argument<String>("text") ?: ""
                        updateSubtitleOverlayText(text)
                        result.success(true)
                    }
                    "updateStyle" -> {
                        val fontSize = call.argument<Double>("fontSize")?.toFloat() ?: 18f
                        val backgroundColor = call.argument<String>("backgroundColor") ?: "#80000000"
                        val textColor = call.argument<String>("textColor") ?: "#FFFFFF"
                        updateSubtitleOverlayStyle(
                            SubtitleOverlayStyle(
                                fontSize = fontSize,
                                backgroundColor = backgroundColor,
                                textColor = textColor
                            )
                        )
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        notificationsMethodChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, notificationsChannel)
        capturePendingNotificationSession(intent)
        notificationsMethodChannel?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "areNotificationsEnabled" -> {
                        result.success(
                            NotificationManagerCompat.from(this).areNotificationsEnabled()
                        )
                    }
                    "openNotificationSettings" -> {
                        result.success(openNotificationSettings())
                    }
                    "syncUnifiedPlaybackNotifications" -> {
                        val rawItems =
                            call.argument<List<Map<String, Any?>>>("items") ?: emptyList()
                        val mode = call.argument<String>("mode") ?: "single"
                        val mainSessionId = call.argument<String>("mainSessionId")
                        val showSummary = call.argument<Boolean>("showSummary") ?: false
                        val summaryText = call.argument<String>("summaryText")
                        val summaryLines =
                            call.argument<List<String>>("summaryLines") ?: emptyList()
                        val styleVariant = call.argument<String>("styleVariant")
                        val items = rawItems.mapNotNull { raw ->
                            val id = raw["id"] as? String ?: return@mapNotNull null
                            val title = raw["title"] as? String ?: return@mapNotNull null
                            UnifiedPlaybackNotificationItem(
                                id = id,
                                title = title,
                                subtitle = raw["subtitle"] as? String,
                                artPath = raw["artPath"] as? String,
                                playing = raw["playing"] as? Boolean ?: false,
                                hasPrevious = raw["hasPrevious"] as? Boolean ?: false,
                                hasNext = raw["hasNext"] as? Boolean ?: false
                            )
                        }
                        UnifiedPlaybackNotificationController.sync(
                            this,
                            mode,
                            mainSessionId,
                            items,
                            showSummary,
                            summaryText,
                            summaryLines,
                            styleVariant
                        )
                        result.success(null)
                    }
                    "clearUnifiedPlaybackNotifications" -> {
                        UnifiedPlaybackNotificationController.clear(this)
                        result.success(null)
                    }
                    "consumePendingNotificationSessionId" -> {
                        val sessionId = pendingNotificationSessionId
                        pendingNotificationSessionId = null
                        result.success(sessionId)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileCacheChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "cacheFromUri" -> {
                        val uriString = call.argument<String>("uri")
                        val name = call.argument<String>("name") ?: "picked_audio"
                        val index = call.argument<Int>("index") ?: 0
                        if (uriString.isNullOrBlank()) {
                            result.error("invalid_args", "uri is required", null)
                            return@setMethodCallHandler
                        }

                        try {
                            val uri = Uri.parse(uriString)
                            val extension = name.substringAfterLast('.', "")
                            val safeExt = if (extension.isBlank()) "bin" else extension

                            val outDir = File(filesDir, "nameless_audio_imports")
                            if (!outDir.exists()) {
                                outDir.mkdirs()
                            }
                            val outFile = File(outDir, "${System.currentTimeMillis()}_${index}.$safeExt")

                            contentResolver.openInputStream(uri).use { input ->
                                if (input == null) {
                                    result.error("open_failed", "cannot open input stream", null)
                                    return@setMethodCallHandler
                                }
                                FileOutputStream(outFile).use { output ->
                                    val buffer = ByteArray(64 * 1024)
                                    while (true) {
                                        val read = input.read(buffer)
                                        if (read < 0) break
                                        output.write(buffer, 0, read)
                                    }
                                    output.flush()
                                }
                            }
                            result.success(outFile.absolutePath)
                        } catch (e: Exception) {
                            result.error("cache_failed", e.message ?: "unknown error", null)
                        }
                    }
                    "clearApplicationCache" -> {
                        Thread {
                            val deletedBytes = clearApplicationCache()
                            runOnUiThread { result.success(deletedBytes) }
                        }.start()
                    }
                    "setApplicationCacheLimit" -> {
                        val maxBytes = call.argument<Number>("maxBytes")?.toLong()
                            ?: defaultMaxApplicationCacheBytes
                        setMaxApplicationCacheBytes(maxBytes)
                        Thread {
                            enforceApplicationCacheLimit(maxBytes)
                            runOnUiThread { result.success(null) }
                        }.start()
                    }
                    "enforceApplicationCacheLimit" -> {
                        val maxBytes = call.argument<Number>("maxBytes")?.toLong()
                            ?: maxApplicationCacheBytes()
                        Thread {
                            enforceApplicationCacheLimit(maxBytes)
                            runOnUiThread { result.success(null) }
                        }.start()
                    }
                    "scanFolder" -> {
                        val folder = call.argument<String>("folder")
                        if (folder.isNullOrBlank()) {
                            result.error("invalid_args", "folder is required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val tracks = scanFolder(folder)
                                val data = tracks.map { track ->
                                    hashMapOf(
                                        "path" to track.path,
                                        "title" to track.title,
                                        "groupKey" to track.groupKey,
                                        "groupTitle" to track.groupTitle,
                                        "groupSubtitle" to track.groupSubtitle,
                                        "isVideo" to track.isVideo,
                                        "scannedAtMs" to track.scannedAtMs,
                                        "fileSizeBytes" to track.fileSizeBytes,
                                        "modifiedAtMs" to track.modifiedAtMs
                                    )
                                }
                                runOnUiThread { result.success(data) }
                            } catch (e: SecurityException) {
                                runOnUiThread {
                                    result.error(
                                        "scan_permission_denied",
                                        e.message ?: "permission denied",
                                        null
                                    )
                                }
                            } catch (e: IllegalStateException) {
                                runOnUiThread {
                                    result.error(
                                        "scan_provider_error",
                                        e.message ?: "provider error",
                                        null
                                    )
                                }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("scan_unknown_error", e.message ?: "unknown error", null)
                                }
                            }
                        }.start()
                    }
                    "listChildFolders" -> {
                        val folder = call.argument<String>("folder")
                        if (folder.isNullOrBlank()) {
                            result.error("invalid_args", "folder is required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val folders = listChildFolders(folder)
                                runOnUiThread { result.success(folders) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "list_child_folders_failed",
                                        e.message ?: "unknown error",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                    "renameDocument" -> {
                        val targetPath = call.argument<String>("path")
                        val name = call.argument<String>("name")
                        if (targetPath.isNullOrBlank() || name.isNullOrBlank()) {
                            result.error("invalid_args", "path and name are required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val renamed = renameDocumentTarget(targetPath, name)
                                runOnUiThread { result.success(renamed) }
                            } catch (e: SecurityException) {
                                runOnUiThread {
                                    result.error(
                                        "rename_permission_denied",
                                        e.message ?: "permission denied",
                                        null
                                    )
                                }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "rename_failed",
                                        e.message ?: "unknown error",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                    "readAudioDetailBackup" -> {
                        val folder = call.argument<String>("folder")
                        if (folder.isNullOrBlank()) {
                            result.error("invalid_args", "folder is required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val json = readAudioDetailBackup(folder)
                                runOnUiThread { result.success(json) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "detail_backup_read_failed",
                                        e.message ?: "unknown error",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                    "writeAudioDetailBackup" -> {
                        val folder = call.argument<String>("folder")
                        val json = call.argument<String>("json")
                        if (folder.isNullOrBlank() || json == null) {
                            result.error("invalid_args", "folder and json are required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val saved = writeAudioDetailBackup(folder, json)
                                runOnUiThread { result.success(saved) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "detail_backup_write_failed",
                                        e.message ?: "unknown error",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                    "readSingleFileDetailBackup" -> {
                        val filePath = call.argument<String>("filePath")
                        if (filePath.isNullOrBlank()) {
                            result.error("invalid_args", "filePath is required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val json = readSingleFileDetailBackup(filePath)
                                runOnUiThread { result.success(json) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "single_detail_backup_read_failed",
                                        e.message ?: "unknown error",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                    "writeSingleFileDetailBackup" -> {
                        val filePath = call.argument<String>("filePath")
                        val json = call.argument<String>("json")
                        if (filePath.isNullOrBlank() || json == null) {
                            result.error("invalid_args", "filePath and json are required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val saved = writeSingleFileDetailBackup(filePath, json)
                                runOnUiThread { result.success(saved) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "single_detail_backup_write_failed",
                                        e.message ?: "unknown error",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                    "writeFileBytesToFolder" -> {
                        val folder = call.argument<String>("folder")
                        val name = call.argument<String>("name")
                        val bytes = call.argument<ByteArray>("bytes")
                        val mimeType = call.argument<String>("mimeType")
                        if (folder.isNullOrBlank() || name.isNullOrBlank() || bytes == null) {
                            result.error(
                                "invalid_args",
                                "folder, name and bytes are required",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val savedPath = writeFileBytesToFolder(folder, name, bytes, mimeType)
                                runOnUiThread { result.success(savedPath) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "folder_file_write_failed",
                                        e.message ?: "unknown error",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                    "documentPathExists" -> {
                        val targetPath = call.argument<String>("path")
                        if (targetPath.isNullOrBlank()) {
                            result.error("invalid_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val exists = documentPathExists(targetPath)
                                runOnUiThread { result.success(exists) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "document_path_exists_failed",
                                        e.message ?: "unknown error",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                    "ensureFolderPath" -> {
                        val folder = call.argument<String>("folder")
                        val relativePath = call.argument<String>("relativePath")
                        val overwrite = call.argument<Boolean>("overwrite") ?: false
                        if (folder.isNullOrBlank() || relativePath == null) {
                            result.error(
                                "invalid_args",
                                "folder and relativePath are required",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val ensured = ensureFolderPath(folder, relativePath, overwrite)
                                runOnUiThread { result.success(ensured) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "ensure_folder_failed",
                                        e.message ?: "unknown error",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                    "copyFileToFolder" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val folder = call.argument<String>("folder")
                        val relativePath = call.argument<String>("relativePath")
                        val overwrite = call.argument<Boolean>("overwrite") ?: false
                        if (sourcePath.isNullOrBlank() ||
                            folder.isNullOrBlank() ||
                            relativePath.isNullOrBlank()
                        ) {
                            result.error(
                                "invalid_args",
                                "sourcePath, folder and relativePath are required",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val saved = copyFileToFolder(
                                    sourcePath,
                                    folder,
                                    relativePath,
                                    overwrite
                                )
                                runOnUiThread { result.success(saved) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "copy_file_failed",
                                        e.message ?: "unknown error",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                    "deleteDocumentPath" -> {
                        val targetPath = call.argument<String>("path")
                        if (targetPath.isNullOrBlank()) {
                            result.error("invalid_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val deleted = deleteDocumentPath(targetPath)
                                runOnUiThread { result.success(deleted) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "delete_document_failed",
                                        e.message ?: "unknown error",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                    "resolveTrackCover" -> {
                        val trackPath = call.argument<String>("path")
                        val groupKey = call.argument<String>("groupKey")
                        val rootFolder = call.argument<String>("rootFolder")
                        if (trackPath.isNullOrBlank()) {
                            result.error("invalid_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val coverPath = resolveTrackCover(trackPath, groupKey, rootFolder)
                                runOnUiThread { result.success(coverPath) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "cover_resolve_failed",
                                        e.message ?: "unknown error",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                    "resolveVideoFrame" -> {
                        val trackPath = call.argument<String>("path")
                        val modifiedAtMs = call.argument<Long>("modifiedAtMs")
                        if (trackPath.isNullOrBlank()) {
                            result.error("invalid_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val framePath = resolveVideoFrame(trackPath, modifiedAtMs)
                                runOnUiThread { result.success(framePath) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "video_frame_resolve_failed",
                                        e.message ?: "unknown error",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                    "discoverRootImages" -> {
                        val trackPath = call.argument<String>("path")
                        val groupKey = call.argument<String>("groupKey")
                        val rootFolder = call.argument<String>("rootFolder")
                        if (trackPath.isNullOrBlank()) {
                            result.error("invalid_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val images = discoverRootImages(trackPath, groupKey, rootFolder)
                                runOnUiThread { result.success(images) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "cover_discover_failed",
                                        e.message ?: "unknown error",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                    "resolveTrackSubtitle" -> {
                        val trackPath = call.argument<String>("path")
                        val groupKey = call.argument<String>("groupKey")
                        if (trackPath.isNullOrBlank()) {
                            result.error("invalid_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val subtitle = resolveTrackSubtitle(trackPath, groupKey)
                                runOnUiThread { result.success(subtitle) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "subtitle_resolve_failed",
                                        e.message ?: "unknown error",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                    "pickAudioSource" -> {
                        launchPickAudioSource(result)
                    }
                    "pickAudioFiles" -> {
                        launchPickAudioFiles(result)
                    }
                    "pickAudioFolder" -> {
                        launchPickAudioFolder(result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (
            requestCode == pickAudioSourceRequestCode ||
            requestCode == pickAudioFilesRequestCode ||
            requestCode == pickAudioFolderRequestCode
        ) {
            handlePickAudioSourceResult(requestCode, resultCode, data)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun launchPickAudioSource(result: MethodChannel.Result) {
        if (pendingPickAudioRequest != null) {
            result.error("picker_busy", "Audio picker is already active", null)
            return
        }
        try {
            val pickFilesIntent = buildPickAudioFilesIntent()
            val pickFolderIntent = buildPickAudioFolderIntent()
            val chooserIntent = Intent(Intent.ACTION_CHOOSER).apply {
                putExtra(Intent.EXTRA_INTENT, pickFilesIntent)
                putExtra(Intent.EXTRA_TITLE, "Select audio")
                putExtra(Intent.EXTRA_INITIAL_INTENTS, arrayOf(pickFolderIntent))
            }

            pendingPickAudioRequest = PendingPickAudioRequest(
                result = result,
                mode = PickAudioMode.any
            )
            startActivityForResult(chooserIntent, pickAudioSourceRequestCode)
        } catch (e: Exception) {
            pendingPickAudioRequest = null
            result.error("picker_failed", e.message ?: "cannot launch picker", null)
        }
    }

    private fun launchPickAudioFiles(result: MethodChannel.Result) {
        launchAudioPicker(
            result = result,
            mode = PickAudioMode.files,
            requestCode = pickAudioFilesRequestCode,
            intentBuilder = ::buildPickAudioFilesIntent
        )
    }

    private fun launchPickAudioFolder(result: MethodChannel.Result) {
        launchAudioPicker(
            result = result,
            mode = PickAudioMode.folder,
            requestCode = pickAudioFolderRequestCode,
            intentBuilder = ::buildPickAudioFolderIntent
        )
    }

    private fun launchAudioPicker(
        result: MethodChannel.Result,
        mode: PickAudioMode,
        requestCode: Int,
        intentBuilder: () -> Intent
    ) {
        if (pendingPickAudioRequest != null) {
            result.error("picker_busy", "Audio picker is already active", null)
            return
        }
        try {
            pendingPickAudioRequest = PendingPickAudioRequest(result = result, mode = mode)
            startActivityForResult(intentBuilder(), requestCode)
        } catch (e: Exception) {
            pendingPickAudioRequest = null
            result.error("picker_failed", e.message ?: "cannot launch picker", null)
        }
    }

    private fun buildPickAudioFilesIntent(): Intent {
        return Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            putExtra(Intent.EXTRA_MIME_TYPES, audioPickerMimeTypes)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
    }

    private fun buildPickAudioFolderIntent(): Intent {
        return Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
    }

    private fun handlePickAudioSourceResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ) {
        val pendingRequest = pendingPickAudioRequest ?: return
        val callback = pendingRequest.result
        pendingPickAudioRequest = null

        if (resultCode != Activity.RESULT_OK || data == null) {
            callback.success(null)
            return
        }

        val maybeTreeUri = data.data
        if (maybeTreeUri != null && DocumentsContract.isTreeUri(maybeTreeUri)) {
            if (pendingRequest.mode == PickAudioMode.files) {
                callback.success(null)
                return
            }
            persistReadPermission(maybeTreeUri, data.flags)
            callback.success(
                hashMapOf(
                    "kind" to "folder",
                    "path" to maybeTreeUri.toString(),
                    "label" to resolveTreeDisplayName(maybeTreeUri)
                )
            )
            return
        }

        if (pendingRequest.mode == PickAudioMode.folder || requestCode == pickAudioFolderRequestCode) {
            callback.success(null)
            return
        }

        val files = arrayListOf<HashMap<String, String>>()
        data.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) {
                val uri = clip.getItemAt(i)?.uri ?: continue
                appendPickedFile(files, uri, data.flags)
            }
        }
        maybeTreeUri?.let { uri ->
            appendPickedFile(files, uri, data.flags)
        }

        if (files.isEmpty()) {
            callback.success(null)
            return
        }

        callback.success(
            hashMapOf(
                "kind" to "files",
                "files" to files
            )
        )
    }

    private fun resolveTreeDisplayName(uri: Uri): String? {
        val treeRoot = DocumentFile.fromTreeUri(this, uri)
        val name = treeRoot?.name?.trim()
        if (!name.isNullOrBlank()) {
            return name
        }
        return resolveDisplayName(uri)
    }

    private fun appendPickedFile(
        files: MutableList<HashMap<String, String>>,
        uri: Uri,
        flags: Int
    ) {
        persistReadPermission(uri, flags)
        val name = resolveDisplayName(uri)
            ?: uri.lastPathSegment
            ?: "picked_audio"
        files.add(
            hashMapOf(
                "uri" to uri.toString(),
                "name" to name
            )
        )
    }

    private fun persistReadPermission(uri: Uri, flags: Int) {
        val canRead = flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0
        val canWrite = flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0
        if (!canRead && !canWrite) return
        try {
            var modeFlags = 0
            if (canRead) modeFlags = modeFlags or Intent.FLAG_GRANT_READ_URI_PERMISSION
            if (canWrite) modeFlags = modeFlags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            contentResolver.takePersistableUriPermission(
                uri,
                modeFlags
            )
        } catch (_: Exception) {
            // Some providers do not support persistable permissions.
        }
    }

    private fun resolveDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (!cursor.moveToFirst()) return@use null
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index < 0) return@use null
                cursor.getString(index)
            }
        } catch (_: Exception) {
            null
        }
    }

    private data class PendingPickAudioRequest(
        val result: MethodChannel.Result,
        val mode: PickAudioMode
    )

    private enum class PickAudioMode {
        any,
        files,
        folder
    }

    private fun syncPlaybackKeepAlive(
        enabled: Boolean,
        hasActivePlayback: Boolean,
        hasActiveTimer: Boolean,
        usesUnifiedPlaybackNotifications: Boolean,
        keepForegroundServiceAlive: Boolean
    ) {
        try {
            // NativePlaybackService already owns the foreground notification
            // during active playback.  The keep-alive service provides a
            // redundant foreground service + wake lock so that if
            // NativePlaybackService briefly drops out of foreground (e.g.
            // during a track transition) the process is not killed.
            // When foreground is suppressed (notification control disabled),
            // do NOT start the keep-alive service — it would show a notification
            // that the user explicitly turned off.
            val shouldRunKeepAliveService =
                !NativePlaybackService.foregroundSuppressed &&
                    PlaybackKeepAlivePolicy.shouldRunKeepAliveService(
                        keepForegroundServiceAlive = keepForegroundServiceAlive,
                        hasActiveTimer = hasActiveTimer,
                        hasActivePlayback = hasActivePlayback
                    )
            if (shouldRunKeepAliveService) {
                val serviceIntent =
                    Intent(applicationContext, PlaybackKeepAliveService::class.java).apply {
                        action = PlaybackKeepAliveService.ACTION_START
                        putExtra(
                            PlaybackKeepAliveService.EXTRA_HAS_ACTIVE_PLAYBACK,
                            hasActivePlayback
                        )
                        putExtra(
                            PlaybackKeepAliveService.EXTRA_HAS_ACTIVE_TIMER,
                            hasActiveTimer
                        )
                        putExtra(
                            PlaybackKeepAliveService.EXTRA_USES_UNIFIED_PLAYBACK_NOTIFICATION,
                            usesUnifiedPlaybackNotifications
                        )
                        putExtra(
                            PlaybackKeepAliveService.EXTRA_KEEP_FOREGROUND_SERVICE_ALIVE,
                            true
                        )
                    }
                ContextCompat.startForegroundService(applicationContext, serviceIntent)
            } else {
                stopPlaybackKeepAliveService()
            }
        } catch (_: Exception) {
            // Ignore foreground service sync failures and fall back to a wakelock.
        }
        try {
            PlaybackWakeLockController.sync(
                applicationContext,
                PlaybackKeepAlivePolicy.shouldHoldKeepAliveWakeLock(
                    enabled = enabled,
                    hasActiveTimer = hasActiveTimer,
                    hasActivePlayback = hasActivePlayback
                )
            )
        } catch (_: Exception) {
            // Ignore keep-alive sync failures and let playback continue best-effort.
        }
    }

    private fun stopPlaybackKeepAliveService() {
        val stopIntent = Intent(applicationContext, PlaybackKeepAliveService::class.java).apply {
            action = PlaybackKeepAliveService.ACTION_STOP
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                applicationContext.startService(stopIntent)
            } else {
                @Suppress("DEPRECATION")
                applicationContext.startService(stopIntent)
            }
        } catch (_: Exception) {
            // If the service is not startable from the current state, remove it best-effort.
        }
        applicationContext.stopService(
            Intent(applicationContext, PlaybackKeepAliveService::class.java)
        )
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        manager?.cancel(UnifiedPlaybackNotificationController.foregroundServiceNotificationId + 1)
    }

    private fun openNotificationSettings(): Boolean {
        return try {
            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                putExtra("android.provider.extra.APP_PACKAGE", packageName)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
            true
        } catch (_: Exception) {
            try {
                val fallbackIntent = Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", packageName, null)
                ).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
                startActivity(fallbackIntent)
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }
        val powerManager = getSystemService(POWER_SERVICE) as? PowerManager
        return powerManager?.isIgnoringBatteryOptimizations(packageName) == true
    }

    private fun canManageAllFilesAccess(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return true
        }
        return try {
            Environment.isExternalStorageManager()
        } catch (_: Exception) {
            false
        }
    }

    private fun openManageAllFilesAccessSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return openApplicationDetailsSettings()
        }
        return try {
            val intent = Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName")
            ).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
            true
        } catch (_: Exception) {
            try {
                val fallbackIntent = Intent(
                    Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION
                ).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
                startActivity(fallbackIntent)
                true
            } catch (_: Exception) {
                openApplicationDetailsSettings()
            }
        }
    }

    private fun openBatteryOptimizationSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return openApplicationDetailsSettings()
        }

        return try {
            val intent = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:$packageName")
            ).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
            true
        } catch (_: Exception) {
            try {
                val fallbackIntent = Intent(
                    Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS
                ).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
                startActivity(fallbackIntent)
                true
            } catch (_: Exception) {
                openApplicationDetailsSettings()
            }
        }
    }

    private fun openBackgroundRunSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return openApplicationDetailsSettings()
        }
        if (!isIgnoringBatteryOptimizations() && openBatteryOptimizationSettings()) {
            return true
        }
        return openBatteryOptimizationListSettings() || openApplicationDetailsSettings()
    }

    private fun canScheduleExactAlarms(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return true
        }
        val alarmManager = getSystemService(AlarmManager::class.java)
        return try {
            alarmManager?.canScheduleExactAlarms() == true
        } catch (_: Exception) {
            false
        }
    }

    private fun openExactAlarmSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return openApplicationDetailsSettings()
        }
        return try {
            val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                data = Uri.parse("package:$packageName")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
            true
        } catch (_: Exception) {
            openApplicationDetailsSettings()
        }
    }

    private fun getNativeTimerRuntimeState(): Map<String, Any?>? {
        val state = NativePlaybackStateStore.loadTimerRuntimeState(applicationContext)
            ?: return null
        return mapOf(
            "timerMode" to state.timerModeIndex,
            "timerDurationMs" to state.durationMs,
            "timerWaitingForPlayback" to state.waitingForPlayback,
            "timerEndsAtWallClockMs" to state.timerEndsAtWallClockMs,
            "timerEndsElapsedRealtimeMs" to state.timerEndsElapsedRealtimeMs,
            "autoResumeEnabled" to state.autoResumeEnabled,
            "autoResumeHour" to state.autoResumeHour,
            "autoResumeMinute" to state.autoResumeMinute,
            "autoResumeAtMs" to state.autoResumeAtMs,
            "pausedSessionIds" to state.pausedSessionIds,
            "generation" to state.generation
        )
    }

    private fun openBatteryOptimizationListSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return false
        }
        return try {
            val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun openApplicationDetailsSettings(): Boolean {
        return try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", packageName, null)
            ).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun currentAppVersion(): Map<String, Any> {
        val packageInfo = packageManager.getPackageInfo(packageName, 0)
        val buildNumber = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            packageInfo.versionCode.toLong()
        }
        return mapOf(
            "versionName" to (packageInfo.versionName ?: "0.0.0"),
            "buildNumber" to buildNumber
        )
    }

    private fun installDownloadedApk(apkPath: String?): Map<String, Any?> {
        if (apkPath.isNullOrBlank()) {
            return mapOf(
                "ok" to false,
                "needsPermission" to false,
                "message" to "APK path is empty."
            )
        }

        if (!canInstallUnknownApps()) {
            openInstallPermissionSettings()
            return mapOf(
                "ok" to false,
                "needsPermission" to true,
                "message" to "Install permission is required."
            )
        }

        val apkFile = File(apkPath)
        if (!apkFile.exists() || apkFile.length() <= 0) {
            return mapOf(
                "ok" to false,
                "needsPermission" to false,
                "message" to "APK file does not exist."
            )
        }

        return try {
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                apkFile
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            mapOf(
                "ok" to true,
                "needsPermission" to false,
                "message" to null
            )
        } catch (e: Exception) {
            mapOf(
                "ok" to false,
                "needsPermission" to false,
                "message" to (e.message ?: "Cannot open installer.")
            )
        }
    }

    private fun canInstallUnknownApps(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return true
        }
        return packageManager.canRequestPackageInstalls()
    }

    private fun openInstallPermissionSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName")
            ).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
            true
        } catch (_: Exception) {
            try {
                val fallbackIntent = Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", packageName, null)
                ).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
                startActivity(fallbackIntent)
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    private data class ScannedTrack(
        val path: String,
        val title: String,
        val groupKey: String,
        val groupTitle: String,
        val groupSubtitle: String,
        val isVideo: Boolean = false,
        val scannedAtMs: Long = System.currentTimeMillis(),
        val fileSizeBytes: Long? = null,
        val modifiedAtMs: Long? = null
    )

    private data class DocumentRenameTarget(
        val uri: Uri,
        val rootUri: Uri?,
        val syntheticBase: String?,
        val syntheticParentRelative: String?,
        val treeRoot: Boolean
    )

    private fun scanFolder(folder: String): List<ScannedTrack> {
        val byPath = linkedMapOf<String, ScannedTrack>()
        val folderTrimmed = folder.trim()
        val uri = resolveContentUri(folderTrimmed)

        if (uri != null) {
            scanDocumentTree(uri, byPath)
            if (byPath.isNotEmpty()) {
                return byPath.values.toList()
            }

            // After a tree-root rename performed via File.renameTo, some ROMs
            // keep the underlying directory readable while the new SAF tree URI
            // is not yet queryable. Fall back to direct file scanning so a
            // refresh does not incorrectly prune the folder from the library.
            val filePath = contentUriToFilePath(folderTrimmed)
            if (filePath != null) {
                val root = File(filePath)
                if (root.exists() && root.isDirectory) {
                    scanFileSystemAsDocumentTree(
                        rootUri = uri,
                        root = root,
                        output = byPath
                    )
                    if (byPath.isNotEmpty()) {
                        return byPath.values.toList()
                    }
                    scanMediaStore(filePath, byPath)
                    return byPath.values.toList()
                }
            }
            return byPath.values.toList()
        }

        val root = File(folderTrimmed)
        if (root.exists() && root.isDirectory) {
            scanFileSystem(root, byPath)
            if (byPath.isNotEmpty()) {
                return byPath.values.toList()
            }
        }

        scanMediaStore(folderTrimmed, byPath)
        return byPath.values.toList()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deliverNotificationSessionIntent(intent)
    }

    override fun onDestroy() {
        notificationsMethodChannel = null
        if (isSubtitleServiceBound) {
            unbindService(subtitleServiceConnection)
            isSubtitleServiceBound = false
            subtitleOverlayService = null
        }
        super.onDestroy()
    }

    private val subtitleServiceConnection = object : android.content.ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: android.os.IBinder?) {
            val binder = service as SubtitleOverlayService.LocalBinder
            subtitleOverlayService = binder.getService()
            isSubtitleServiceBound = true
            applyPendingSubtitleOverlayState()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            subtitleOverlayService = null
            isSubtitleServiceBound = false
        }
    }

    private fun startSubtitleService() {
        if (!isSubtitleServiceBound) {
            val intent = Intent(this, SubtitleOverlayService::class.java)
            startService(intent)
            bindService(intent, subtitleServiceConnection, Context.BIND_AUTO_CREATE)
        } else {
            applyPendingSubtitleOverlayState()
        }
    }

    private fun stopSubtitleService() {
        if (isSubtitleServiceBound) {
            unbindService(subtitleServiceConnection)
            isSubtitleServiceBound = false
            subtitleOverlayService = null
        }
        pendingSubtitleOverlayText = null
        stopService(Intent(this, SubtitleOverlayService::class.java))
    }

    private fun updateSubtitleOverlayText(text: String) {
        pendingSubtitleOverlayText = text
        subtitleOverlayService?.updateSubtitle(text)
    }

    private fun updateSubtitleOverlayStyle(style: SubtitleOverlayStyle) {
        pendingSubtitleOverlayStyle = style
        subtitleOverlayService?.setStyle(
            style.fontSize,
            style.backgroundColor,
            style.textColor
        )
    }

    private fun applyPendingSubtitleOverlayState() {
        val service = subtitleOverlayService ?: return
        pendingSubtitleOverlayStyle?.let { style ->
            service.setStyle(style.fontSize, style.backgroundColor, style.textColor)
        }
        pendingSubtitleOverlayText?.let(service::updateSubtitle)
    }

    private fun capturePendingNotificationSession(intent: Intent?) {
        pendingNotificationSessionId = extractNotificationSessionId(intent)
    }

    private fun deliverNotificationSessionIntent(intent: Intent?) {
        val sessionId = extractNotificationSessionId(intent) ?: return
        val channel = notificationsMethodChannel
        if (channel == null) {
            pendingNotificationSessionId = sessionId
            return
        }
        try {
            channel.invokeMethod(
                "openSessionFromNotification",
                mapOf("sessionId" to sessionId)
            )
        } catch (_: Exception) {
            pendingNotificationSessionId = sessionId
        }
    }

    private fun extractNotificationSessionId(intent: Intent?): String? {
        val action = intent?.action
        val sessionId = intent
            ?.getStringExtra(notificationSessionIdExtra)
            ?.takeIf { it.isNotBlank() }
            ?: return null
        if (action == null || action == openSessionFromNotificationAction) {
            return sessionId
        }
        return sessionId
    }

    private fun listChildFolders(folder: String): List<String> {
        val folderTrimmed = folder.trim()
        val uri = resolveContentUri(folderTrimmed)

        if (uri != null) {
            listChildFoldersViaDocumentsContract(uri)?.let { return it }
            val treeRoot = DocumentFile.fromTreeUri(this, uri)
            val root = treeRoot ?: DocumentFile.fromSingleUri(this, uri) ?: return emptyList()
            if (!root.exists()) return emptyList()
            return try {
                root.listFiles()
                    .filter { it.isDirectory }
                    .map { it.uri.toString() }
                    .sortedBy { it.lowercase(Locale.US) }
            } catch (_: Exception) {
                emptyList()
            }
        }

        val root = File(folderTrimmed)
        if (!root.exists() || !root.isDirectory) {
            return emptyList()
        }
        return try {
            root.listFiles()
                ?.filter { it.isDirectory }
                ?.map { it.absolutePath }
                ?.sortedBy { it.lowercase(Locale.US) }
                ?: emptyList()
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun resolveContentUri(rawFolder: String): Uri? {
        if (rawFolder.startsWith("content://")) {
            return Uri.parse(rawFolder)
        }
        if (rawFolder.startsWith("/tree/")) {
            return Uri.parse("content://com.android.externalstorage.documents$rawFolder")
        }
        if (!rawFolder.contains("/") && rawFolder.contains(":")) {
            return DocumentsContract.buildTreeDocumentUri(
                "com.android.externalstorage.documents",
                rawFolder
            )
        }
        return null
    }

    private fun renameDocumentTarget(targetPath: String, newName: String): HashMap<String, String> {
        val target = resolveDocumentRenameTarget(targetPath)
            ?: throw IllegalArgumentException("Cannot resolve rename target.")

        // For tree-root targets the SAF provider may refuse to rename the
        // directory because the app only holds a grant on that root itself,
        // not on its parent.  Fall back to java.io.File.renameTo which works
        // when the app has MANAGE_EXTERNAL_STORAGE or the path is on primary
        // external storage.
        if (target.treeRoot) {
            val fileRenamedPath = tryRenameTreeRootViaFile(target, newName)
            if (fileRenamedPath != null) {
                return hashMapOf("path" to fileRenamedPath)
            }
            // File rename not available — fall through to SAF rename.
        }

        val renamedUri = DocumentsContract.renameDocument(contentResolver, target.uri, newName)
            ?: throw IllegalStateException("Provider did not return renamed document uri.")
        var renamedPermissionUri: Uri? = renamedUri
        val renamedPath = when {
            target.syntheticBase != null -> {
                renamedPermissionUri = null
                val parent = target.syntheticParentRelative.orEmpty()
                if (parent.isBlank()) {
                    "${target.syntheticBase}::$newName"
                } else {
                    "${target.syntheticBase}::$parent/$newName"
                }
            }
            target.treeRoot -> {
                val documentId = documentIdForUri(renamedUri)
                    ?: throw IllegalStateException("Cannot resolve renamed tree document id.")
                val authority = renamedUri.authority ?: target.rootUri?.authority
                    ?: throw IllegalStateException("Cannot resolve renamed tree authority.")
                val renamedTreeUri = DocumentsContract.buildTreeDocumentUri(authority, documentId)
                renamedPermissionUri = renamedTreeUri
                renamedTreeUri.toString()
            }
            else -> renamedUri.toString()
        }
        renamedPermissionUri?.let { persistRenamedPermission(target.rootUri ?: target.uri, it) }
        return hashMapOf("path" to renamedPath)
    }

    /**
     * Attempts to rename a tree-root directory using [java.io.File].
     * This works when the app has MANAGE_EXTERNAL_STORAGE or the path is on
     * primary external storage and the document ID encodes the relative path
     * (e.g. "primary:Music/MyFolder").
     *
     * Returns the new content URI string on success, or null if the rename
     * could not be performed via this path.
     */
    private fun tryRenameTreeRootViaFile(
        target: DocumentRenameTarget,
        newName: String
    ): String? {
        val rootUri = target.rootUri ?: return null
        val documentId = documentIdForUri(target.uri) ?: return null
        // Document IDs for primary external storage look like "primary:path/to/dir".
        val colonIndex = documentId.indexOf(':')
        if (colonIndex < 0) return null
        val volumeName = documentId.substring(0, colonIndex)
        val relativePath = documentId.substring(colonIndex + 1)
        val volumeRoot = resolveVolumeRoot(volumeName) ?: return null
        val oldFile = java.io.File(volumeRoot, relativePath)
        if (!oldFile.exists() || !oldFile.isDirectory) return null
        val parentFile = oldFile.parentFile ?: return null
        val newFile = java.io.File(parentFile, newName)
        if (!oldFile.renameTo(newFile)) return null

        // Build the new tree URI with the updated document ID.
        val newRelativePath = newFile.absolutePath.removePrefix(volumeRoot).trimStart('/')
        val newDocumentId = "$volumeName:$newRelativePath"
        val authority = rootUri.authority ?: return null
        val newTreeUri = DocumentsContract.buildTreeDocumentUri(authority, newDocumentId)
        try {
            persistRenamedPermission(rootUri, newTreeUri)
        } catch (_: Exception) {
            // Permission migration is best-effort.
        }
        return newTreeUri.toString()
    }

    /**
     * Resolves the root path for a storage volume name.
     * "primary" maps to the primary external storage root.
     */
    private fun resolveVolumeRoot(volumeName: String): String? {
        if (volumeName.equals("primary", ignoreCase = true)) {
            return Environment.getExternalStorageDirectory().absolutePath
        }
        // For secondary volumes, try to find the mount point via StorageManager.
        return try {
            val storageManager = getSystemService(Context.STORAGE_SERVICE)
                as? android.os.storage.StorageManager ?: return null
            val volumes: List<android.os.storage.StorageVolume> =
                storageManager.storageVolumes
            val volume = volumes.firstOrNull { v ->
                v.uuid?.equals(volumeName, ignoreCase = true) == true
            } ?: return null
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                volume.directory?.absolutePath
            } else {
                @Suppress("DiscouragedPrivateApi")
                val method = volume.javaClass.getDeclaredMethod("getPath")
                method.isAccessible = true
                method.invoke(volume) as? String
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun persistRenamedPermission(oldUri: Uri, newUri: Uri) {
        val existing = contentResolver.persistedUriPermissions.firstOrNull {
            it.uri == oldUri
        } ?: return
        var modeFlags = 0
        if (existing.isReadPermission) {
            modeFlags = modeFlags or Intent.FLAG_GRANT_READ_URI_PERMISSION
        }
        if (existing.isWritePermission) {
            modeFlags = modeFlags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        }
        if (modeFlags == 0) return
        try {
            contentResolver.takePersistableUriPermission(newUri, modeFlags)
        } catch (_: Exception) {
            // Some providers keep the old grant alive or do not expose a new persistable grant.
        }
    }

    private fun readAudioDetailBackup(folderPath: String): String? {
        val folder = resolveDocumentFileForFolderPath(folderPath)
        if (folder != null && folder.exists()) {
            val backup = folder.listFiles().firstOrNull {
                it.isFile && it.name == audioDetailBackupFileName
            } ?: folder.listFiles().firstOrNull {
                it.isFile && it.name == legacyAudioDetailBackupFileName
            }
            if (backup != null) {
                return contentResolver.openInputStream(backup.uri)?.use { input ->
                    input.bufferedReader(Charsets.UTF_8).readText()
                }
            }
        }
        // SAF access failed (e.g. after a File.renameTo) — fall back to File I/O.
        val filePath = contentUriToFilePath(folderPath) ?: return null
        val backupFile = java.io.File(filePath, audioDetailBackupFileName)
        if (backupFile.exists()) return backupFile.readText(Charsets.UTF_8)
        val legacyFile = java.io.File(filePath, legacyAudioDetailBackupFileName)
        if (legacyFile.exists()) return legacyFile.readText(Charsets.UTF_8)
        return null
    }

    private fun writeAudioDetailBackup(folderPath: String, json: String): Boolean {
        val folder = resolveDocumentFileForFolderPath(folderPath)
        if (folder != null && folder.exists()) {
            val backup = folder.listFiles().firstOrNull {
                it.isFile && it.name == audioDetailBackupFileName
            } ?: folder.createFile("application/json", audioDetailBackupFileName)
            if (backup != null) {
                contentResolver.openOutputStream(backup.uri, "wt")?.use { output ->
                    output.write(json.toByteArray(Charsets.UTF_8))
                    output.flush()
                } ?: return false
                return true
            }
        }
        // SAF access failed — fall back to File I/O.
        val filePath = contentUriToFilePath(folderPath) ?: return false
        return try {
            val backupFile = java.io.File(filePath, audioDetailBackupFileName)
            backupFile.writeText(json, Charsets.UTF_8)
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Converts a content URI (tree or document) to an actual file-system path
     * by parsing the document ID (e.g. "primary:Music/MyFolder").
     * Returns null if the URI cannot be resolved to a file path.
     */
    private fun contentUriToFilePath(contentUri: String): String? {
        val trimmed = contentUri.trim()
        if (!trimmed.startsWith("content://")) return null
        val uri = Uri.parse(trimmed)
        val documentId = try {
            if (DocumentsContract.isDocumentUri(this, uri)) {
                DocumentsContract.getDocumentId(uri)
            } else {
                DocumentsContract.getTreeDocumentId(uri)
            }
        } catch (_: Exception) {
            return null
        } ?: return null
        val colonIndex = documentId.indexOf(':')
        if (colonIndex < 0) return null
        val volumeName = documentId.substring(0, colonIndex)
        val relativePath = documentId.substring(colonIndex + 1)
        val volumeRoot = resolveVolumeRoot(volumeName) ?: return null
        return java.io.File(volumeRoot, relativePath).absolutePath
    }

    /**
     * Reads the `nameless-audio.json` file from the parent directory of the
     * given single-file content URI.  Returns the raw JSON string, or null if
     * the file does not exist or cannot be read.
     */
    private fun readSingleFileDetailBackup(filePath: String): String? {
        val parentFolder = resolveParentFolderForFile(filePath) ?: return null
        val backup = parentFolder.listFiles().firstOrNull {
            it.isFile && it.name == audioDetailBackupFileName
        } ?: return null
        return contentResolver.openInputStream(backup.uri)?.use { input ->
            input.bufferedReader(Charsets.UTF_8).readText()
        }
    }

    /**
     * Writes [json] into `nameless-audio.json` in the parent directory of the
     * given single-file content URI.  Returns true on success.
     */
    private fun writeSingleFileDetailBackup(filePath: String, json: String): Boolean {
        val parentFolder = resolveParentFolderForFile(filePath) ?: return false
        val backup = parentFolder.listFiles().firstOrNull {
            it.isFile && it.name == audioDetailBackupFileName
        } ?: parentFolder.createFile("application/json", audioDetailBackupFileName)
            ?: return false
        contentResolver.openOutputStream(backup.uri, "wt")?.use { output ->
            output.write(json.toByteArray(Charsets.UTF_8))
            output.flush()
        } ?: return false
        return true
    }

    /**
     * Resolves the parent [DocumentFile] directory for a single-file content
     * URI.  Supports both tree-based URIs (where the document ID encodes the
     * path) and synthetic `base::relative` URIs used internally.
     */
    private fun resolveParentFolderForFile(filePath: String): DocumentFile? {
        val trimmed = filePath.trim()
        if (!trimmed.startsWith("content://")) return null

        // Synthetic URI: "content://authority/tree/rootId::relative/path/file.mp3"
        val syntheticIndex = trimmed.indexOf("::")
        if (syntheticIndex >= 0) {
            val base = trimmed.substring(0, syntheticIndex)
            val relative = trimmed.substring(syntheticIndex + 2).trim('/')
            val parentRelative = relative.substringBeforeLast('/', missingDelimiterValue = "")
            val root = DocumentFile.fromTreeUri(this, Uri.parse(base)) ?: return null
            return if (parentRelative.isEmpty()) {
                root
            } else {
                resolveRelativeDocumentDirectory(root, parentRelative)
            }
        }

        // Standard tree document URI: extract parent document ID from the
        // document ID by stripping the last path segment.
        val uri = Uri.parse(trimmed)
        val treeBase = treeUriBaseForDocumentUri(uri)
        val documentId = documentIdForUri(uri)
        if (treeBase != null && documentId != null) {
            val parentDocumentId = if (documentId.contains('/')) {
                documentId.substringBeforeLast('/')
            } else {
                // File is at the tree root — parent is the root itself.
                startDocumentIdForTreeUri(treeBase) ?: return null
            }
            val parentUri = DocumentsContract.buildDocumentUriUsingTree(
                treeBase,
                parentDocumentId
            )
            return DocumentFile.fromTreeUri(this, parentUri)
                ?: DocumentFile.fromSingleUri(this, parentUri)
        }

        return null
    }

    private fun writeFileBytesToFolder(
        folderPath: String,
        name: String,
        bytes: ByteArray,
        mimeType: String?
    ): String? {
        val folder = resolveDocumentFileForFolderPath(folderPath) ?: return null
        val file = folder.listFiles().firstOrNull {
            it.isFile && normalizeDisplayName(it.name?.trim().orEmpty()) == name
        } ?: folder.createFile(
            mimeType ?: MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase(Locale.US))
                ?: "application/octet-stream",
            name
        ) ?: return null

        contentResolver.openOutputStream(file.uri, "w")?.use { output ->
            output.write(bytes)
            output.flush()
        } ?: return null

        return cacheDocumentCover(file, "$folderPath/$name")
    }

    private fun ensureFolderPath(
        folderPath: String,
        relativePath: String,
        overwrite: Boolean
    ): Boolean {
        val folder = ensureDocumentFileForFolderPath(folderPath, relativePath, overwrite)
            ?: return false
        return folder.exists()
    }

    private fun documentPathExists(targetPath: String): Boolean {
        val folder = resolveDocumentFileForFolderPath(targetPath) ?: return false
        return folder.exists()
    }

    private fun copyFileToFolder(
        sourcePath: String,
        folderPath: String,
        relativePath: String,
        overwrite: Boolean
    ): Boolean {
        val source = java.io.File(sourcePath)
        if (!source.exists() || !source.isFile) return false

        val normalizedRelative = relativePath.trim().replace('\\', '/')
        if (normalizedRelative.isBlank()) return false

        val folder = resolveDocumentFileForFolderPath(folderPath) ?: return false
        val targetFolder = ensureRelativeDocumentDirectory(
            folder,
            normalizedRelative.substringBeforeLast('/', missingDelimiterValue = ""),
            overwrite
        ) ?: return false

        val targetName = normalizedRelative.substringAfterLast('/')
        var existing = targetFolder.listFiles().firstOrNull {
            it.isFile && normalizeDisplayName(it.name?.trim().orEmpty()) == targetName
        }
        if (existing != null) {
            if (!overwrite) return false
            if (!existing.delete()) return false
            existing = null
        }

        val mimeType = MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(targetName.substringAfterLast('.', "").lowercase(Locale.US))
            ?: "application/octet-stream"
        val target = existing ?: targetFolder.createFile(mimeType, targetName) ?: return false
        java.io.FileInputStream(source).use { input ->
            contentResolver.openOutputStream(target.uri, "w")?.use { output ->
                input.copyTo(output)
                output.flush()
            } ?: return false
        }
        return true
    }

    private fun deleteDocumentPath(targetPath: String): Boolean {
        val target = resolveDocumentFileForFolderPath(targetPath) ?: return false
        return target.delete()
    }

    private fun ensureDocumentFileForFolderPath(
        folderPath: String,
        relativePath: String,
        overwrite: Boolean
    ): DocumentFile? {
        val folder = resolveDocumentFileForFolderPath(folderPath) ?: return null
        return ensureRelativeDocumentDirectory(folder, relativePath, overwrite)
    }

    private fun resolveDocumentFileForFolderPath(folderPath: String): DocumentFile? {
        val trimmed = folderPath.trim()
        if (!trimmed.startsWith("content://")) return null
        val syntheticIndex = trimmed.indexOf("::")
        if (syntheticIndex >= 0) {
            val base = trimmed.substring(0, syntheticIndex)
            val relative = trimmed.substring(syntheticIndex + 2).trim('/')
            val root = DocumentFile.fromTreeUri(this, Uri.parse(base)) ?: return null
            return resolveRelativeDocumentDirectory(root, relative)
        }
        val uri = Uri.parse(trimmed)
        return DocumentFile.fromTreeUri(this, uri)
            ?: DocumentFile.fromSingleUri(this, uri)?.takeIf { it.isDirectory }
    }

    private fun ensureRelativeDocumentDirectory(
        root: DocumentFile,
        relativeDirectory: String,
        overwrite: Boolean
    ): DocumentFile? {
        if (relativeDirectory.isBlank()) return root
        var current: DocumentFile? = root
        for (segment in relativeDirectory.split('/')) {
            if (segment.isBlank()) continue
            val next = current?.listFiles()?.firstOrNull {
                normalizeDisplayName(it.name?.trim().orEmpty()) == segment
            }
            current = when {
                next == null -> current?.createDirectory(segment)
                next.isDirectory -> next
                overwrite -> {
                    if (!next.delete()) return null
                    current?.createDirectory(segment)
                }
                else -> return null
            } ?: return null
        }
        return current
    }

    private fun resolveDocumentRenameTarget(targetPath: String): DocumentRenameTarget? {
        val trimmed = targetPath.trim()
        if (!trimmed.startsWith("content://")) return null

        val syntheticIndex = trimmed.indexOf("::")
        if (syntheticIndex >= 0) {
            val base = trimmed.substring(0, syntheticIndex)
            val relative = trimmed.substring(syntheticIndex + 2).trim('/')
            val rootUri = Uri.parse(base)
            val targetUri = if (relative.isBlank()) {
                documentUriForTreeRoot(rootUri)
            } else {
                resolveRelativeDocumentUri(rootUri, relative)
            } ?: return null
            val parentRelative = relative.substringBeforeLast('/', missingDelimiterValue = "")
            return DocumentRenameTarget(
                uri = targetUri,
                rootUri = rootUri,
                syntheticBase = base,
                syntheticParentRelative = parentRelative,
                treeRoot = false
            )
        }

        val uri = Uri.parse(trimmed)
        if (DocumentsContract.isTreeUri(uri) && trimmed.indexOf("/document/") < 0) {
            val documentUri = documentUriForTreeRoot(uri) ?: return null
            return DocumentRenameTarget(
                uri = documentUri,
                rootUri = uri,
                syntheticBase = null,
                syntheticParentRelative = null,
                treeRoot = true
            )
        }

        return DocumentRenameTarget(
            uri = uri,
            rootUri = treeUriBaseForDocumentUri(uri),
            syntheticBase = null,
            syntheticParentRelative = null,
            treeRoot = false
        )
    }

    private fun documentUriForTreeRoot(rootUri: Uri): Uri? {
        val documentId = startDocumentIdForTreeUri(rootUri) ?: return null
        return DocumentsContract.buildDocumentUriUsingTree(rootUri, documentId)
    }

    private fun treeUriBaseForDocumentUri(uri: Uri): Uri? {
        return try {
            val treeDocumentId = DocumentsContract.getTreeDocumentId(uri)
            val authority = uri.authority ?: return null
            DocumentsContract.buildTreeDocumentUri(authority, treeDocumentId)
        } catch (_: Exception) {
            null
        }
    }

    private fun documentIdForUri(uri: Uri): String? {
        return try {
            DocumentsContract.getDocumentId(uri)
        } catch (_: Exception) {
            startDocumentIdForTreeUri(uri)
        }
    }

    private fun resolveRelativeDocumentUri(rootUri: Uri, relativePath: String): Uri? {
        val startDocumentId = startDocumentIdForTreeUri(rootUri) ?: return null
        var currentDocumentId = startDocumentId
        val segments = relativePath.split('/').filter { it.isNotBlank() }
        if (segments.isEmpty()) {
            return DocumentsContract.buildDocumentUriUsingTree(rootUri, currentDocumentId)
        }
        for (segment in segments) {
            val child = findChildDocumentId(rootUri, currentDocumentId, segment) ?: return null
            currentDocumentId = child
        }
        return DocumentsContract.buildDocumentUriUsingTree(rootUri, currentDocumentId)
    }

    private fun findChildDocumentId(
        rootUri: Uri,
        parentDocumentId: String,
        displayName: String
    ): String? {
        val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            rootUri,
            parentDocumentId
        )
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME
        )
        return try {
            contentResolver.query(childUri, projection, null, null, null)?.use { cursor ->
                val documentIdIndex = cursor.getColumnIndex(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID
                )
                val nameIndex = cursor.getColumnIndex(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME
                )
                if (documentIdIndex < 0 || nameIndex < 0) return null
                while (cursor.moveToNext()) {
                    val name = normalizeDisplayName(cursor.getString(nameIndex)?.trim().orEmpty())
                    if (name != displayName) continue
                    return cursor.getString(documentIdIndex)
                }
                null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun listChildFoldersViaDocumentsContract(rootUri: Uri): List<String>? {
        val startDocumentId = startDocumentIdForTreeUri(rootUri) ?: return null
        val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            rootUri,
            startDocumentId
        )
        val folders = mutableListOf<Pair<String, String>>()
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE
        )
        return try {
            contentResolver.query(childUri, projection, null, null, null)?.use { cursor ->
                val documentIdIndex = cursor.getColumnIndex(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID
                )
                val nameIndex = cursor.getColumnIndex(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME
                )
                val mimeIndex = cursor.getColumnIndex(
                    DocumentsContract.Document.COLUMN_MIME_TYPE
                )
                if (documentIdIndex < 0 || mimeIndex < 0) return null
                while (cursor.moveToNext()) {
                    val mime = cursor.getString(mimeIndex)
                    if (mime != DocumentsContract.Document.MIME_TYPE_DIR) continue
                    val documentId = cursor.getString(documentIdIndex) ?: continue
                    val name = if (nameIndex >= 0) cursor.getString(nameIndex) else null
                    val childDocumentUri = DocumentsContract
                        .buildDocumentUriUsingTree(rootUri, documentId)
                        .toString()
                    folders.add(
                        Pair(
                            normalizeDisplayName(name?.trim().orEmpty()).ifBlank {
                                documentId
                            },
                            childDocumentUri
                        )
                    )
                }
            } ?: return null
            folders.sortedBy { it.first.lowercase(Locale.US) }.map { it.second }
        } catch (_: Exception) {
            null
        }
    }

    private fun scanDocumentTree(rootUri: Uri, output: MutableMap<String, ScannedTrack>) {
        if (scanDocumentTreeViaDocumentsContract(rootUri, output)) return

        val treeRoot = DocumentFile.fromTreeUri(this, rootUri)
        val root = treeRoot ?: DocumentFile.fromSingleUri(this, rootUri) ?: return
        if (!root.exists()) return

        val rootName = normalizeDisplayName(root.name?.ifBlank { "Folder" } ?: "Folder")
        data class Node(val dir: DocumentFile, val relative: String)
        val pending = ArrayDeque<Node>()
        pending.add(Node(root, ""))

        while (pending.isNotEmpty()) {
            val current = pending.removeFirst()
            val children = try {
                current.dir.listFiles()
            } catch (_: Exception) {
                emptyArray()
            }
            for (child in children) {
                val childName = normalizeDisplayName(child.name?.trim().orEmpty())
                if (child.isDirectory) {
                    val nextRelative = when {
                        current.relative.isEmpty() -> childName
                        childName.isEmpty() -> current.relative
                        else -> "${current.relative}/$childName"
                    }
                    pending.add(Node(child, nextRelative))
                    continue
                }
                if (!child.isFile || !isSupportedDocumentFile(child)) {
                    continue
                }

                val parentRelative = current.relative
                val groupTitle = if (parentRelative.isEmpty()) rootName else parentRelative.substringAfterLast('/')
                val groupSubtitle = if (parentRelative.isEmpty()) {
                    rootName
                } else {
                    "$rootName/$parentRelative"
                }
                val groupKey = if (parentRelative.isEmpty()) {
                    root.uri.toString()
                } else {
                    "${root.uri}::$parentRelative"
                }
                val safeName = childName.ifEmpty {
                    normalizeDisplayName(child.uri.lastPathSegment ?: "audio_file")
                }
                val title = safeName.substringBeforeLast('.', safeName)
                output.putIfAbsent(
                    child.uri.toString(),
                    ScannedTrack(
                        path = child.uri.toString(),
                        title = title,
                        groupKey = groupKey,
                        groupTitle = groupTitle.ifBlank { rootName },
                        groupSubtitle = groupSubtitle,
                        isVideo = isVideoFileName(safeName),
                        fileSizeBytes = child.length().takeIf { it >= 0 },
                        modifiedAtMs = child.lastModified().takeIf { it > 0 }
                    )
                )
            }
        }
    }

    private fun scanDocumentTreeViaDocumentsContract(
        rootUri: Uri,
        output: MutableMap<String, ScannedTrack>
    ): Boolean {
        val startDocumentId = startDocumentIdForTreeUri(rootUri) ?: return false
        val rootName = normalizeDisplayName(
            startDocumentId.substringAfterLast(':')
                .substringAfterLast('/')
                .ifBlank { "Folder" }
        )
        data class Node(val documentId: String, val relative: String)
        val pending = ArrayDeque<Node>()
        pending.add(Node(startDocumentId, ""))
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED
        )

        return try {
            while (pending.isNotEmpty()) {
                val current = pending.removeFirst()
                val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                    rootUri,
                    current.documentId
                )
                contentResolver.query(childUri, projection, null, null, null)?.use { cursor ->
                    val documentIdIndex = cursor.getColumnIndex(
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID
                    )
                    val nameIndex = cursor.getColumnIndex(
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME
                    )
                    val mimeIndex = cursor.getColumnIndex(
                        DocumentsContract.Document.COLUMN_MIME_TYPE
                    )
                    val sizeIndex = cursor.getColumnIndex(
                        DocumentsContract.Document.COLUMN_SIZE
                    )
                    val modifiedIndex = cursor.getColumnIndex(
                        DocumentsContract.Document.COLUMN_LAST_MODIFIED
                    )
                    if (documentIdIndex < 0 || mimeIndex < 0) return false

                    while (cursor.moveToNext()) {
                        val documentId = cursor.getString(documentIdIndex) ?: continue
                        val mime = cursor.getString(mimeIndex)
                        val displayName = normalizeDisplayName(
                            if (nameIndex >= 0) {
                                cursor.getString(nameIndex)?.trim().orEmpty()
                            } else {
                                ""
                            }
                        ).ifBlank {
                            normalizeDisplayName(documentId.substringAfterLast('/'))
                        }

                        if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                            val nextRelative = when {
                                current.relative.isEmpty() -> displayName
                                displayName.isEmpty() -> current.relative
                                else -> "${current.relative}/$displayName"
                            }
                            pending.add(Node(documentId, nextRelative))
                            continue
                        }
                        if (!isSupportedDocumentEntry(displayName, mime)) continue

                        val documentUri = DocumentsContract
                            .buildDocumentUriUsingTree(rootUri, documentId)
                            .toString()
                        val parentRelative = current.relative
                        val groupTitle = if (parentRelative.isEmpty()) {
                            rootName
                        } else {
                            parentRelative.substringAfterLast('/')
                        }
                        val groupSubtitle = if (parentRelative.isEmpty()) {
                            rootName
                        } else {
                            "$rootName/$parentRelative"
                        }
                        val groupKey = if (parentRelative.isEmpty()) {
                            rootUri.toString()
                        } else {
                            "${rootUri}::$parentRelative"
                        }
                        val title = displayName.substringBeforeLast('.', displayName)
                        val fileSizeBytes = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                            cursor.getLong(sizeIndex).takeIf { it >= 0 }
                        } else {
                            null
                        }
                        val modifiedAtMs = if (
                            modifiedIndex >= 0 &&
                            !cursor.isNull(modifiedIndex)
                        ) {
                            cursor.getLong(modifiedIndex).takeIf { it > 0 }
                        } else {
                            null
                        }

                        output.putIfAbsent(
                            documentUri,
                            ScannedTrack(
                                path = documentUri,
                                title = title,
                                groupKey = groupKey,
                                groupTitle = groupTitle.ifBlank { rootName },
                                groupSubtitle = groupSubtitle,
                                isVideo = isVideoFileName(displayName),
                                fileSizeBytes = fileSizeBytes,
                                modifiedAtMs = modifiedAtMs
                            )
                        )
                    }
                }
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun startDocumentIdForTreeUri(uri: Uri): String? {
        return try {
            val segments = uri.pathSegments
            val documentIndex = segments.indexOf("document")
            if (documentIndex >= 0 && documentIndex + 1 < segments.size) {
                segments[documentIndex + 1]
            } else {
                DocumentsContract.getTreeDocumentId(uri)
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun resolveTrackSubtitle(
        trackPath: String,
        groupKey: String?
    ): HashMap<String, String>? {
        if (!trackPath.startsWith("content://")) return null
        val rootUriString = when {
            !groupKey.isNullOrBlank() && groupKey.contains("::") ->
                groupKey.substringBefore("::")
            !groupKey.isNullOrBlank() && groupKey.startsWith("content://") -> groupKey
            else -> trackPath.substringBefore("/document/", missingDelimiterValue = trackPath)
        }
        val rootUri = Uri.parse(rootUriString)
        val trackUri = Uri.parse(trackPath)
        val trackDocumentId = startDocumentIdForTreeUri(trackUri) ?: return null
        val rootDocumentId = startDocumentIdForTreeUri(rootUri) ?: return null
        val parentDocumentId = if (trackDocumentId.contains('/')) {
            trackDocumentId.substringBeforeLast('/')
        } else {
            rootDocumentId
        }
        val audioStem = normalizeSubtitleMatchStem(
            trackDocumentId.substringAfterLast('/')
        )
        val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            rootUri,
            parentDocumentId
        )
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE
        )
        val candidates = mutableListOf<Triple<Int, String, Uri>>()

        try {
            contentResolver.query(childUri, projection, null, null, null)?.use { cursor ->
                val documentIdIndex = cursor.getColumnIndex(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID
                )
                val nameIndex = cursor.getColumnIndex(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME
                )
                val mimeIndex = cursor.getColumnIndex(
                    DocumentsContract.Document.COLUMN_MIME_TYPE
                )
                if (documentIdIndex < 0 || mimeIndex < 0) return null
                while (cursor.moveToNext()) {
                    val documentId = cursor.getString(documentIdIndex) ?: continue
                    val mime = cursor.getString(mimeIndex)
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) continue
                    val name = normalizeDisplayName(
                        if (nameIndex >= 0) {
                            cursor.getString(nameIndex)?.trim().orEmpty()
                        } else {
                            ""
                        }
                    ).ifBlank {
                        normalizeDisplayName(documentId.substringAfterLast('/'))
                    }
                    if (!isSupportedSubtitleEntry(name, mime)) continue
                    val stem = normalizeSubtitleMatchStem(name)
                    val rank = when {
                        stem == audioStem -> 0
                        stem.startsWith("$audioStem.") -> 1
                        stem.startsWith("${audioStem}_") -> 2
                        stem.startsWith("$audioStem ") -> 3
                        else -> 10
                    }
                    candidates.add(
                        Triple(
                            rank,
                            name.lowercase(Locale.US),
                            DocumentsContract.buildDocumentUriUsingTree(rootUri, documentId)
                        )
                    )
                }
            }
        } catch (_: Exception) {
            return null
        }

        val best = candidates
            .filter { it.first < 10 }
            .sortedWith(compareBy<Triple<Int, String, Uri>> { it.first }.thenBy { it.second })
            .firstOrNull() ?: return null
        val subtitleUri = best.third
        val subtitleName = best.second
        val text = readDocumentText(subtitleUri) ?: return null
        val extension = subtitleName.substringAfterLast('.', "")
        if (extension.isBlank()) return null
        return hashMapOf(
            "sourcePath" to subtitleUri.toString(),
            "extension" to extension,
            "text" to text
        )
    }

    private fun readDocumentText(uri: Uri): String? {
        return try {
            contentResolver.openInputStream(uri)?.bufferedReader(
                StandardCharsets.UTF_8
            )?.use { reader -> reader.readText() }
        } catch (_: Exception) {
            null
        }
    }

    private fun scanFileSystem(root: File, output: MutableMap<String, ScannedTrack>) {
        val pending = ArrayDeque<File>()
        pending.add(root)

        while (pending.isNotEmpty()) {
            val current = pending.removeFirst()
            val children = try {
                current.listFiles()
            } catch (_: Exception) {
                null
            } ?: continue

            for (child in children) {
                if (child.isDirectory) {
                    pending.add(child)
                    continue
                }
                if (!child.isFile || !isSupportedFileName(child.name)) {
                    continue
                }
                val parent = child.parentFile
                val parentPath = parent?.absolutePath ?: root.absolutePath
                val parentName = parent?.name?.ifBlank { parentPath } ?: parentPath
                val title = child.name.substringBeforeLast('.', child.name)
                output.putIfAbsent(
                    child.absolutePath,
                    ScannedTrack(
                        path = child.absolutePath,
                        title = title,
                        groupKey = parentPath,
                        groupTitle = parentName,
                        groupSubtitle = parentPath,
                        isVideo = isVideoFileName(child.name),
                        fileSizeBytes = child.length().takeIf { it >= 0 },
                        modifiedAtMs = child.lastModified().takeIf { it > 0 }
                    )
                )
            }
        }
    }

    private fun scanFileSystemAsDocumentTree(
        rootUri: Uri,
        root: File,
        output: MutableMap<String, ScannedTrack>
    ) {
        val rootDocumentId = startDocumentIdForTreeUri(rootUri) ?: return
        val rootName = normalizeDisplayName(root.name.ifBlank { "Folder" })
        val pending = ArrayDeque<File>()
        pending.add(root)

        while (pending.isNotEmpty()) {
            val current = pending.removeFirst()
            val children = try {
                current.listFiles()
            } catch (_: Exception) {
                null
            } ?: continue

            for (child in children) {
                if (child.isDirectory) {
                    pending.add(child)
                    continue
                }
                if (!child.isFile || !isSupportedFileName(child.name)) {
                    continue
                }

                val normalizedChildPath = child.absolutePath
                val relativePath = root.toPath()
                    .relativize(child.toPath())
                    .joinToString("/") { segment -> segment.toString() }
                if (relativePath.isBlank()) {
                    continue
                }

                val parentRelative = relativePath.substringBeforeLast(
                    '/',
                    missingDelimiterValue = ""
                )
                val groupTitle = if (parentRelative.isEmpty()) {
                    rootName
                } else {
                    parentRelative.substringAfterLast('/')
                }
                val groupSubtitle = if (parentRelative.isEmpty()) {
                    rootName
                } else {
                    "$rootName/$parentRelative"
                }
                val groupKey = if (parentRelative.isEmpty()) {
                    rootUri.toString()
                } else {
                    "${rootUri}::$parentRelative"
                }
                val documentId = if (parentRelative.isEmpty()) {
                    "$rootDocumentId/${child.name}"
                } else {
                    "$rootDocumentId/$relativePath"
                }
                val documentUri = DocumentsContract.buildDocumentUriUsingTree(
                    rootUri,
                    documentId
                ).toString()
                val safeName = normalizeDisplayName(child.name.ifBlank { "audio_file" })
                val title = safeName.substringBeforeLast('.', safeName)
                output.putIfAbsent(
                    documentUri,
                    ScannedTrack(
                        path = documentUri,
                        title = title,
                        groupKey = groupKey,
                        groupTitle = groupTitle.ifBlank { rootName },
                        groupSubtitle = groupSubtitle,
                        isVideo = isVideoFileName(safeName),
                        fileSizeBytes = child.length().takeIf { it >= 0 },
                        modifiedAtMs = child.lastModified().takeIf { it > 0 }
                    )
                )
            }
        }
    }

    private fun scanMediaStore(folderPath: String, output: MutableMap<String, ScannedTrack>) {
        val normalized = folderPath
            .replace('\\', '/')
            .trimEnd('/')
        if (normalized.isBlank()) return

        val projection = mutableListOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.RELATIVE_PATH,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.DATE_MODIFIED
        )
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            projection.add(MediaStore.Audio.Media.DATA)
        }

        val basePath = if (normalized.startsWith("/storage/emulated/0/")) {
            normalized.removePrefix("/storage/emulated/0/")
        } else if (normalized.startsWith("/sdcard/")) {
            normalized.removePrefix("/sdcard/")
        } else {
            null
        }?.trim('/')

        val relPrefix = basePath?.let {
            if (it.isEmpty()) null else "$it/"
        } ?: return

        val selection = "${MediaStore.Audio.Media.RELATIVE_PATH} LIKE ?"
        val selectionArgs = arrayOf("$relPrefix%")
        val audioUri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI

        contentResolver.query(
            audioUri,
            projection.toTypedArray(),
            selection,
            selectionArgs,
            null
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val displayNameIndex =
                cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
            val relativeIndex =
                cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.RELATIVE_PATH)
            val sizeIndex = cursor.getColumnIndex(MediaStore.Audio.Media.SIZE)
            val dateModifiedIndex =
                cursor.getColumnIndex(MediaStore.Audio.Media.DATE_MODIFIED)
            val dataIndex = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                cursor.getColumnIndex(MediaStore.Audio.Media.DATA)
            } else {
                -1
            }

            while (cursor.moveToNext()) {
                val id = cursor.getLong(idIndex)
                val displayName = normalizeDisplayName(cursor.getString(displayNameIndex) ?: "audio_file")
                if (!isSupportedFileName(displayName)) {
                    continue
                }
                val relative = normalizeDisplayName(cursor.getString(relativeIndex)?.trimEnd('/') ?: "")
                val title = displayName.substringBeforeLast('.', displayName)
                val fullPath = if (dataIndex >= 0) cursor.getString(dataIndex) else null
                val contentPath = ContentUris.withAppendedId(audioUri, id).toString()
                val fileSizeBytes = if (sizeIndex >= 0) cursor.getLong(sizeIndex) else null
                val modifiedAtMs = if (dateModifiedIndex >= 0) {
                    cursor.getLong(dateModifiedIndex).takeIf { it > 0 }?.times(1000L)
                } else {
                    null
                }

                val groupTitle = relative.substringAfterLast('/', missingDelimiterValue = relative)
                    .ifBlank { relPrefix.trimEnd('/').substringAfterLast('/') }
                val groupSubtitle = relative.ifBlank { relPrefix.trimEnd('/') }
                val groupKey = "ms:${relative.ifBlank { relPrefix }}"
                val playablePath = fullPath?.takeIf { it.isNotBlank() } ?: contentPath

                output.putIfAbsent(
                    playablePath,
                    ScannedTrack(
                        path = playablePath,
                        title = title,
                        groupKey = groupKey,
                        groupTitle = groupTitle.ifBlank { "Folder" },
                        groupSubtitle = groupSubtitle,
                        isVideo = isVideoFileName(displayName),
                        fileSizeBytes = fileSizeBytes,
                        modifiedAtMs = modifiedAtMs
                    )
                )
            }
        }
    }

    private fun normalizeDisplayName(raw: String): String {
        var text = raw.trim()
        if (text.isEmpty()) return text

        text = tryDecodePercent(text)

        val maybeFixed = tryLatin1ToUtf8(text)
        if (looksLikeMojibake(text) && !looksLikeMojibake(maybeFixed)) {
            text = maybeFixed
        }
        return text.trim()
    }

    private fun tryDecodePercent(value: String): String {
        if (!value.contains('%')) return value
        return try {
            URLDecoder.decode(value, StandardCharsets.UTF_8.name())
        } catch (_: Exception) {
            value
        }
    }

    private fun tryLatin1ToUtf8(value: String): String {
        return try {
            String(value.toByteArray(Charsets.ISO_8859_1), Charsets.UTF_8)
        } catch (_: Exception) {
            value
        }
    }

    private fun looksLikeMojibake(value: String): Boolean {
        if (value.isEmpty()) return false
        if (value.any { it == '\uFFFD' || it == '\u951F' }) return true
        return value.count { it.code in 0x00C0..0x00FF } >= 2
    }

    private fun isSupportedDocumentFile(file: DocumentFile): Boolean {
        val mime = file.type?.lowercase(Locale.US)
        if (mime != null && isSupportedMediaMime(mime)) {
            return true
        }
        val name = file.name ?: return false
        return isSupportedFileName(name)
    }

    private fun isSupportedDocumentEntry(name: String, mime: String?): Boolean {
        val normalizedMime = mime?.lowercase(Locale.US)
        if (normalizedMime != null && isSupportedMediaMime(normalizedMime)) {
            return true
        }
        return isSupportedFileName(name)
    }

    private fun isSupportedFileName(name: String): Boolean {
        val extension = name.substringAfterLast('.', "").lowercase(Locale.US)
        if (extension.isBlank()) {
            return true
        }
        if (blockedExtensions.contains(extension)) {
            return false
        }
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?.lowercase(Locale.US)
        if (mime == null) {
            return true
        }
        return isSupportedMediaMime(mime)
    }

    private fun isSupportedMediaMime(mime: String): Boolean {
        return mime.startsWith("audio/") ||
            mime.startsWith("video/") ||
            mime == "application/ogg"
    }

    private fun isVideoFileName(name: String): Boolean {
        val extension = name.substringAfterLast('.', "").lowercase(Locale.US)
        if (extension.isBlank()) {
            return false
        }
        if (extension in supportedVideoExtensions) {
            return true
        }
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?.lowercase(Locale.US)
        return mime?.startsWith("video/") == true
    }

    private data class DocumentImageCandidate(
        val uri: Uri,
        val name: String,
        val sortPath: String
    )

    private fun resolveTrackCover(
        trackPath: String,
        groupKey: String?,
        rootFolder: String?
    ): String? {
        if (!trackPath.startsWith("content://")) {
            return null
        }

        if (!rootFolder.isNullOrBlank() && rootFolder.startsWith("content://")) {
            val coverDirectory = resolveDocumentFileForFolderPath(rootFolder)
            if (coverDirectory != null && coverDirectory.exists()) {
                val cover = findPreferredCoverInDocumentTree(coverDirectory)
                if (cover != null) return cacheDocumentCover(cover, rootFolder)
            }
            // SAF fallback via File I/O.
            val filePath = contentUriToFilePath(rootFolder)
            if (filePath != null) {
                return findPreferredCoverViaFile(filePath, trackPath)
            }
            return null
        }

        val rootTreeUri = when {
            groupKey.isNullOrBlank() -> null
            groupKey.contains("::") -> groupKey.substringBefore("::")
            else -> groupKey
        }?.takeIf { it.startsWith("content://") } ?: return null

        val relativeDirectory = when {
            groupKey.isNullOrBlank() -> ""
            groupKey.contains("::") -> groupKey.substringAfter("::", "")
            else -> ""
        }

        val treeRoot = DocumentFile.fromTreeUri(this, Uri.parse(rootTreeUri))
            ?: DocumentFile.fromSingleUri(this, Uri.parse(rootTreeUri))
        if (treeRoot != null && treeRoot.exists()) {
            val candidateDirectories = resolveCandidateDocumentDirectories(
                treeRoot,
                relativeDirectory
            )
            candidateDirectories.forEach { directory ->
                val cover = findPreferredCoverInDocumentDirectory(directory) ?: return@forEach
                return cacheDocumentCover(cover, trackPath)
            }
            return null
        }

        // SAF access failed (e.g. after a File.renameTo) — fall back to File I/O.
        val folderPath = if (relativeDirectory.isBlank()) {
            contentUriToFilePath(rootTreeUri)
        } else {
            val base = contentUriToFilePath(rootTreeUri) ?: return null
            java.io.File(base, relativeDirectory).absolutePath
        } ?: return null
        return findPreferredCoverViaFile(folderPath, trackPath)
    }

    private val defaultMaxApplicationCacheBytes: Long = 300L * 1024L * 1024L
    private val cachePolicyPrefsName = "app_cache_policy"
    private val maxCacheBytesKey = "max_cache_bytes"

    private fun maxApplicationCacheBytes(): Long {
        return getSharedPreferences(cachePolicyPrefsName, Context.MODE_PRIVATE)
            .getLong(maxCacheBytesKey, defaultMaxApplicationCacheBytes)
            .coerceAtLeast(1L)
    }

    private fun setMaxApplicationCacheBytes(maxBytes: Long) {
        getSharedPreferences(cachePolicyPrefsName, Context.MODE_PRIVATE)
            .edit()
            .putLong(maxCacheBytesKey, maxBytes.coerceAtLeast(1L))
            .apply()
    }

    private fun clearApplicationCache(): Long {
        var deletedBytes = 0L
        applicationCacheRoots().forEach { root ->
            if (!root.exists()) return@forEach
            root.listFiles()?.forEach { child ->
                deletedBytes += deleteCacheEntity(child)
            }
        }
        return deletedBytes.coerceAtMost(Int.MAX_VALUE.toLong())
    }

    private fun deleteCacheEntity(entity: File): Long {
        val size = cacheEntitySize(entity)
        try {
            if (entity.isDirectory) {
                entity.deleteRecursively()
            } else {
                entity.delete()
            }
        } catch (_: Exception) {
        }
        return if (entity.exists()) 0L else size
    }

    private fun enforceApplicationCacheLimit(
        maxBytes: Long = maxApplicationCacheBytes()
    ) {
        val files = applicationCacheRoots()
            .filter { it.exists() }
            .flatMap(::collectCacheFiles)
            .distinctBy { it.absolutePath }
        if (files.size <= 1) return

        var totalBytes = files.sumOf { file -> file.length().coerceAtLeast(0L) }
        var remainingFiles = files.size
        files.sortedBy { it.lastModified() }.forEach { file ->
            if (totalBytes <= maxBytes || remainingFiles <= 1) return@forEach
            val size = file.length().coerceAtLeast(0L)
            try {
                if (file.delete()) {
                    totalBytes -= size
                    remainingFiles -= 1
                }
            } catch (_: Exception) {
            }
        }
        applicationCacheRoots().forEach(::deleteEmptyCacheDirectories)
    }

    private fun applicationCacheRoots(): List<File> {
        return listOfNotNull(cacheDir, externalCacheDir)
    }

    private fun collectCacheFiles(root: File): List<File> {
        val children = root.listFiles() ?: return emptyList()
        val result = mutableListOf<File>()
        children.forEach { child ->
            if (child.isDirectory) {
                result.addAll(collectCacheFiles(child))
            } else if (child.isFile) {
                result.add(child)
            }
        }
        return result
    }

    private fun cacheEntitySize(entity: File): Long {
        return try {
            if (entity.isFile) {
                entity.length().coerceAtLeast(0L)
            } else {
                entity.listFiles()?.sumOf(::cacheEntitySize) ?: 0L
            }
        } catch (_: Exception) {
            0L
        }
    }

    private fun deleteEmptyCacheDirectories(root: File) {
        root.listFiles()?.forEach { child ->
            if (child.isDirectory) {
                deleteEmptyCacheDirectories(child)
                if (child.listFiles()?.isEmpty() == true) {
                    try {
                        child.delete()
                    } catch (_: Exception) {
                    }
                }
            }
        }
    }

    private fun touchCacheFile(file: File) {
        try {
            file.setLastModified(System.currentTimeMillis())
        } catch (_: Exception) {
        }
    }

    /**
     * Finds the preferred cover image in [folderPath] using File I/O and
     * caches it, returning the cached path.
     */
    private fun findPreferredCoverViaFile(folderPath: String, cacheKey: String): String? {
        val dir = java.io.File(folderPath)
        if (!dir.exists() || !dir.isDirectory) return null
        val files = dir.listFiles() ?: return null
        val imageExtensions = setOf("jpg", "jpeg", "png", "webp")
        val preferredNames = listOf("cover", "folder", "front", "album", "artwork", "poster")
        // Preferred names first, then any image.
        val preferred = files.firstOrNull { f ->
            val ext = f.extension.lowercase(Locale.US)
            if (!imageExtensions.contains(ext)) return@firstOrNull false
            val stem = f.nameWithoutExtension.lowercase(Locale.US)
            preferredNames.any { stem == it || stem.startsWith(it) }
        } ?: files.firstOrNull { f ->
            imageExtensions.contains(f.extension.lowercase(Locale.US))
        } ?: return null
        return cacheFileAsCover(preferred, cacheKey)
    }

    /**
     * Copies [imageFile] into the cover cache and returns the cached path.
     */
    private fun cacheFileAsCover(imageFile: java.io.File, cacheKey: String): String? {
        val coverCacheDir = java.io.File(cacheDir, "nameless_audio_covers")
        if (!coverCacheDir.exists()) coverCacheDir.mkdirs()
        val outputFile = java.io.File(
            coverCacheDir,
            "cover_${kotlin.math.abs(cacheKey.hashCode())}.jpg"
        )
        if (outputFile.exists() && outputFile.length() > 0) {
            touchCacheFile(outputFile)
            return outputFile.absolutePath
        }
        return try {
            imageFile.copyTo(outputFile, overwrite = true)
            touchCacheFile(outputFile)
            enforceApplicationCacheLimit()
            outputFile.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun resolveVideoFrame(
        trackPath: String,
        modifiedAtMs: Long?
    ): String? {
        val coverCacheDir = File(this.cacheDir, "nameless_audio_covers")
        if (!coverCacheDir.exists()) {
            coverCacheDir.mkdirs()
        }
        val cacheKey = buildString {
            append(trackPath)
            if (modifiedAtMs != null) {
                append('|')
                append(modifiedAtMs)
            }
        }
        val outputFile = File(
            coverCacheDir,
            "video_frame_${kotlin.math.abs(cacheKey.hashCode())}.jpg"
        )
        if (outputFile.exists() && outputFile.length() > 0) {
            touchCacheFile(outputFile)
            return outputFile.absolutePath
        }

        var retriever: MediaMetadataRetriever? = null
        try {
            retriever = MediaMetadataRetriever()
            if (trackPath.startsWith("content://")) {
                retriever.setDataSource(this, Uri.parse(trackPath))
            } else {
                retriever.setDataSource(trackPath)
            }
            val bitmap = retriever.getFrameAtTime(
                1_000_000L,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            ) ?: retriever.frameAtTime ?: return null
            FileOutputStream(outputFile).use { output ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 88, output)
                output.flush()
            }
            touchCacheFile(outputFile)
            enforceApplicationCacheLimit()
            bitmap.recycle()
            return outputFile.absolutePath
        } catch (_: Exception) {
            if (outputFile.exists()) {
                outputFile.delete()
            }
            return null
        } finally {
            try {
                retriever?.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun discoverRootImages(
        trackPath: String,
        groupKey: String?,
        rootFolder: String?
    ): List<String> {
        if (!rootFolder.isNullOrBlank() && rootFolder.startsWith("content://")) {
            val root = resolveDocumentFileForFolderPath(rootFolder) ?: return emptyList()
            val candidates = collectImageDocumentsRecursively(root)
            if (candidates.isEmpty()) return emptyList()
            return candidates.mapNotNull { candidate ->
                cacheDocumentCover(candidate.file, "$trackPath|${candidate.sortPath}")
            }
        }

        val rootUriString = when {
            !groupKey.isNullOrBlank() && groupKey.contains("::") ->
                groupKey.substringBefore("::")
            !groupKey.isNullOrBlank() && groupKey.startsWith("content://") -> groupKey
            else -> null
        } ?: return emptyList()
        val rootUri = Uri.parse(rootUriString)
        val candidates = collectImageDocumentsViaDocumentsContract(rootUri)
        if (candidates.isEmpty()) return emptyList()
        return candidates.mapNotNull { candidate ->
            cacheDocumentImage(
                uri = candidate.uri,
                name = candidate.name,
                cacheKey = "$trackPath|${candidate.uri}"
            )
        }
    }

    private fun collectImageDocumentsViaDocumentsContract(
        rootUri: Uri
    ): List<DocumentImageCandidate> {
        val startDocumentId = startDocumentIdForTreeUri(rootUri) ?: return emptyList()
        data class Node(val documentId: String, val relative: String)
        val pending = ArrayDeque<Node>()
        pending.add(Node(startDocumentId, ""))
        val images = mutableListOf<DocumentImageCandidate>()
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE
        )

        try {
            while (pending.isNotEmpty()) {
                val current = pending.removeFirst()
                val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                    rootUri,
                    current.documentId
                )
                contentResolver.query(childUri, projection, null, null, null)?.use { cursor ->
                    val documentIdIndex = cursor.getColumnIndex(
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID
                    )
                    val nameIndex = cursor.getColumnIndex(
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME
                    )
                    val mimeIndex = cursor.getColumnIndex(
                        DocumentsContract.Document.COLUMN_MIME_TYPE
                    )
                    if (documentIdIndex < 0 || mimeIndex < 0) return emptyList()

                    while (cursor.moveToNext()) {
                        val documentId = cursor.getString(documentIdIndex) ?: continue
                        val mime = cursor.getString(mimeIndex)
                        val name = normalizeDisplayName(
                            if (nameIndex >= 0) {
                                cursor.getString(nameIndex)?.trim().orEmpty()
                            } else {
                                ""
                            }
                        ).ifBlank {
                            normalizeDisplayName(documentId.substringAfterLast('/'))
                        }

                        if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                            val nextRelative = when {
                                current.relative.isEmpty() -> name
                                name.isEmpty() -> current.relative
                                else -> "${current.relative}/$name"
                            }
                            pending.add(Node(documentId, nextRelative))
                            continue
                        }
                        if (!isSupportedImageEntry(name, mime)) continue
                        val documentUri = DocumentsContract
                            .buildDocumentUriUsingTree(rootUri, documentId)
                        val sortPath = if (current.relative.isEmpty()) {
                            name
                        } else {
                            "${current.relative}/$name"
                        }
                        images.add(DocumentImageCandidate(documentUri, name, sortPath))
                    }
                }
            }
        } catch (_: Exception) {
            return emptyList()
        }

        return images.sortedWith { left, right ->
            val priority = compareCoverNames(left.name, right.name)
            if (priority != 0) priority else left.sortPath.lowercase(Locale.US)
                .compareTo(right.sortPath.lowercase(Locale.US))
        }
    }

    private fun resolveCandidateDocumentDirectories(
        root: DocumentFile,
        relativeDirectory: String
    ): List<DocumentFile> {
        val visited = mutableListOf<DocumentFile>()
        var current: DocumentFile = root
        visited.add(current)
        if (relativeDirectory.isBlank()) {
            return visited.asReversed()
        }
        for (segment in relativeDirectory.split('/')) {
            if (segment.isBlank()) continue
            val next = current.listFiles().firstOrNull {
                it.isDirectory && normalizeDisplayName(it.name?.trim().orEmpty()) == segment
            } ?: break
            current = next
            visited.add(current)
        }
        return visited.asReversed()
    }

    private fun resolveRelativeDocumentDirectory(
        root: DocumentFile,
        relativeDirectory: String
    ): DocumentFile? {
        if (relativeDirectory.isBlank()) return root
        var current: DocumentFile? = root
        for (segment in relativeDirectory.split('/')) {
            if (segment.isBlank()) continue
            current = current?.listFiles()?.firstOrNull {
                it.isDirectory && normalizeDisplayName(it.name?.trim().orEmpty()) == segment
            } ?: return null
        }
        return current
    }

    private fun findPreferredCoverInDocumentDirectory(directory: DocumentFile): DocumentFile? {
        val images = collectImageDocuments(directory)
        if (images.isEmpty()) return null
        return images.sortedWith { left, right ->
            compareCoverNames(
                normalizeDisplayName(left.name ?: left.uri.lastPathSegment ?: ""),
                normalizeDisplayName(right.name ?: right.uri.lastPathSegment ?: "")
            )
        }.firstOrNull()
    }

    private data class DocumentCoverCandidate(
        val file: DocumentFile,
        val sortPath: String
    )

    private fun findPreferredCoverInDocumentTree(directory: DocumentFile): DocumentFile? {
        val images = collectImageDocumentsRecursively(directory)
        if (images.isEmpty()) return null
        return images.sortedWith { left, right ->
            val leftName = normalizeDisplayName(left.file.name ?: left.file.uri.lastPathSegment ?: "")
            val rightName = normalizeDisplayName(right.file.name ?: right.file.uri.lastPathSegment ?: "")
            val priority = compareCoverNames(leftName, rightName)
            if (priority != 0) priority else left.sortPath.lowercase(Locale.US)
                .compareTo(right.sortPath.lowercase(Locale.US))
        }.firstOrNull()?.file
    }

    private fun collectImageDocuments(directory: DocumentFile): List<DocumentFile> {
        return try {
            val images = mutableListOf<DocumentFile>()
            for (child in directory.listFiles()) {
                if (child.isFile && isSupportedImageDocument(child)) {
                    images.add(child)
                }
            }
            images
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun collectImageDocumentsRecursively(directory: DocumentFile): List<DocumentCoverCandidate> {
        data class Node(val folder: DocumentFile, val relative: String)

        return try {
            val pending = ArrayDeque<Node>()
            val images = mutableListOf<DocumentCoverCandidate>()
            pending.add(Node(directory, ""))

            while (pending.isNotEmpty()) {
                val current = pending.removeFirst()
                for (child in current.folder.listFiles()) {
                    val name = normalizeDisplayName(child.name?.trim().orEmpty()).ifBlank {
                        normalizeDisplayName(child.uri.lastPathSegment ?: "")
                    }
                    if (child.isDirectory) {
                        val nextRelative = when {
                            current.relative.isEmpty() -> name
                            name.isEmpty() -> current.relative
                            else -> "${current.relative}/$name"
                        }
                        pending.add(Node(child, nextRelative))
                        continue
                    }
                    if (!child.isFile || !isSupportedImageDocument(child)) continue
                    val sortPath = if (current.relative.isEmpty()) {
                        name
                    } else {
                        "${current.relative}/$name"
                    }
                    images.add(DocumentCoverCandidate(file = child, sortPath = sortPath))
                }
            }

            images
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun isSupportedImageDocument(file: DocumentFile): Boolean {
        val mime = file.type?.lowercase(Locale.US)
        if (mime != null && mime.startsWith("image/")) {
            return true
        }
        val extension = file.name
            ?.substringAfterLast('.', "")
            ?.lowercase(Locale.US)
            .orEmpty()
        return extension in supportedImageExtensions
    }

    private fun isSupportedImageEntry(name: String, mime: String?): Boolean {
        val normalizedMime = mime?.lowercase(Locale.US)
        if (normalizedMime != null && normalizedMime.startsWith("image/")) {
            return true
        }
        val extension = name.substringAfterLast('.', "").lowercase(Locale.US)
        return extension in supportedImageExtensions
    }

    private fun isSupportedSubtitleEntry(name: String, mime: String?): Boolean {
        val normalizedMime = mime?.lowercase(Locale.US)
        if (normalizedMime == "text/vtt" ||
            normalizedMime == "application/x-subrip" ||
            normalizedMime == "text/plain"
        ) {
            return true
        }
        val extension = name.substringAfterLast('.', "").lowercase(Locale.US)
        return extension in supportedSubtitleExtensions
    }

    private fun normalizeSubtitleMatchStem(name: String): String {
        var current = normalizeDisplayName(name).lowercase(Locale.US)
        while (current.isNotEmpty()) {
            val extension = current.substringAfterLast('.', "")
            if (extension.isEmpty()) {
                break
            }
            if (extension !in supportedSubtitleExtensions &&
                extension !in subtitleMatchMediaExtensions
            ) {
                break
            }
            current = current.substringBeforeLast('.')
        }
        return current
    }

    private fun compareCoverNames(leftNameRaw: String, rightNameRaw: String): Int {
        val leftName = leftNameRaw.substringBeforeLast('.', leftNameRaw).lowercase(Locale.US)
        val rightName = rightNameRaw.substringBeforeLast('.', rightNameRaw).lowercase(Locale.US)
        val scoreCompare = coverPriority(leftName).compareTo(coverPriority(rightName))
        if (scoreCompare != 0) return scoreCompare
        val nameCompare = leftName.compareTo(rightName)
        if (nameCompare != 0) return nameCompare
        return leftNameRaw.lowercase(Locale.US).compareTo(rightNameRaw.lowercase(Locale.US))
    }

    private fun coverPriority(baseName: String): Int {
        val exactMatchIndex = preferredCoverBasenames.indexOf(baseName)
        if (exactMatchIndex >= 0) {
            return exactMatchIndex
        }
        for (i in preferredCoverBasenames.indices) {
            if (baseName.contains(preferredCoverBasenames[i])) {
                return 100 + i
            }
        }
        return 200
    }

    private fun cacheDocumentCover(file: DocumentFile, trackPath: String): String? {
        val extension = file.name
            ?.substringAfterLast('.', "")
            ?.ifBlank { "img" }
            ?: "img"
        val coverDir = File(cacheDir, "nameless_audio_covers")
        if (!coverDir.exists()) {
            coverDir.mkdirs()
        }
        val outputFile = File(
            coverDir,
            "cover_${kotlin.math.abs(trackPath.hashCode())}.$extension"
        )
        if (outputFile.exists() && outputFile.length() > 0) {
            touchCacheFile(outputFile)
            return outputFile.absolutePath
        }

        return try {
            contentResolver.openInputStream(file.uri)?.use { input ->
                FileOutputStream(outputFile).use { output ->
                    input.copyTo(output)
                    output.flush()
                }
            } ?: return null
            touchCacheFile(outputFile)
            enforceApplicationCacheLimit()
            outputFile.absolutePath
        } catch (_: Exception) {
            if (outputFile.exists()) {
                outputFile.delete()
            }
            null
        }
    }

    private fun cacheDocumentImage(uri: Uri, name: String, cacheKey: String): String? {
        val extension = name.substringAfterLast('.', "").ifBlank { "img" }
        val coverDir = File(cacheDir, "nameless_audio_covers")
        if (!coverDir.exists()) {
            coverDir.mkdirs()
        }
        val outputFile = File(
            coverDir,
            "cover_${kotlin.math.abs(cacheKey.hashCode())}.$extension"
        )
        if (outputFile.exists() && outputFile.length() > 0) {
            touchCacheFile(outputFile)
            return outputFile.absolutePath
        }

        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(outputFile).use { output ->
                    input.copyTo(output)
                    output.flush()
                }
            } ?: return null
            touchCacheFile(outputFile)
            enforceApplicationCacheLimit()
            outputFile.absolutePath
        } catch (_: Exception) {
            if (outputFile.exists()) {
                outputFile.delete()
            }
            null
        }
    }
}
