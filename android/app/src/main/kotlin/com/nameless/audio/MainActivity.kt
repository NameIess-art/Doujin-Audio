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
import android.net.Uri
import android.os.Build
import android.os.Bundle
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
private val supportedImageExtensions = setOf(
    "jpg", "jpeg", "png", "webp", "bmp", "gif"
)

private val supportedSubtitleExtensions = setOf(
    "vtt", "webvtt", "lrc", "srt", "ass", "ssa"
)

private val preferredCoverBasenames = listOf(
    "cover", "folder", "front", "album", "artwork", "poster"
)

private const val audioDetailBackupFileName = ".nameless-audio.json"

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
        "audio/opus"
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
                    "resolveTrackCover" -> {
                        val trackPath = call.argument<String>("path")
                        val groupKey = call.argument<String>("groupKey")
                        if (trackPath.isNullOrBlank()) {
                            result.error("invalid_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val coverPath = resolveTrackCover(trackPath, groupKey)
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
            // Pure playback also needs a foreground service on some OEM ROMs,
            // otherwise the process is still eligible to be culled after screen-off.
            if (keepForegroundServiceAlive) {
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
                            keepForegroundServiceAlive
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
            PlaybackWakeLockController.sync(applicationContext, enabled)
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
        // Only cancel the notification if the unified notification controller
        // is NOT actively managing it; otherwise the cancel would remove the
        // rich playback notification and cause a visible collapse/reappear.
        if (!UnifiedPlaybackNotificationController.hasUnifiedNotifications()) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            manager?.cancel(UnifiedPlaybackNotificationController.foregroundServiceNotificationId)
        }
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
        val folder = resolveDocumentFileForFolderPath(folderPath) ?: return null
        val backup = folder.listFiles().firstOrNull {
            it.isFile && it.name == audioDetailBackupFileName
        } ?: return null
        return contentResolver.openInputStream(backup.uri)?.use { input ->
            input.bufferedReader(Charsets.UTF_8).readText()
        }
    }

    private fun writeAudioDetailBackup(folderPath: String, json: String): Boolean {
        val folder = resolveDocumentFileForFolderPath(folderPath) ?: return false
        val backup = folder.listFiles().firstOrNull {
            it.isFile && it.name == audioDetailBackupFileName
        } ?: folder.createFile("application/json", audioDetailBackupFileName)
            ?: return false
        contentResolver.openOutputStream(backup.uri, "wt")?.use { output ->
            output.write(json.toByteArray(Charsets.UTF_8))
            output.flush()
        } ?: return false
        return true
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
        val audioStem = normalizeDisplayName(
            trackDocumentId.substringAfterLast('/').substringBeforeLast('.')
        ).lowercase(Locale.US)
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
                    val stem = name.substringBeforeLast('.', name).lowercase(Locale.US)
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
        if (mime != null && (mime.startsWith("audio/") || mime == "application/ogg")) {
            return true
        }
        val name = file.name ?: return false
        return isSupportedFileName(name)
    }

    private fun isSupportedDocumentEntry(name: String, mime: String?): Boolean {
        val normalizedMime = mime?.lowercase(Locale.US)
        if (normalizedMime != null &&
            (normalizedMime.startsWith("audio/") || normalizedMime == "application/ogg")
        ) {
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
        return mime.startsWith("audio/") || mime == "application/ogg"
    }

    private data class DocumentImageCandidate(
        val uri: Uri,
        val name: String,
        val sortPath: String
    )

    private fun resolveTrackCover(trackPath: String, groupKey: String?): String? {
        if (!trackPath.startsWith("content://")) {
            return null
        }

        val discovered = discoverRootImages(trackPath, groupKey, null)
        if (discovered.isNotEmpty()) return discovered.first()

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
            ?: return null
        if (!treeRoot.exists()) return null

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

    private fun discoverRootImages(
        trackPath: String,
        groupKey: String?,
        rootFolder: String?
    ): List<String> {
        val rootUriString = when {
            !rootFolder.isNullOrBlank() && rootFolder.startsWith("content://") -> rootFolder
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

    private fun collectImageDocuments(directory: DocumentFile): List<DocumentFile> {
        return try {
            val images = mutableListOf<DocumentFile>()
            val pending = java.util.ArrayDeque<DocumentFile>()
            pending.add(directory)
            while (pending.isNotEmpty()) {
                val current = pending.removeFirst()
                for (child in current.listFiles()) {
                    when {
                        child.isDirectory -> pending.addLast(child)
                        child.isFile && isSupportedImageDocument(child) -> images.add(child)
                    }
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
            return outputFile.absolutePath
        }

        return try {
            contentResolver.openInputStream(file.uri)?.use { input ->
                FileOutputStream(outputFile).use { output ->
                    input.copyTo(output)
                    output.flush()
                }
            } ?: return null
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
            return outputFile.absolutePath
        }

        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(outputFile).use { output ->
                    input.copyTo(output)
                    output.flush()
                }
            } ?: return null
            outputFile.absolutePath
        } catch (_: Exception) {
            if (outputFile.exists()) {
                outputFile.delete()
            }
            null
        }
    }
}
