package com.doujin.audio

import com.doujin.audio.channel.*
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
import android.content.ComponentCallbacks2
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.view.View
import android.view.WindowInsetsController
import android.view.animation.AccelerateDecelerateInterpolator
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

open class MainActivity : FlutterFragmentActivity() {
    private var appLifecycleMethodChannel: MethodChannel? = null
    private var nativePlaybackMethodChannel: MethodChannel? = null
    private var nativePlaybackEventChannel: EventChannel? = null
    private var nativePlaybackBridge: NativePlaybackBridge? = null
    private var fileCacheMethodChannel: MethodChannel? = null
    private var networkMethodChannel: MethodChannel? = null
    private var fileCacheMethodHandler: FileCacheMethodHandler? = null
    private var fileCacheTaskExecutor: FileCacheTaskExecutor? = null
    private var fileExportCoordinator: FileExportCoordinator? = null
    private var fileCacheScanStreamHandler: FileCacheScanStreamHandler? = null
    private var audioPickerCoordinator: AudioPickerCoordinator? = null
    private var videoDisplayMethodChannel: MethodChannel? = null
    private var videoDisplayMethodHandler: VideoDisplayMethodHandler? = null
    private var updateMethodChannel: MethodChannel? = null
    private var subtitleOverlayMethodChannel: MethodChannel? = null
    private var powerMethodChannel: MethodChannel? = null
    private var powerMethodHandler: PowerMethodHandler? = null
    private var fileCacheScanEventChannel: EventChannel? = null
    private val subtitleOverlayCoordinator by lazy { SubtitleOverlayCoordinator(applicationContext) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyStartupWindowTheme()
        setupSplashScreenExitAnimation()
        if (BuildConfig.SCREENSHOT_MODE) {
            // Flutter restores edge-to-edge after page transitions and keyboard
            // dismissal. Reapply the screenshot policy when those insets change.
            window.decorView.setOnApplyWindowInsetsListener { view, insets ->
                hideScreenshotStatusBar()
                view.onApplyWindowInsets(insets)
            }
            hideScreenshotStatusBar()
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && BuildConfig.SCREENSHOT_MODE) {
            hideScreenshotStatusBar()
        }
    }

