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

        val fileCacheOperations = FileCacheOperations(this)
        fileCacheScanStreamHandler?.shutdown()
        val fileCacheScanStreamHandler = FileCacheScanStreamHandler(this, fileCacheOperations)
        this.fileCacheScanStreamHandler = fileCacheScanStreamHandler
        EventChannel(messenger, PlatformChannelNames.FILE_CACHE_SCAN_EVENTS)
            .setStreamHandler(fileCacheScanStreamHandler)
        MethodChannel(messenger, PlatformChannelNames.FILE_CACHE)
            .setMethodCallHandler(
                FileCacheMethodHandler(
                    activity = this,
                    operations = fileCacheOperations,
                    scanStreamHandler = fileCacheScanStreamHandler,
                    launchPickAudioSource = audioPickerCoordinator::launchPickAudioSource,
                    launchPickAudioFiles = audioPickerCoordinator::launchPickAudioFiles,
                    launchPickAudioFolder = audioPickerCoordinator::launchPickAudioFolder
                )
            )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
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
