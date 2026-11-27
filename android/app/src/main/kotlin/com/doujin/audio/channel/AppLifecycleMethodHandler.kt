package com.doujin.audio.channel

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class AppLifecycleMethodHandler(
    private val terminateForPendingRestore: () -> Unit,
    private val syncAppTheme: (String, String, Boolean) -> Unit = { _, _, _ -> },
    private val getSystemAccentColor: () -> Int? = { null },
    private val setImmersiveMode: (Boolean) -> Unit = {},
) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val envelope = ChannelEnvelopeResult(result)
        try {
            when (call.method) {
                AppLifecycleMethods.TERMINATE_FOR_PENDING_RESTORE -> {
                    envelope.success(null)
                    try {
                        terminateForPendingRestore()
                    } catch (_: Exception) {
                        // Response already sent; termination is best-effort.
                    }
                }
                AppLifecycleMethods.SYNC_APP_THEME -> {
                    val preset = call.requiredString("preset")
                    val themeMode = call.requiredString("themeMode")
                    val pureBlackRaw = call.argument<Any?>("pureBlack")
                    val pureBlack = when (pureBlackRaw) {
                        null -> false
                        is Boolean -> pureBlackRaw
                        else -> throw IllegalArgumentException("pureBlack must be a boolean")
                    }
                    syncAppTheme(preset, themeMode, pureBlack)
                    envelope.success(null)
                }
                AppLifecycleMethods.GET_SYSTEM_ACCENT_COLOR -> {
                    envelope.success(getSystemAccentColor())
                }
                AppLifecycleMethods.SET_IMMERSIVE_MODE -> {
                    setImmersiveMode(call.argumentReader().requiredBoolean("enabled"))
                    envelope.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: IllegalArgumentException) {
            envelope.error(
                ChannelErrorCodes.INVALID_ARGUMENT,
                error.message ?: "Invalid app lifecycle payload",
                mapOf("method" to call.method)
            )
        } catch (error: Exception) {
            envelope.error(
                ChannelErrorCodes.PLATFORM_ERROR,
                error.message ?: "App lifecycle operation failed.",
                mapOf("method" to call.method)
            )
        }
    }
}
