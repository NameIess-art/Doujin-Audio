package com.nameless.audio

import android.content.Intent
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    companion object {
        const val notificationSessionIdExtra = "notificationSessionId"
        const val openSessionFromNotificationAction =
            "com.nameless.audio.OPEN_SESSION_FROM_NOTIFICATION"
    }

    private var notificationsMethodChannel: MethodChannel? = null
    private var fileCacheMethodChannel: MethodChannel? = null
    private var fileCacheMethodHandler: FileCacheMethodHandler? = null
    private var fileCacheTaskExecutor: FileCacheTaskExecutor? = null
    private var fileExportCoordinator: FileExportCoordinator? = null
    private var fileCacheScanStreamHandler: FileCacheScanStreamHandler? = null
    private var pendingNotificationSessionId: String? = null
    private val subtitleOverlayCoordinator by lazy { SubtitleOverlayCoordinator(this) }
    private val audioPickerCoordinator by lazy { AudioPickerCoordinator(this) }

    override fun getRenderMode(): RenderMode = RenderMode.surface

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        val nativePlaybackBridge = NativePlaybackBridge(applicationContext)
        MethodChannel(messenger, PlatformChannelNames.NATIVE_PLAYBACK)
            .setMethodCallHandler(nativePlaybackBridge)
        EventChannel(messenger, PlatformChannelNames.NATIVE_PLAYBACK_EVENTS)
            .setStreamHandler(nativePlaybackBridge)

        MethodChannel(messenger, PlatformChannelNames.POWER)
            .setMethodCallHandler(PowerMethodHandler(this))
        MethodChannel(messenger, PlatformChannelNames.UPDATE)
            .setMethodCallHandler(UpdateMethodHandler(this))
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
        fileCacheTaskExecutor?.shutdownNow()
        fileCacheScanStreamHandler?.shutdown()

        val fileCacheOperations = FileCacheOperations(applicationContext)
        val fileCacheTaskExecutor = FileCacheTaskExecutor()
        this.fileCacheTaskExecutor = fileCacheTaskExecutor
        val fileExportCoordinator = FileExportCoordinator(
            this,
            fileCacheOperations,
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
        if (audioPickerCoordinator.handleActivityResult(requestCode, resultCode, data)) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deliverNotificationSessionIntent(intent)
    }

    override fun onDestroy() {
        notificationsMethodChannel = null
        fileCacheMethodChannel?.setMethodCallHandler(null)
        fileCacheMethodChannel = null
        fileCacheMethodHandler?.shutdown()
        fileCacheMethodHandler = null
        fileExportCoordinator?.dispose()
        fileExportCoordinator = null
        fileCacheTaskExecutor?.shutdownNow()
        fileCacheTaskExecutor = null
        fileCacheScanStreamHandler?.shutdown()
        fileCacheScanStreamHandler = null
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
        return intent
            ?.getStringExtra(notificationSessionIdExtra)
            ?.takeIf { it.isNotBlank() }
    }
}
