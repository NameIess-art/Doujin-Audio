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

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.AnimatorSet
import android.animation.ObjectAnimator
import android.animation.PropertyValuesHolder
import android.animation.ValueAnimator
import android.content.Intent
import android.content.res.Configuration
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.view.View
import android.view.WindowInsetsController
import android.view.animation.AccelerateDecelerateInterpolator
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
    private var powerMethodHandler: PowerMethodHandler? = null
    private val subtitleOverlayCoordinator by lazy { SubtitleOverlayCoordinator(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        applyStartupWindowTheme()
        super.onCreate(savedInstanceState)
        applyStartupWindowTheme()
        setupSplashScreenExitAnimation()
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
        val surfaceColor = StartupWindowTheme.surfaceColor(preset, dark)
        syncWindowSurface(surfaceColor, dark)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                splashScreen.setSplashScreenTheme(
                    StartupWindowTheme.splashThemeResId(preset, mode)
                )
            } catch (_: Exception) {
            }
        }
    }

    private fun syncWindowSurface(color: Int, dark: Boolean) {
        window.setBackgroundDrawable(ColorDrawable(color))
        window.statusBarColor = color
        window.navigationBarColor = color
        val decorView = window.peekDecorView() ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val controller = window.insetsController
                val appearance =
                    WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                        WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
                controller?.setSystemBarsAppearance(
                    if (dark) 0 else appearance,
                    appearance
                )
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                @Suppress("DEPRECATION")
                var flags = decorView.systemUiVisibility
                flags = if (dark) {
                    flags and View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR.inv()
                } else {
                    flags or View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    flags = if (dark) {
                        flags and View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR.inv()
                    } else {
                        flags or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
                    }
                }
                @Suppress("DEPRECATION")
                decorView.systemUiVisibility = flags
            }
        } catch (_: Exception) {
        }
    }

    private fun syncAppTheme(preset: String, themeMode: String) {
        val dark = when (themeMode) {
            "dark" -> true
            "light" -> false
            else -> (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES
        }
        val surfaceColor = StartupWindowTheme.surfaceColor(preset, dark)
        syncWindowSurface(surfaceColor, dark)

        try {
            val preferences = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            preferences.edit()
                .putString("flutter.appThemeColor", preset)
                .putString("flutter.themeMode", themeMode)
                .commit()
        } catch (_: Exception) {
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                splashScreen.setSplashScreenTheme(
                    StartupWindowTheme.splashThemeResId(preset, themeMode)
                )
            } catch (_: Exception) {
            }
        }
    }

    private fun setupSplashScreenExitAnimation() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return

        try {
            splashScreen.setOnExitAnimationListener { splashScreenView ->
                try {
                    val preferences = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                    val preset = preferences.getString("flutter.appThemeColor", "rose") ?: "rose"
                    val mode = preferences.getString("flutter.themeMode", "system") ?: "system"
                    val dark = when (mode) {
                        "dark" -> true
                        "light" -> false
                        else -> (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                            Configuration.UI_MODE_NIGHT_YES
                    }
                    val surfaceColor = StartupWindowTheme.surfaceColor(preset, dark)
                    splashScreenView.setBackgroundColor(surfaceColor)

                    if (!ValueAnimator.areAnimatorsEnabled()) {
                        splashScreenView.remove()
                        return@setOnExitAnimationListener
                    }

                    val iconView = splashScreenView.iconView
                    val animators = mutableListOf<Animator>()

                    val splashAlpha = ObjectAnimator.ofFloat(splashScreenView, View.ALPHA, 1.0f, 0.0f).apply {
                        duration = 300L
                        interpolator = AccelerateDecelerateInterpolator()
                    }
                    animators.add(splashAlpha)

                    if (iconView != null) {
                        val iconScaleX = PropertyValuesHolder.ofFloat(View.SCALE_X, 1.0f, 0.82f)
                        val iconScaleY = PropertyValuesHolder.ofFloat(View.SCALE_Y, 1.0f, 0.82f)
                        val iconAlpha = PropertyValuesHolder.ofFloat(View.ALPHA, 1.0f, 0.0f)
                        val iconAnimator = ObjectAnimator.ofPropertyValuesHolder(
                            iconView,
                            iconScaleX,
                            iconScaleY,
                            iconAlpha,
                        ).apply {
                            duration = 240L
                            interpolator = AccelerateDecelerateInterpolator()
                        }
                        animators.add(iconAnimator)
                    }

                    var removed = false
                    fun safeRemove() {
                        if (!removed) {
                            removed = true
                            try {
                                splashScreenView.remove()
                            } catch (_: Exception) {
                            }
                        }
                    }

                    AnimatorSet().apply {
                        playTogether(animators)
                        addListener(object : AnimatorListenerAdapter() {
                            override fun onAnimationEnd(animation: Animator) {
                                safeRemove()
                            }
                            override fun onAnimationCancel(animation: Animator) {
                                safeRemove()
                            }
                        })
                        start()
                    }

                    Handler(Looper.getMainLooper()).postDelayed({ safeRemove() }, 600L)
                } catch (_: Exception) {
                    try {
                        splashScreenView.remove()
                    } catch (_: Exception) {
                    }
                }
            }
        } catch (_: Exception) {
        }
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
                    syncAppTheme = ::syncAppTheme,
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

        powerMethodHandler?.dispose()
        val powerMethodHandler = PowerMethodHandler(this)
        this.powerMethodHandler = powerMethodHandler
        MethodChannel(messenger, PlatformChannelNames.POWER)
            .setMethodCallHandler(powerMethodHandler)
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
        powerMethodHandler?.dispose()
        powerMethodHandler = null
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

    fun splashThemeResId(preset: String, mode: String): Int {
        return when (mode) {
            "light" -> when (preset) {
                "lavender", "periwinkle" -> R.style.LaunchTheme_Lavender_Light
                "blue", "sky", "cyan" -> R.style.LaunchTheme_Blue_Light
                "mint", "green", "lightGreen" -> R.style.LaunchTheme_Mint_Light
                "lime", "amber", "orange", "peach" -> R.style.LaunchTheme_Amber_Light
                "gray" -> R.style.LaunchTheme_Gray_Light
                else -> R.style.LaunchTheme_Rose_Light
            }
            "dark" -> when (preset) {
                "lavender", "periwinkle" -> R.style.LaunchTheme_Lavender_Dark
                "blue", "sky", "cyan" -> R.style.LaunchTheme_Blue_Dark
                "mint", "green", "lightGreen" -> R.style.LaunchTheme_Mint_Dark
                "lime", "amber", "orange", "peach" -> R.style.LaunchTheme_Amber_Dark
                "gray" -> R.style.LaunchTheme_Gray_Dark
                else -> R.style.LaunchTheme_Rose_Dark
            }
            else -> when (preset) {
                "lavender", "periwinkle" -> R.style.LaunchTheme_Lavender
                "blue", "sky", "cyan" -> R.style.LaunchTheme_Blue
                "mint", "green", "lightGreen" -> R.style.LaunchTheme_Mint
                "lime", "amber", "orange", "peach" -> R.style.LaunchTheme_Amber
                "gray" -> R.style.LaunchTheme_Gray
                else -> R.style.LaunchTheme_Rose
            }
        }
    }
}
