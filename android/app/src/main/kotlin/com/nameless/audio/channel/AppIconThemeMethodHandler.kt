package com.nameless.audio.channel

import com.nameless.audio.player.notification.UnifiedPlaybackNotificationController

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
    private var lastThemeMode = THEME_MODE_SYSTEM
    private var lastColorGroup = ICON_GROUP_WARM

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
        val dark = isDarkThemeMode(mode, context.resources.configuration.uiMode)
        iconColorGroupAliasSuffix(colorGroup)
        setLauncherAliasEnabled(dark, colorGroup)
        UnifiedPlaybackNotificationController.refreshThemeIcon(context)
        lastThemeMode = mode
        lastColorGroup = colorGroup
    }

    private fun setLauncherAliasEnabled(dark: Boolean, colorGroup: String) {
        val packageManager = context.packageManager
        val packageName = context.packageName
        val enabledAliasName = appIconAliasName(packageName, dark, colorGroup)
        val updates = launcherAliasUpdates(
            launcherAliasNames(packageName),
            enabledAliasName
        )
        val flags = PackageManager.DONT_KILL_APP
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.setComponentEnabledSettings(
                updates.map { (aliasName, enabled) ->
                    PackageManager.ComponentEnabledSetting(
                        ComponentName(packageName, aliasName),
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
            updates.forEach { (aliasName, enabled) ->
                packageManager.setComponentEnabledSetting(
                    ComponentName(packageName, aliasName),
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
private const val THEME_MODE_LIGHT = "light"
private const val THEME_MODE_DARK = "dark"
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

internal fun isDarkThemeMode(mode: String, uiMode: Int): Boolean {
    return when (mode) {
        THEME_MODE_DARK -> true
        THEME_MODE_LIGHT -> false
        THEME_MODE_SYSTEM -> {
            (uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES
        }
        else -> throw IllegalArgumentException("Unsupported theme mode: $mode")
    }
}

internal fun launcherAliasNames(packageName: String): List<String> {
    return ICON_COLOR_GROUPS.flatMap { colorGroup ->
        listOf(
            appIconAliasName(packageName, dark = false, colorGroup = colorGroup),
            appIconAliasName(packageName, dark = true, colorGroup = colorGroup)
        )
    }
}

internal fun launcherAliasUpdates(
    aliasNames: List<String>,
    enabledAliasName: String
): List<Pair<String, Boolean>> {
    require(enabledAliasName in aliasNames) {
        "Launcher alias is not registered: $enabledAliasName"
    }
    return buildList {
        add(enabledAliasName to true)
        aliasNames.forEach { aliasName ->
            if (aliasName != enabledAliasName) add(aliasName to false)
        }
    }
}

internal fun appIconAliasName(
    packageName: String,
    dark: Boolean,
    colorGroup: String
): String {
    val groupSuffix = iconColorGroupAliasSuffix(colorGroup)
    val modeSuffix = if (dark) "Dark" else "Light"
    val aliasName = "MainActivity${groupSuffix}${modeSuffix}"
    return "$packageName.$aliasName"
}

internal fun iconColorGroupAliasSuffix(colorGroup: String): String {
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
