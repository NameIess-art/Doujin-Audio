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

private val preferredCoverBasenames = listOf(
    "cover", "folder", "front", "album", "artwork", "poster"
)

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
                        subtitleOverlayService?.updateSubtitle(text)
                        result.success(true)
                    }
                    "updateStyle" -> {
                        val fontSize = call.argument<Double>("fontSize")?.toFloat() ?: 18f
                        val backgroundColor = call.argument<String>("backgroundColor") ?: "#80000000"
                        val textColor = call.argument<String>("textColor") ?: "#FFFFFF"
                        subtitleOverlayService?.setStyle(fontSize, backgroundColor, textColor)
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
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("scan_failed", e.message ?: "unknown error", null)
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
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
    }

    private fun buildPickAudioFolderIntent(): Intent {
        return Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
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
        if (!canRead) return
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION
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
        if (UnifiedPlaybackNotificationController.activeNotificationCount == 0) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            manager?.cancel(1107)
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
        stopSubtitleService()
        super.onDestroy()
    }

    private val subtitleServiceConnection = object : android.content.ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: android.os.IBinder?) {
            val binder = service as SubtitleOverlayService.LocalBinder
            subtitleOverlayService = binder.getService()
            isSubtitleServiceBound = true
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
        }
    }

    private fun stopSubtitleService() {
        if (isSubtitleServiceBound) {
            unbindService(subtitleServiceConnection)
            isSubtitleServiceBound = false
            subtitleOverlayService = null
        }
        stopService(Intent(this, SubtitleOverlayService::class.java))
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

    private fun scanDocumentTree(rootUri: Uri, output: MutableMap<String, ScannedTrack>) {
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
        val pattern = Regex("[脙脗脜脝脟脨脩脴脵脷脹脺脻脼脽脿谩芒茫盲氓忙莽猫茅锚毛矛铆卯茂冒帽貌贸么玫枚酶霉煤没眉媒镁每锟絔")
        return pattern.containsMatchIn(value)
    }

    private fun isSupportedDocumentFile(file: DocumentFile): Boolean {
        val mime = file.type?.lowercase(Locale.US)
        if (mime != null && (mime.startsWith("audio/") || mime == "application/ogg")) {
            return true
        }
        val name = file.name ?: return false
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

    private fun resolveTrackCover(trackPath: String, groupKey: String?): String? {
        if (!trackPath.startsWith("content://")) {
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
}
