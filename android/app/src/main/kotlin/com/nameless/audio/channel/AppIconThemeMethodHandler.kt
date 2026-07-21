package com.nameless.audio.channel

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

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val envelope = ChannelEnvelopeResult(result)
        try {
            when (call.method) {
                AppIconMethods.SYNC_THEME_MODE -> {
                    val mode = call.argumentReader().requiredString("mode")
                    syncThemeMode(mode)
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
            syncThemeMode(THEME_MODE_SYSTEM)
        }
    }

    private fun syncThemeMode(mode: String) {
        val dark = isDarkThemeMode(mode, context.resources.configuration.uiMode)
        setLauncherAliasEnabled(dark)
        lastThemeMode = mode
    }

    private fun setLauncherAliasEnabled(dark: Boolean) {
        val packageManager = context.packageManager
        val lightAlias = appIconAliasComponent(context.packageName, dark = false)
        val darkAlias = appIconAliasComponent(context.packageName, dark = true)
        val flags = PackageManager.DONT_KILL_APP
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.setComponentEnabledSettings(
                listOf(
                    PackageManager.ComponentEnabledSetting(
                        lightAlias,
                        if (dark) {
                            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                        } else {
                            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                        },
                        flags
                    ),
                    PackageManager.ComponentEnabledSetting(
                        darkAlias,
                        if (dark) {
                            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                        } else {
                            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                        },
                        flags
                    )
                )
            )
            return
        }
        val enabled = if (dark) darkAlias else lightAlias
        val disabled = if (dark) lightAlias else darkAlias
        packageManager.setComponentEnabledSetting(
            enabled,
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            flags
        )
        packageManager.setComponentEnabledSetting(
            disabled,
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            flags
        )
    }
}

internal const val THEME_MODE_SYSTEM = "system"
private const val THEME_MODE_LIGHT = "light"
private const val THEME_MODE_DARK = "dark"

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

internal fun appIconAliasComponent(packageName: String, dark: Boolean): ComponentName {
    return ComponentName(packageName, appIconAliasName(packageName, dark))
}

internal fun appIconAliasName(packageName: String, dark: Boolean): String {
    val aliasName = if (dark) "MainActivityDark" else "MainActivityLight"
    return "$packageName.$aliasName"
}
