package com.doujin.audio

import com.doujin.audio.channel.*
import com.doujin.audio.player.notification.notificationSessionIdFromIntent
import com.doujin.audio.player.common.*
import com.doujin.audio.player.service.NativePlaybackService
import com.doujin.audio.player.video.NativeVideoPlatformViewFactory
import com.doujin.audio.scanner.*
import com.doujin.audio.storage.*
import com.doujin.audio.subtitle.*
import com.doujin.audio.update.*

import android.content.Intent
import android.content.res.Configuration
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

open class MainActivity : FlutterFragmentActivity() {
    companion object {
        const val notificationSessionIdExtra = "notificationSessionId"
        const val openSessionFromNotificationAction =
            "com.doujin.audio.OPEN_SESSION_FROM_NOTIFICATION"
    }

    private var notificationsMethodChannel: MethodChannel? = null
    private var appLifecycleMethodChannel: MethodChannel? = null
    private var nativePlaybackMethodChannel: MethodChannel? = null
    private var nativePlaybackEventChannel: EventChannel? = null
    private var nativePlaybackBridge: NativePlaybackBridge? = null
    private var fileCacheMethodChannel: MethodChannel? = null
    private var fileCacheMethodHandler: FileCacheMethodHandler? = null
    private var fileCacheTaskExecutor: FileCacheTaskExecutor? = null
    private var fileExportCoordinator: FileExportCoordinator? = null
    private var fileCacheScanStreamHandler: FileCacheScanStreamHandler? = null
    private var audioPickerCoordinator: AudioPickerCoordinator? = null
    private var videoDisplayMethodChannel: MethodChannel? = null
    private var videoDisplayMethodHandler: VideoDisplayMethodHandler? = null
    private var pendingNotificationSessionId: String? = null
    private val subtitleOverlayCoordinator by lazy { SubtitleOverlayCoordinator(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        applyStartupWindowTheme()
        super.onCreate(savedInstanceState)
        applyStartupWindowTheme()
    }

    override fun getRenderMode(): RenderMode = RenderMode.surface

    private fun applyStartupWindowTheme() {
        val preferences = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        val preset = preferences.getString("flutter.appThemeColor", "rose") ?: "rose"
        val mode = preferences.getString("flutter.themeMode", "system") ?: "system"
        val dark = when (mode) {
            "dark" -> true
            "light" -> false
            else -> (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES
        }
        syncWindowSurface(StartupWindowTheme.surfaceColor(preset, dark))
    }

    private fun syncWindowSurface(color: Int) {
        window.setBackgroundDrawable(ColorDrawable(color))
        window.statusBarColor = color
        window.navigationBarColor = color
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        appLifecycleMethodChannel?.setMethodCallHandler(null)
        appLifecycleMethodChannel = MethodChannel(
            messenger,
            PlatformChannelNames.APP_LIFECYCLE
        ).also {
            it.setMethodCallHandler(
                AppLifecycleMethodHandler(
                    terminateForPendingRestore = ::schedulePendingRestoreTermination,
                )
            )
        }
        flutterEngine.platformViewsController.registry.registerViewFactory(
            NativeVideoPlatformViewFactory.viewType,
            NativeVideoPlatformViewFactory()
        )

        disposeNativePlaybackBridge()
        val nativePlaybackBridge = NativePlaybackBridge(applicationContext)
        this.nativePlaybackBridge = nativePlaybackBridge
        nativePlaybackMethodChannel = MethodChannel(
            messenger,
            PlatformChannelNames.NATIVE_PLAYBACK
        ).also { it.setMethodCallHandler(nativePlaybackBridge) }
        nativePlaybackEventChannel = EventChannel(
            messenger,
            PlatformChannelNames.NATIVE_PLAYBACK_EVENTS
        ).also { it.setStreamHandler(nativePlaybackBridge) }

        MethodChannel(messenger, PlatformChannelNames.POWER)
            .setMethodCallHandler(PowerMethodHandler(this))
        MethodChannel(messenger, PlatformChannelNames.UPDATE)
            .setMethodCallHandler(UpdateMethodHandler(this))
        videoDisplayMethodHandler?.dispose()
        val videoDisplayMethodHandler = VideoDisplayMethodHandler(this)
        this.videoDisplayMethodHandler = videoDisplayMethodHandler
        videoDisplayMethodChannel = MethodChannel(
            messenger,
            PlatformChannelNames.VIDEO_DISPLAY
        ).also { it.setMethodCallHandler(videoDisplayMethodHandler) }
        MethodChannel(messenger, PlatformChannelNames.SUBTITLE_OVERLAY)
            .setMethodCallHandler(SubtitleOverlayMethodHandler(subtitleOverlayCoordinator))
        notificationsMethodChannel = MethodChannel(messenger, PlatformChannelNames.NOTIFICATIONS)
        capturePendingNotificationSession(intent)
        notificationsMethodChannel?.setMethodCallHandler(
            NotificationsMethodHandler(this) { consumePendingNotificationSessionId() }
        )

        fileCacheMethodChannel?.setMethodCallHandler(null)
        fileCacheMethodHandler?.shutdown()
        fileExportCoordinator?.dispose()
        audioPickerCoordinator?.dispose()
        fileCacheTaskExecutor?.shutdownNow()
        fileCacheScanStreamHandler?.shutdown()

        val fileCacheOperations = FileCacheOperations(applicationContext)
        val fileCacheTaskExecutor = FileCacheTaskExecutor()
        this.fileCacheTaskExecutor = fileCacheTaskExecutor
        val audioPickerCoordinator = AudioPickerCoordinator(
            this,
            fileCacheTaskExecutor
        )
        this.audioPickerCoordinator = audioPickerCoordinator
        val fileExportCoordinator = FileExportCoordinator(
            this,
            fileCacheOperations.documentStorage,
            fileCacheTaskExecutor
        )
        this.fileExportCoordinator = fileExportCoordinator
        val fileCacheScanStreamHandler = FileCacheScanStreamHandler(this, fileCacheOperations)
        this.fileCacheScanStreamHandler = fileCacheScanStreamHandler
        EventChannel(messenger, PlatformChannelNames.FILE_CACHE_SCAN_EVENTS)
            .setStreamHandler(fileCacheScanStreamHandler)
        val fileCacheMethodHandler = FileCacheMethodHandler(
            operations = fileCacheOperations,
            scanStreamHandler = fileCacheScanStreamHandler,
            taskExecutor = fileCacheTaskExecutor,
            launchExportFile = fileExportCoordinator::launch,
            launchPickAudioSource = audioPickerCoordinator::launchPickAudioSource,
            launchPickAudioFiles = audioPickerCoordinator::launchPickAudioFiles,
            launchPickAudioFolder = audioPickerCoordinator::launchPickAudioFolder
        )
        this.fileCacheMethodHandler = fileCacheMethodHandler
        fileCacheMethodChannel = MethodChannel(messenger, PlatformChannelNames.FILE_CACHE).also {
            it.setMethodCallHandler(fileCacheMethodHandler)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (fileExportCoordinator?.handleActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        if (
            audioPickerCoordinator?.handleActivityResult(requestCode, resultCode, data) == true
        ) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deliverNotificationSessionIntent(intent)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        disposeNativePlaybackBridge()
        disposeVideoDisplayChannel()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        disposeNativePlaybackBridge()
        disposeVideoDisplayChannel()
        notificationsMethodChannel = null
        appLifecycleMethodChannel?.setMethodCallHandler(null)
        appLifecycleMethodChannel = null
        fileCacheMethodChannel?.setMethodCallHandler(null)
        fileCacheMethodChannel = null
        fileCacheMethodHandler?.shutdown()
        fileCacheMethodHandler = null
        fileExportCoordinator?.dispose()
        fileExportCoordinator = null
        audioPickerCoordinator?.dispose()
        audioPickerCoordinator = null
        fileCacheTaskExecutor?.shutdownNow()
        fileCacheTaskExecutor = null
        fileCacheScanStreamHandler?.shutdown()
        fileCacheScanStreamHandler = null
        subtitleOverlayCoordinator.dispose()
        super.onDestroy()
    }

    private fun disposeNativePlaybackBridge() {
        nativePlaybackMethodChannel?.setMethodCallHandler(null)
        nativePlaybackMethodChannel = null
        nativePlaybackEventChannel?.setStreamHandler(null)
        nativePlaybackEventChannel = null
        nativePlaybackBridge?.dispose()
        nativePlaybackBridge = null
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
        if (intent?.action != openSessionFromNotificationAction) return null
        val sessionId = try {
            intent.getStringExtra(notificationSessionIdExtra)
        } catch (_: RuntimeException) {
            null
        }
        return notificationSessionIdFromIntent(intent.action, sessionId)
    }

    private fun disposeVideoDisplayChannel() {
        videoDisplayMethodChannel?.setMethodCallHandler(null)
        videoDisplayMethodChannel = null
        videoDisplayMethodHandler?.dispose()
        videoDisplayMethodHandler = null
    }

    private fun schedulePendingRestoreTermination() {
        Handler(Looper.getMainLooper()).postDelayed(
            {
                stopService(
                    Intent(applicationContext, NativePlaybackService::class.java)
                )
                finishAndRemoveTask()
                Handler(Looper.getMainLooper()).postDelayed(
                    { Process.killProcess(Process.myPid()) },
                    150L
                )
            },
            100L
        )
    }
}

internal object StartupWindowTheme {
    fun surfaceColor(preset: String, dark: Boolean): Int {
        return when (preset) {
            "lavender", "periwinkle" -> if (dark) 0xFF1D1927.toInt() else 0xFFFAF8FF.toInt()
            "blue", "sky", "cyan" -> if (dark) 0xFF111D24.toInt() else 0xFFF5FBFF.toInt()
            "mint", "green", "lightGreen" -> if (dark) 0xFF12201C.toInt() else 0xFFF5FFF9.toInt()
            "lime", "amber", "orange", "peach" -> if (dark) 0xFF241D13.toInt() else 0xFFFFF9F2.toInt()
            "gray" -> if (dark) 0xFF1A1D21.toInt() else 0xFFF7F8FA.toInt()
            else -> if (dark) 0xFF211A1B.toInt() else 0xFFFFF8F8.toInt()
        }
    }
}
