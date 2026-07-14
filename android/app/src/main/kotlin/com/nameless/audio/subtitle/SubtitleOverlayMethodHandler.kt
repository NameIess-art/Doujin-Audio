package com.nameless.audio.subtitle

import com.nameless.audio.channel.*

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
                    coordinator.start()
                    envelope.success(true)
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
                    coordinator.updateStyle(
                        SubtitleOverlayStyle(
                            fontSize = if (arguments.hasKey("fontSize")) arguments.requiredDouble("fontSize").toFloat() else 18f,
                            backgroundColor = arguments.optionalString("backgroundColor") ?: "#80000000",
                            textColor = arguments.optionalString("textColor") ?: "#FFFFFF",
                            fontFamily = arguments.optionalString("fontFamily") ?: "",
                            borderDepth = if (arguments.hasKey("borderDepth")) arguments.requiredDouble("borderDepth").toFloat() else 0.5f
                        )
                    )
                    if (arguments.hasKey("backgroundOpacity")) {
                        arguments.requiredDouble("backgroundOpacity")
                    }
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
        }
    }
}
