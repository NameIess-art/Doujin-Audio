package com.doujin.audio.channel

import com.doujin.audio.player.notification.UnifiedPlaybackNotificationController

import android.content.ComponentName
import android.content.Context
import android.content.res.Configuration
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class AppIconThemeMethodHandler(
    context: Context
) : MethodChannel.MethodCallHandler {
    private val context = context.applicationContext
    private val preferences =
        this.context.getSharedPreferences(APP_ICON_THEME_PREFERENCES, Context.MODE_PRIVATE)
    private var lastThemeMode = validThemeModeOrDefault(
        preferences.getString(APP_ICON_THEME_MODE_KEY, null)
    )
    private var lastColorGroup = validIconColorGroupOrDefault(
        preferences.getString(APP_ICON_COLOR_GROUP_KEY, null)
    )

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val envelope = ChannelEnvelopeResult(result)
        try {
            when (call.method) {
                AppIconMethods.SYNC_THEME_MODE -> {
                    val mode = call.argumentReader().requiredString("mode")
                    val colorGroup = call.argumentReader().requiredString("colorGroup")
                    syncThemeMode(mode, colorGroup)
                    envelope.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: IllegalArgumentException) {
            envelope.error(
                ChannelErrorCodes.INVALID_ARGUMENT,
                error.message ?: "Invalid arguments.",
                mapOf("method" to call.method)
            )
        } catch (error: SecurityException) {
            envelope.error(
                ChannelErrorCodes.PLATFORM_ERROR,
                error.message ?: "Unable to update launcher icon.",
                mapOf("method" to call.method)
            )
        }
    }

    fun syncSystemThemeIfNeeded() {
        if (lastThemeMode == THEME_MODE_SYSTEM) {
            syncThemeMode(THEME_MODE_SYSTEM, lastColorGroup)
        }
    }

    private fun syncThemeMode(mode: String, colorGroup: String) {
        val launcherMode = effectiveLauncherThemeMode(
            mode,
            context.resources.configuration.uiMode
        )
        iconColorGroupLauncherSuffix(colorGroup)
        setLauncherActivityEnabled(launcherMode, colorGroup)
        preferences.edit()
            .putString(APP_ICON_THEME_MODE_KEY, mode)
            .putString(APP_ICON_COLOR_GROUP_KEY, colorGroup)
            .apply()
        UnifiedPlaybackNotificationController.refreshThemeIcon(context)
        lastThemeMode = mode
        lastColorGroup = colorGroup
    }

    private fun setLauncherActivityEnabled(mode: String, colorGroup: String) {
        val packageManager = context.packageManager
        val packageName = context.packageName
        val enabledActivityName = appIconLauncherActivityName(
            mode,
            colorGroup
        )
        val updates = launcherActivityUpdates(
            launcherActivityNames(),
            enabledActivityName
        )
        val flags = PackageManager.DONT_KILL_APP
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.setComponentEnabledSettings(
                updates.map { (activityName, enabled) ->
                    PackageManager.ComponentEnabledSetting(
                        ComponentName(packageName, activityName),
                        if (enabled) {
                            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                        } else {
                            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                        },
                        flags
                    )
                }
            )
        } else {
            updates.forEach { (activityName, enabled) ->
                packageManager.setComponentEnabledSetting(
                    ComponentName(packageName, activityName),
                    if (enabled) {
                        PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                    } else {
                        PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                    },
                    flags
                )
            }
        }
    }
}

internal const val THEME_MODE_SYSTEM = "system"
internal const val THEME_MODE_LIGHT = "light"
internal const val THEME_MODE_DARK = "dark"
internal const val ICON_GROUP_WARM = "warm"
private const val ICON_GROUP_PURPLE = "purple"
private const val ICON_GROUP_BLUE = "blue"
private const val ICON_GROUP_GREEN = "green"
private const val ICON_GROUP_SUNSET = "sunset"
private const val ICON_GROUP_NEUTRAL = "neutral"
internal val ICON_COLOR_GROUPS = listOf(
    ICON_GROUP_WARM,
    ICON_GROUP_PURPLE,
    ICON_GROUP_BLUE,
    ICON_GROUP_GREEN,
    ICON_GROUP_SUNSET,
    ICON_GROUP_NEUTRAL
)
private val THEME_MODES = listOf(
    THEME_MODE_SYSTEM,
    THEME_MODE_LIGHT,
    THEME_MODE_DARK
)
private const val APP_ICON_THEME_PREFERENCES = "app_icon_theme_v1"
private const val APP_ICON_THEME_MODE_KEY = "theme_mode"
private const val APP_ICON_COLOR_GROUP_KEY = "color_group"
private const val LAUNCHER_ACTIVITY_CLASS_PACKAGE = "com.doujin.audio.common"

internal fun launcherActivityNames(): List<String> {
    return ICON_COLOR_GROUPS.flatMap { colorGroup ->
        THEME_MODES.map { mode ->
            appIconLauncherActivityName(mode, colorGroup)
        }
    }
}

internal fun launcherActivityUpdates(
    activityNames: List<String>,
    enabledActivityName: String
): List<Pair<String, Boolean>> {
    require(enabledActivityName in activityNames) {
        "Launcher activity is not registered: $enabledActivityName"
    }
    return buildList {
        add(enabledActivityName to true)
        activityNames.forEach { activityName ->
            if (activityName != enabledActivityName) add(activityName to false)
        }
    }
}

internal fun appIconLauncherActivityName(
    mode: String,
    colorGroup: String
): String {
    val groupSuffix = iconColorGroupLauncherSuffix(colorGroup)
    val modeSuffix = launcherThemeModeSuffix(mode)
    val activityName = "MainActivity${groupSuffix}${modeSuffix}"
    return "$LAUNCHER_ACTIVITY_CLASS_PACKAGE.$activityName"
}

internal fun launcherThemeModeSuffix(mode: String): String {
    return when (mode) {
        THEME_MODE_SYSTEM -> "System"
        THEME_MODE_LIGHT -> "Light"
        THEME_MODE_DARK -> "Dark"
        else -> throw IllegalArgumentException("Unsupported theme mode: $mode")
    }
}

internal fun effectiveLauncherThemeMode(mode: String, uiMode: Int): String {
    return when (mode) {
        THEME_MODE_SYSTEM -> {
            if ((uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES
            ) {
                THEME_MODE_DARK
            } else {
                THEME_MODE_LIGHT
            }
        }
        THEME_MODE_LIGHT,
        THEME_MODE_DARK -> mode
        else -> throw IllegalArgumentException("Unsupported theme mode: $mode")
    }
}

internal fun validThemeModeOrDefault(value: String?): String {
    return value?.takeIf(THEME_MODES::contains) ?: THEME_MODE_SYSTEM
}

internal fun validIconColorGroupOrDefault(value: String?): String {
    return value?.takeIf(ICON_COLOR_GROUPS::contains) ?: ICON_GROUP_WARM
}

internal fun iconColorGroupLauncherSuffix(colorGroup: String): String {
    return when (colorGroup) {
        ICON_GROUP_WARM -> "Warm"
        ICON_GROUP_PURPLE -> "Purple"
        ICON_GROUP_BLUE -> "Blue"
        ICON_GROUP_GREEN -> "Green"
        ICON_GROUP_SUNSET -> "Sunset"
        ICON_GROUP_NEUTRAL -> "Neutral"
        else -> throw IllegalArgumentException("Unsupported icon color group: $colorGroup")
    }
}
