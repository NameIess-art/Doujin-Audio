package com.example.music_player

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class NativePlaybackBridge(
    private val context: Context
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var events: EventChannel.EventSink? = null
    private val listenerId = "flutter"
    private val mainHandler = Handler(Looper.getMainLooper())
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val service = ensureService()
        attachEventListenerIfNeeded(service)
        val response = when (call.method) {
            "prepareSession" -> service?.prepareSession(call.argumentsMap())
                ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
            "play" -> service?.play(call.requiredString("sessionId"))
                ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
            "pause" -> service?.pause(call.requiredString("sessionId"))
                ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
            "stop" -> service?.stop(call.requiredString("sessionId"))
                ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
            "seek" -> service?.seek(
                call.requiredString("sessionId"),
                call.requiredLong("positionMs")
            ) ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
            "setVolume" -> service?.setVolume(
                call.requiredString("sessionId"),
                call.requiredDouble("volume").toFloat()
            ) ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
            "setRepeatOne" -> service?.setRepeatOne(
                call.requiredString("sessionId"),
                call.argument<Boolean>("repeatOne") ?: false
            ) ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
            "removeSession" -> service?.removeSession(call.requiredString("sessionId"))
                ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
            "pauseAll" -> service?.pauseAll()
                ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
            "clearAll" -> service?.clearAll()
                ?: mapOf("ok" to true, "value" to null)
            "setForegroundEnabled" -> service?.setForegroundEnabled(
                call.argument<Boolean>("enabled") ?: true
            ) ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
            "dismissNotifications" -> service?.dismissNotifications()
                ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
            "undismissNotifications" -> service?.undismissNotifications()
                ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
            "snapshot" -> service?.snapshot()
                ?: mapOf("sessions" to emptyList<Map<String, Any?>>())
            else -> {
                result.notImplemented()
                return
            }
        }
        publishResponseSnapshot(response)
        result.success(response)
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        events = eventSink
        attachEventListenerIfNeeded(ensureService())
        mainHandler.postDelayed({ attachEventListenerIfNeeded(ensureService()) }, 80L)
        mainHandler.postDelayed({ attachEventListenerIfNeeded(ensureService()) }, 240L)
    }

    override fun onCancel(arguments: Any?) {
        NativePlaybackService.controller()?.removeStateListener(listenerId)
        events = null
    }

    private fun ensureService(): NativePlaybackService? {
        val existing = NativePlaybackService.controller()
        if (existing != null) return existing
        val intent = Intent(context, NativePlaybackService::class.java).apply {
            action = NativePlaybackService.ACTION_START
        }
        return try {
            context.startService(intent)
            NativePlaybackService.controller().also { service ->
                if (service == null) {
                    mainHandler.postDelayed(
                        { attachEventListenerIfNeeded(NativePlaybackService.controller()) },
                        80L
                    )
                }
            }
        } catch (_: Exception) {
            NativePlaybackService.controller()
        }
    }

    private fun attachEventListenerIfNeeded(service: NativePlaybackService?) {
        if (service == null) return
        service.addStateListener(listenerId) { snapshot ->
            events?.success(snapshot)
        }
    }

    private fun publishResponseSnapshot(response: Map<String, Any?>) {
        val value = response["value"] as? Map<*, *> ?: return
        if (!value.containsKey("sessionId")) return
        events?.success(value)
    }
}

private fun MethodCall.argumentsMap(): Map<String, Any?> {
    @Suppress("UNCHECKED_CAST")
    return arguments as? Map<String, Any?> ?: emptyMap()
}

private fun MethodCall.requiredString(key: String): String {
    return argument<String>(key) ?: ""
}

private fun MethodCall.requiredLong(key: String): Long {
    return when (val value = argument<Any>(key)) {
        is Number -> value.toLong()
        else -> 0L
    }
}

private fun MethodCall.requiredDouble(key: String): Double {
    return when (val value = argument<Any>(key)) {
        is Number -> value.toDouble()
        else -> 0.0
    }
}
