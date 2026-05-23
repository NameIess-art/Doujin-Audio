package com.nameless.audio

import android.app.AlarmManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {
    companion object {
        const val notificationSessionIdExtra = "notificationSessionId"
        const val openSessionFromNotificationAction =
            "com.nameless.audio.OPEN_SESSION_FROM_NOTIFICATION"
    }

    private var notificationsMethodChannel: MethodChannel? = null
    private var pendingNotificationSessionId: String? = null
    private val playbackKeepAliveCoordinator by lazy {
        PlaybackKeepAliveCoordinator(applicationContext)
    }
    private val subtitleOverlayCoordinator by lazy {
        SubtitleOverlayCoordinator(this)
    }
    private val audioPickerCoordinator by lazy {
        AudioPickerCoordinator(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val nativePlaybackBridge = NativePlaybackBridge(applicationContext)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PlatformChannelNames.NATIVE_PLAYBACK
        ).setMethodCallHandler(nativePlaybackBridge)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PlatformChannelNames.NATIVE_PLAYBACK_EVENTS
        ).setStreamHandler(nativePlaybackBridge)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PlatformChannelNames.POWER)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    PowerMethods.SET_KEEP_CPU_AWAKE -> {
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
                    PowerMethods.CAN_MANAGE_ALL_FILES_ACCESS -> {
                        result.success(canManageAllFilesAccess())
                    }
                    PowerMethods.OPEN_MANAGE_ALL_FILES_ACCESS_SETTINGS -> {
                        result.success(openManageAllFilesAccessSettings())
                    }
                    PowerMethods.STOP_PLAYBACK_KEEP_ALIVE -> {
                        stopPlaybackKeepAliveService()
                        result.success(null)
                    }
                    PowerMethods.IS_IGNORING_BATTERY_OPTIMIZATIONS -> {
                        result.success(isIgnoringBatteryOptimizations())
                    }
                    PowerMethods.OPEN_BATTERY_OPTIMIZATION_SETTINGS -> {
                        result.success(openBatteryOptimizationSettings())
                    }
                    PowerMethods.OPEN_BACKGROUND_RUN_SETTINGS -> {
                        result.success(openBackgroundRunSettings())
                    }
                    PowerMethods.CAN_SCHEDULE_EXACT_ALARMS -> {
                        result.success(canScheduleExactAlarms())
                    }
                    PowerMethods.OPEN_EXACT_ALARM_SETTINGS -> {
                        result.success(openExactAlarmSettings())
                    }
                    PowerMethods.GET_NATIVE_TIMER_RUNTIME_STATE -> {
                        result.success(getNativeTimerRuntimeState())
                    }
                    PowerMethods.EXECUTE_TIMER_EXPIRED_NOW -> {
                        val generation = call.argument<Int>("generation")
                        PlaybackTimerAlarmScheduler.executeNow(
                            applicationContext,
                            PlaybackTimerAlarmScheduler.actionTimerExpired,
                            generation
                        )
                        result.success(true)
                    }
                    PowerMethods.EXECUTE_AUTO_RESUME_NOW -> {
                        val generation = call.argument<Int>("generation")
                        PlaybackTimerAlarmScheduler.executeNow(
                            applicationContext,
                            PlaybackTimerAlarmScheduler.actionAutoResume,
                            generation
                        )
                        result.success(true)
                    }
                    PowerMethods.SYNC_PLAYBACK_TIMER_ALARMS -> {
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PlatformChannelNames.UPDATE)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    UpdateMethods.GET_APP_VERSION -> {
                        result.success(currentAppVersion())
                    }
                    UpdateMethods.INSTALL_APK -> {
                        val apkPath = call.argument<String>("path")
                        result.success(installDownloadedApk(apkPath))
                    }
                    UpdateMethods.CAN_INSTALL_UNKNOWN_APPS -> {
                        result.success(canInstallUnknownApps())
                    }
                    UpdateMethods.OPEN_INSTALL_PERMISSION_SETTINGS -> {
                        result.success(openInstallPermissionSettings())
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PlatformChannelNames.SUBTITLE_OVERLAY)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    SubtitleOverlayMethods.CAN_DRAW_OVERLAYS -> {
                        result.success(subtitleOverlayCoordinator.canDrawOverlays())
                    }
                    SubtitleOverlayMethods.OPEN_OVERLAY_SETTINGS -> {
                        result.success(subtitleOverlayCoordinator.openOverlaySettings())
                    }
                    SubtitleOverlayMethods.START_OVERLAY -> {
                        subtitleOverlayCoordinator.start()
                        result.success(true)
                    }
                    SubtitleOverlayMethods.STOP_OVERLAY -> {
                        subtitleOverlayCoordinator.stop()
                        result.success(true)
                    }
                    SubtitleOverlayMethods.UPDATE_SUBTITLE -> {
                        val text = call.argument<String>("text") ?: ""
                        subtitleOverlayCoordinator.updateSubtitle(text)
                        result.success(true)
                    }
                    SubtitleOverlayMethods.UPDATE_STYLE -> {
                        val fontSize = call.argument<Double>("fontSize")?.toFloat() ?: 18f
                        val backgroundColor = call.argument<String>("backgroundColor") ?: "#80000000"
                        val textColor = call.argument<String>("textColor") ?: "#FFFFFF"
                        subtitleOverlayCoordinator.updateStyle(
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
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PlatformChannelNames.NOTIFICATIONS)
        capturePendingNotificationSession(intent)
        notificationsMethodChannel?.setMethodCallHandler(
            NotificationsMethodHandler(this) { consumePendingNotificationSessionId() }
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PlatformChannelNames.FILE_CACHE)
            .setMethodCallHandler(
                FileCacheMethodHandler(
                    activity = this,
                    operations = FileCacheOperations(this),
                    launchPickAudioSource = audioPickerCoordinator::launchPickAudioSource,
                    launchPickAudioFiles = audioPickerCoordinator::launchPickAudioFiles,
                    launchPickAudioFolder = audioPickerCoordinator::launchPickAudioFolder
                )
            )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (audioPickerCoordinator.handleActivityResult(requestCode, resultCode, data)) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun syncPlaybackKeepAlive(
        enabled: Boolean,
        hasActivePlayback: Boolean,
        hasActiveTimer: Boolean,
        usesUnifiedPlaybackNotifications: Boolean,
        keepForegroundServiceAlive: Boolean
    ) {
        playbackKeepAliveCoordinator.sync(
            enabled = enabled,
            hasActivePlayback = hasActivePlayback,
            hasActiveTimer = hasActiveTimer,
            usesUnifiedPlaybackNotifications = usesUnifiedPlaybackNotifications,
            keepForegroundServiceAlive = keepForegroundServiceAlive
        )
    }

    private fun stopPlaybackKeepAliveService() {
        playbackKeepAliveCoordinator.stopService()
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

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deliverNotificationSessionIntent(intent)
    }

    override fun onDestroy() {
        notificationsMethodChannel = null
        subtitleOverlayCoordinator.dispose()
        super.onDestroy()
    }

    private fun capturePendingNotificationSession(intent: Intent?) {
        pendingNotificationSessionId = extractNotificationSessionId(intent)
    }

    private fun consumePendingNotificationSessionId(): String? {
        val sessionId = pendingNotificationSessionId
        pendingNotificationSessionId = null
        return sessionId
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
                NotificationsMethods.OPEN_SESSION_FROM_NOTIFICATION,
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

}
