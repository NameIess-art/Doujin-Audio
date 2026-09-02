package com.doujin.audio.channel

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class AppLifecycleMethodHandler(
    private val terminateForPendingRestore: () -> Unit,
    private val syncWindowSurface: (Int) -> Unit = {},
) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            AppLifecycleMethods.TERMINATE_FOR_PENDING_RESTORE -> {
                result.success(channelSuccess(null))
                terminateForPendingRestore()
            }
            AppLifecycleMethods.SYNC_WINDOW_SURFACE -> {
                try {
                    val color = call.requiredLong("color").toInt()
                    syncWindowSurface(color)
                    result.success(channelSuccess(null))
                } catch (error: IllegalArgumentException) {
                    result.success(
                        channelFailure(
                            ChannelErrorCodes.INVALID_ARGUMENT,
                            error.message ?: "Invalid window surface color",
                        )
                    )
                }
            }
            else -> result.notImplemented()
        }
    }
}
