package com.doujin.audio.channel

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class AppLifecycleMethodHandler(
    private val terminateForPendingRestore: () -> Unit,
    private val syncAppTheme: (String, String, Boolean) -> Unit,
    private val getSystemAccentColor: () -> Int? = { null },
) : MethodChannel.MethodCallHandler {
    constructor(terminateForPendingRestore: () -> Unit) : this(
        terminateForPendingRestore,
        { _, _, _ -> },
    )

    constructor(
        terminateForPendingRestore: () -> Unit,
        syncAppTheme: (String, String) -> Unit,
    ) : this(
        terminateForPendingRestore,
        { preset, themeMode, _ -> syncAppTheme(preset, themeMode) },
    )

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            AppLifecycleMethods.TERMINATE_FOR_PENDING_RESTORE -> {
                result.success(channelSuccess(null))
                terminateForPendingRestore()
            }
            AppLifecycleMethods.SYNC_APP_THEME -> {
                try {
                    val preset = call.requiredString("preset")
                    val themeMode = call.requiredString("themeMode")
                    val pureBlackRaw = call.argument<Any?>("pureBlack")
                    val pureBlack = when (pureBlackRaw) {
                        null -> false
                        is Boolean -> pureBlackRaw
                        else -> throw IllegalArgumentException("pureBlack must be a boolean")
                    }
                    syncAppTheme(preset, themeMode, pureBlack)
                    result.success(channelSuccess(null))
                } catch (error: IllegalArgumentException) {
                    result.success(
                        channelFailure(
                            ChannelErrorCodes.INVALID_ARGUMENT,
                            error.message ?: "Invalid app theme payload",
                        )
                    )
                }
            }
            AppLifecycleMethods.GET_SYSTEM_ACCENT_COLOR -> {
                result.success(channelSuccess(getSystemAccentColor()))
            }
            else -> result.notImplemented()
        }
    }
}