    private fun hideScreenshotStatusBar() {
        WindowCompat.getInsetsController(window, window.decorView).apply {
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.statusBars())
        }
    }

    override fun getRenderMode(): RenderMode = RenderMode.surface

    override fun onTrimMemory(level: Int) {
        // UI_HIDDEN only reports leaving the foreground. Flutter treats its
        // numeric value as memory pressure and clears decoded cover caches.
        // Forward real pressure levels so bounded caches can still be freed.
        if (level == ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) return
        super.onTrimMemory(level)
    }

    private fun applyStartupWindowTheme() {
        val preferences = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        val preset = preferences.getString("flutter.appThemeColor", "rose") ?: "rose"
        val mode = preferences.getString("flutter.themeMode", "system") ?: "system"
        val pureBlack = preferences.getBoolean("flutter.pureBlackTheme", false)
        val dark = when (mode) {
            "dark" -> true
            "light" -> false
            else -> (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES
        }
        val surfaceColor = StartupWindowTheme.surfaceColor(preset, dark, pureBlack)
        syncWindowSurface(surfaceColor, dark, transparentSystemBars = false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                splashScreen.setSplashScreenTheme(
                    StartupWindowTheme.splashThemeResId(preset, mode, pureBlack, dark)
                )
            } catch (_: Exception) {
            }
        }
    }

    private fun syncWindowSurface(
        color: Int,
        dark: Boolean,
        transparentSystemBars: Boolean = false,
    ) {
        window.setBackgroundDrawable(ColorDrawable(color))
        val barColor = if (transparentSystemBars) Color.TRANSPARENT else color
        window.statusBarColor = barColor
        window.navigationBarColor = barColor
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

    private fun syncAppTheme(preset: String, themeMode: String, pureBlack: Boolean) {
        val dark = when (themeMode) {
            "dark" -> true
            "light" -> false
            else -> (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES
        }
        val surfaceColor = StartupWindowTheme.surfaceColor(preset, dark, pureBlack)
        // Runtime theme updates keep edge-to-edge transparent system bars so
        // Flutter controls top/bottom bar layering without opaque color bands.
        syncWindowSurface(surfaceColor, dark, transparentSystemBars = true)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                splashScreen.setSplashScreenTheme(
                    StartupWindowTheme.splashThemeResId(preset, themeMode, pureBlack, dark)
                )
            } catch (_: Exception) {
            }
        }
    }

    private fun getSystemAccentColor(): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        return try {
            getColor(android.R.color.system_accent1_500)
        } catch (_: Exception) {
            null
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
                    val pureBlack = preferences.getBoolean("flutter.pureBlackTheme", false)
                    val dark = when (mode) {
                        "dark" -> true
                        "light" -> false
                        else -> (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                            Configuration.UI_MODE_NIGHT_YES
                    }
                    val surfaceColor = StartupWindowTheme.surfaceColor(preset, dark, pureBlack)
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
        networkMethodChannel?.setMethodCallHandler(null)
        networkMethodChannel = MethodChannel(
            messenger, PlatformChannelNames.NETWORK, StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue(),
        ).also { it.setMethodCallHandler(NetworkMethodHandler(applicationContext)) }
        appLifecycleMethodChannel?.setMethodCallHandler(null)
        appLifecycleMethodChannel = MethodChannel(
            messenger,
            PlatformChannelNames.APP_LIFECYCLE
        ).also {
            it.setMethodCallHandler(
                AppLifecycleMethodHandler(
                    terminateForPendingRestore = ::schedulePendingRestoreTermination,
                    syncAppTheme = ::syncAppTheme,
                    getSystemAccentColor = ::getSystemAccentColor,
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
            PlatformChannelNames.NATIVE_PLAYBACK,
            StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue()
        ).also { it.setMethodCallHandler(nativePlaybackBridge) }
        nativePlaybackEventChannel = EventChannel(
            messenger,
            PlatformChannelNames.NATIVE_PLAYBACK_EVENTS
        ).also { it.setStreamHandler(nativePlaybackBridge) }

        updateMethodChannel?.setMethodCallHandler(null)
        updateMethodChannel = MethodChannel(messenger, PlatformChannelNames.UPDATE).also {
            it.setMethodCallHandler(UpdateMethodHandler(this))
        }
        videoDisplayMethodHandler?.dispose()
        val videoDisplayMethodHandler = VideoDisplayMethodHandler(this)
        this.videoDisplayMethodHandler = videoDisplayMethodHandler
        videoDisplayMethodChannel?.setMethodCallHandler(null)
        videoDisplayMethodChannel = MethodChannel(
            messenger,
            PlatformChannelNames.VIDEO_DISPLAY
        ).also { it.setMethodCallHandler(videoDisplayMethodHandler) }
        subtitleOverlayMethodChannel?.setMethodCallHandler(null)
        subtitleOverlayMethodChannel = MethodChannel(
            messenger,
            PlatformChannelNames.SUBTITLE_OVERLAY
        ).also {
            it.setMethodCallHandler(SubtitleOverlayMethodHandler(subtitleOverlayCoordinator))
        }
        fileCacheMethodChannel?.setMethodCallHandler(null)
        fileCacheMethodHandler?.shutdown()
        fileExportCoordinator?.dispose()
        audioPickerCoordinator?.dispose()
        fileCacheTaskExecutor?.shutdownNow()
        fileCacheScanEventChannel?.setStreamHandler(null)
        fileCacheScanStreamHandler?.shutdown()

        val fileCacheOperations = FileCacheOperations(applicationContext)
        val fileCacheTaskExecutor = FileCacheTaskExecutor()
        this.fileCacheTaskExecutor = fileCacheTaskExecutor
        powerMethodChannel?.setMethodCallHandler(null)
        powerMethodHandler?.dispose()
        val powerMethodHandler = PowerMethodHandler(this, fileCacheTaskExecutor)
        this.powerMethodHandler = powerMethodHandler
        powerMethodChannel = MethodChannel(messenger, PlatformChannelNames.POWER).also {
            it.setMethodCallHandler(powerMethodHandler)
        }
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
        fileCacheScanEventChannel = EventChannel(
            messenger,
            PlatformChannelNames.FILE_CACHE_SCAN_EVENTS
        ).also { it.setStreamHandler(fileCacheScanStreamHandler) }
        val fileCacheMethodHandler = FileCacheMethodHandler(
            operations = fileCacheOperations,
            scanStreamHandler = fileCacheScanStreamHandler,
            taskExecutor = fileCacheTaskExecutor,
            launchExportFile = fileExportCoordinator::launch,
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

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        disposeFlutterChannels()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        disposeFlutterChannels()
        subtitleOverlayCoordinator.dispose()
        super.onDestroy()
    }

    private fun disposeFlutterChannels() {
        networkMethodChannel?.setMethodCallHandler(null)
        networkMethodChannel = null
        disposeNativePlaybackBridge()
        disposeVideoDisplayChannel()
        appLifecycleMethodChannel?.setMethodCallHandler(null)
        appLifecycleMethodChannel = null
        updateMethodChannel?.setMethodCallHandler(null)
        updateMethodChannel = null
        subtitleOverlayMethodChannel?.setMethodCallHandler(null)
        subtitleOverlayMethodChannel = null
        powerMethodChannel?.setMethodCallHandler(null)
        powerMethodChannel = null
        powerMethodHandler?.dispose()
        powerMethodHandler = null
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
        fileCacheScanEventChannel?.setStreamHandler(null)
        fileCacheScanEventChannel = null
        fileCacheScanStreamHandler?.shutdown()
        fileCacheScanStreamHandler = null
    }

    private fun disposeNativePlaybackBridge() {
        nativePlaybackMethodChannel?.setMethodCallHandler(null)
        nativePlaybackMethodChannel = null
        nativePlaybackEventChannel?.setStreamHandler(null)
        nativePlaybackEventChannel = null
        nativePlaybackBridge?.dispose()
        nativePlaybackBridge = null
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
    fun surfaceColor(preset: String, dark: Boolean, pureBlack: Boolean = false): Int {
        if (pureBlack && dark) return 0xFF000000.toInt()
        return when (preset) {
            "purple", "indigo", "lavender", "periwinkle" ->
                if (dark) 0xFF131117.toInt() else 0xFFFAF8FF.toInt()
            "blue", "sky", "cyan" ->
                if (dark) 0xFF101218.toInt() else 0xFFF7F9FF.toInt()
            "teal", "green", "olive", "mint", "lightGreen" ->
                if (dark) 0xFF101513.toInt() else 0xFFF5FFF9.toInt()
            "yellow", "orange", "brown", "lime", "amber", "peach" ->
                if (dark) 0xFF151310.toInt() else 0xFFFFF9F2.toInt()
            "gray", "monochrome" ->
                if (dark) 0xFF121315.toInt() else 0xFFF7F8FA.toInt()
            else -> if (dark) 0xFF141112.toInt() else 0xFFFFF8F8.toInt()
        }
    }

    fun splashThemeResId(
        preset: String,
        mode: String,
        pureBlack: Boolean = false,
        dark: Boolean = false,
    ): Int {
        if (pureBlack && (mode == "dark" || (mode == "system" && dark))) {
            return R.style.LaunchTheme_PureBlack
        }
        return when (mode) {
            "light" -> when (preset) {
                "purple", "indigo", "lavender", "periwinkle" -> R.style.LaunchTheme_Lavender_Light
                "blue", "sky", "cyan" -> R.style.LaunchTheme_Blue_Light
                "teal", "green", "olive", "mint", "lightGreen" -> R.style.LaunchTheme_Mint_Light
                "yellow", "orange", "brown", "lime", "amber", "peach" -> R.style.LaunchTheme_Amber_Light
                "gray", "monochrome" -> R.style.LaunchTheme_Gray_Light
                else -> R.style.LaunchTheme_Rose_Light
            }
            "dark" -> when (preset) {
                "purple", "indigo", "lavender", "periwinkle" -> R.style.LaunchTheme_Lavender_Dark
                "blue", "sky", "cyan" -> R.style.LaunchTheme_Blue_Dark
                "teal", "green", "olive", "mint", "lightGreen" -> R.style.LaunchTheme_Mint_Dark
                "yellow", "orange", "brown", "lime", "amber", "peach" -> R.style.LaunchTheme_Amber_Dark
                "gray", "monochrome" -> R.style.LaunchTheme_Gray_Dark
                else -> R.style.LaunchTheme_Rose_Dark
            }
            else -> when (preset) {
                "purple", "indigo", "lavender", "periwinkle" -> R.style.LaunchTheme_Lavender
                "blue", "sky", "cyan" -> R.style.LaunchTheme_Blue
                "teal", "green", "olive", "mint", "lightGreen" -> R.style.LaunchTheme_Mint
                "yellow", "orange", "brown", "lime", "amber", "peach" -> R.style.LaunchTheme_Amber
                "gray", "monochrome" -> R.style.LaunchTheme_Gray
                else -> R.style.LaunchTheme_Rose
            }
        }
    }
}
