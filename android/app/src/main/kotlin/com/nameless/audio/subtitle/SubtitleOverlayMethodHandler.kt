package com.nameless.audio.subtitle

import com.nameless.audio.channel.*

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class SubtitleOverlayMethodHandler(
    private val coordinator: SubtitleOverlayCoordinator
) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            SubtitleOverlayMethods.CAN_DRAW_OVERLAYS -> result.success(coordinator.canDrawOverlays())
            SubtitleOverlayMethods.OPEN_OVERLAY_SETTINGS ->
                result.success(coordinator.openOverlaySettings())
            SubtitleOverlayMethods.START_OVERLAY -> {
                coordinator.start()
                result.success(true)
            }
            SubtitleOverlayMethods.STOP_OVERLAY -> {
                coordinator.stop()
                result.success(true)
            }
            SubtitleOverlayMethods.UPDATE_SUBTITLE -> {
                coordinator.updateSubtitle(call.argument<String>("text") ?: "")
                result.success(true)
            }
            SubtitleOverlayMethods.UPDATE_STYLE -> {
                coordinator.updateStyle(
                    SubtitleOverlayStyle(
                        fontSize = call.argument<Number>("fontSize")?.toFloat() ?: 18f,
                        backgroundColor = call.argument<String>("backgroundColor") ?: "#80000000",
                        textColor = call.argument<String>("textColor") ?: "#FFFFFF",
                        fontFamily = call.argument<String>("fontFamily") ?: "",
                        borderDepth = call.argument<Number>("borderDepth")?.toFloat() ?: 0.5f
                    )
                )
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }
}
