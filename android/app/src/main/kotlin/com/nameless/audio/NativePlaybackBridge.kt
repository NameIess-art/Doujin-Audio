package com.nameless.audio

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object NativePlaybackMethods {
    const val PREPARE_SESSION = "prepareSession"
    const val PLAY = "play"
    const val PAUSE = "pause"
    const val STOP = "stop"
    const val SEEK = "seek"
    const val SET_VOLUME = "setVolume"
    const val SET_REPEAT_ONE = "setRepeatOne"
    const val SET_CHANNEL_SWAP = "setChannelSwap"
    const val REMOVE_SESSION = "removeSession"
    const val PAUSE_ALL = "pauseAll"
    const val CLEAR_ALL = "clearAll"
    const val SET_FOREGROUND_ENABLED = "setForegroundEnabled"
    const val DISMISS_NOTIFICATIONS = "dismissNotifications"
    const val UNDISMISS_NOTIFICATIONS = "undismissNotifications"
    const val SNAPSHOT = "snapshot"
}

class NativePlaybackBridge(
    private val context: Context
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var events: EventChannel.EventSink? = null
    private var listening = false
    private val listenerId = "flutter"
    private val mainHandler = Handler(Looper.getMainLooper())
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val service = ensureService(
            requireForegroundBootstrap = call.requiresForegroundBootstrap()
        )
        attachEventListenerIfNeeded(service)
        val response = try {
            when (call.method) {
                NativePlaybackMethods.PREPARE_SESSION -> service?.prepareSession(call.argumentsMap())
                    ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
                NativePlaybackMethods.PLAY -> service?.play(call.requiredString("sessionId"))
                    ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
                NativePlaybackMethods.PAUSE -> service?.pause(call.requiredString("sessionId"))
                    ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
                NativePlaybackMethods.STOP -> service?.stop(call.requiredString("sessionId"))
                    ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
                NativePlaybackMethods.SEEK -> service?.seek(
                    call.requiredString("sessionId"),
                    call.requiredLong("positionMs")
                ) ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
                NativePlaybackMethods.SET_VOLUME -> service?.setVolume(
                    call.requiredString("sessionId"),
                    call.requiredDouble("volume").toFloat()
                ) ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
                NativePlaybackMethods.SET_REPEAT_ONE -> service?.setRepeatOne(
                    call.requiredString("sessionId"),
                    call.argument<Boolean>("repeatOne") ?: false,
                    call.argumentsMap()
                ) ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
                NativePlaybackMethods.SET_CHANNEL_SWAP -> service?.setChannelSwap(
                    call.requiredString("sessionId"),
                    call.argument<Boolean>("enabled") ?: false
                ) ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
                NativePlaybackMethods.REMOVE_SESSION -> service?.removeSession(call.requiredString("sessionId"))
                    ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
                NativePlaybackMethods.PAUSE_ALL -> service?.pauseAll()
                    ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
                NativePlaybackMethods.CLEAR_ALL -> service?.clearAll()
                    ?: mapOf("ok" to true, "value" to null)
                NativePlaybackMethods.SET_FOREGROUND_ENABLED -> service?.setForegroundEnabled(
                    call.argument<Boolean>("enabled") ?: true
                ) ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
                NativePlaybackMethods.DISMISS_NOTIFICATIONS -> service?.dismissNotifications()
                    ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
                NativePlaybackMethods.UNDISMISS_NOTIFICATIONS -> service?.undismissNotifications()
                    ?: mapOf("ok" to false, "error" to "Native playback service is not ready.")
                NativePlaybackMethods.SNAPSHOT -> service?.snapshot()
                    ?: mapOf(
                        "ok" to true,
                        "value" to mapOf("sessions" to emptyList<Map<String, Any?>>())
                    )
                else -> {
                    result.notImplemented()
                    return
                }
            }
        } catch (error: IllegalArgumentException) {
            mapOf("ok" to false, "error" to (error.message ?: "Invalid arguments."))
        }
        publishResponseSnapshot(response)
        result.success(response)
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        listening = true
        events = eventSink
        attachEventListenerIfNeeded(ensureService())
        mainHandler.postDelayed({ if (listening) attachEventListenerIfNeeded(ensureService()) }, 80L)
        mainHandler.postDelayed({ if (listening) attachEventListenerIfNeeded(ensureService()) }, 240L)
    }

    override fun onCancel(arguments: Any?) {
        listening = false
        NativePlaybackService.controller()?.removeStateListener(listenerId)
        events = null
    }

    private fun ensureService(
        requireForegroundBootstrap: Boolean = false
    ): NativePlaybackService? {
        return NativePlaybackService.ensureStarted(
            context,
            requireForegroundBootstrap = requireForegroundBootstrap
        ).also { service ->
            if (service == null && listening) {
                mainHandler.postDelayed(
                    { if (listening) attachEventListenerIfNeeded(NativePlaybackService.controller()) },
                    80L
                )
            }
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

private fun MethodCall.requiresForegroundBootstrap(): Boolean {
    return when (method) {
        NativePlaybackMethods.PLAY -> true
        NativePlaybackMethods.PREPARE_SESSION -> argument<Boolean>("autoPlay") == true
        else -> false
    }
}

private fun MethodCall.argumentsMap(): Map<String, Any?> {
    @Suppress("UNCHECKED_CAST")
    return arguments as? Map<String, Any?> ?: emptyMap()
}

private fun MethodCall.requiredString(key: String): String {
    val value = argument<String>(key)?.trim()
    if (value.isNullOrEmpty()) {
        throw IllegalArgumentException("Missing required argument: $key")
    }
    return value
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
