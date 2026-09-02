package com.doujin.audio.channel

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class AppLifecycleMethodHandler(
    private val terminateForPendingRestore: () -> Unit,
    private val syncAppTheme: (String, String) -> Unit,
) : MethodChannel.MethodCallHandler {
    constructor(terminateForPendingRestore: () -> Unit) : this(
        terminateForPendingRestore,
        { _, _ -> },
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
                    syncAppTheme(preset, themeMode)
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
            else -> result.notImplemented()
        }
    }
}
