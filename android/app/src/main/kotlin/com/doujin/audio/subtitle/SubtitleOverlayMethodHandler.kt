package com.doujin.audio.subtitle

import com.doujin.audio.channel.*

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class SubtitleOverlayMethodHandler(
    private val coordinator: SubtitleOverlayCoordinator
) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val envelope = ChannelEnvelopeResult(result)
        try {
            when (call.method) {
                SubtitleOverlayMethods.CAN_DRAW_OVERLAYS -> envelope.success(coordinator.canDrawOverlays())
                SubtitleOverlayMethods.OPEN_OVERLAY_SETTINGS ->
                    envelope.success(coordinator.openOverlaySettings())
                SubtitleOverlayMethods.START_OVERLAY -> {
                    envelope.success(coordinator.start())
                }
                SubtitleOverlayMethods.STOP_OVERLAY -> {
                    coordinator.stop()
                    envelope.success(true)
                }
                SubtitleOverlayMethods.UPDATE_SUBTITLE -> {
                    coordinator.updateSubtitle(call.argumentReader().requiredString("text", allowBlank = true))
                    envelope.success(true)
                }
                SubtitleOverlayMethods.UPDATE_STYLE -> {
                    val arguments = call.argumentReader()
                    val fontSize = arguments.requiredDouble("fontSize").also {
                        require(it > 0.0) { "Numeric argument must be positive: fontSize" }
                    }.toFloat()
                    val backgroundColor = arguments.requiredString("backgroundColor")
                    val textColor = arguments.requiredString("textColor")
                    val fontFamily = arguments.requiredString("fontFamily", allowBlank = true)
                    val borderDepth = arguments.requiredDouble("borderDepth").also {
                        require(it >= 0.0) { "Numeric argument must not be negative: borderDepth" }
                    }.toFloat()
                    if (arguments.hasKey("backgroundOpacity")) {
                        val backgroundOpacity = arguments.requiredDouble("backgroundOpacity")
                        require(backgroundOpacity in 0.0..1.0) {
                            "Numeric argument is outside the allowed range: backgroundOpacity"
                        }
                    }
                    coordinator.updateStyle(
                        SubtitleOverlayStyle(
                            fontSize = fontSize,
                            backgroundColor = backgroundColor,
                            textColor = textColor,
                            fontFamily = fontFamily,
                            borderDepth = borderDepth
                        )
                    )
                    envelope.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (error: IllegalArgumentException) {
            envelope.error(
                ChannelErrorCodes.INVALID_ARGUMENT,
                error.message ?: "Invalid arguments.",
                mapOf("method" to call.method)
            )
        } catch (error: IllegalStateException) {
            envelope.error(
                ChannelErrorCodes.PLATFORM_ERROR,
                error.message ?: "Subtitle overlay operation failed.",
                mapOf("method" to call.method)
            )
        } catch (error: SecurityException) {
            envelope.error(
                ChannelErrorCodes.PLATFORM_ERROR,
                error.message ?: "Subtitle overlay permission denied.",
                mapOf("method" to call.method)
            )
        } catch (error: Exception) {
            envelope.error(
                ChannelErrorCodes.PLATFORM_ERROR,
                error.message ?: "Subtitle overlay operation failed.",
                mapOf("method" to call.method)
            )
        }
    }
}
