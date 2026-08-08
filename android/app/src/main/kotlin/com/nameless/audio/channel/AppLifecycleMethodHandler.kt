package com.nameless.audio.channel

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class AppLifecycleMethodHandler(
    private val terminateForPendingRestore: () -> Unit
) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            AppLifecycleMethods.TERMINATE_FOR_PENDING_RESTORE -> {
                result.success(channelSuccess(null))
                terminateForPendingRestore()
            }
            else -> result.notImplemented()
        }
    }
}
