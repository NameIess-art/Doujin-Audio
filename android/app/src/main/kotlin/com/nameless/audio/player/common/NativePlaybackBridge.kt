package com.nameless.audio.player.common

import com.nameless.audio.channel.*
import com.nameless.audio.player.service.*
import com.nameless.audio.player.session.NativeAudioEffects

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
    private var listening = false
    private var attachedService: NativePlaybackService? = null
    private val listenerId = "flutter"
    private val mainHandler = Handler(Looper.getMainLooper())
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        var prepareArguments: NativePrepareSessionArguments? = null
        var repeatArguments: NativeRepeatOneArguments? = null
        var audioEffectsSessionId: String? = null
        var audioEffects: NativeAudioEffects? = null
        try {
            validatePlaybackArgumentsBeforeService(call)
            when (call.method) {
                NativePlaybackMethods.PREPARE_SESSION -> {
                    prepareArguments = NativePlaybackCommandPayloads.parsePrepareSession(
                        call.argumentsMap()
                    )
                }
                NativePlaybackMethods.SET_REPEAT_ONE -> {
                    repeatArguments = NativePlaybackCommandPayloads.parseRepeatOne(
                        call.argumentsMap()
                    )
                }
                NativePlaybackMethods.SET_AUDIO_EFFECTS -> {
                    val reader = call.argumentReader()
                    audioEffectsSessionId = reader.requiredString("sessionId")
                    val effects = reader.requiredMap("effects")
                    audioEffects = NativePlaybackCommandPayloads.parseAudioEffects(effects)
                }
            }
        } catch (error: IllegalArgumentException) {
            result.success(
                channelFailure(
                    code = ChannelErrorCodes.INVALID_ARGUMENT,
                    message = error.message ?: "Invalid arguments.",
                    details = mapOf("method" to call.method)
                )
            )
            return
        }
        val service = ensureService(
            requireForegroundBootstrap = call.requiresForegroundBootstrap(prepareArguments)
        )
        attachEventListenerIfNeeded(service)
        val response = try {
            when (call.method) {
                NativePlaybackMethods.PREPARE_SESSION -> service?.prepareSession(prepareArguments!!)
                    ?: serviceUnavailable(call.method)
                NativePlaybackMethods.PLAY -> service?.play(
                    call.requiredString("sessionId"),
                    call.requiredLong("transportCommandId"),
                    call.argument<Boolean>("exclusive") ?: false
                )
                    ?: serviceUnavailable(call.method)
                NativePlaybackMethods.PAUSE -> service?.pause(
                    call.requiredString("sessionId"),
                    call.requiredLong("transportCommandId")
                )
                    ?: serviceUnavailable(call.method)
                NativePlaybackMethods.STOP -> service?.stop(call.requiredString("sessionId"))
                    ?: serviceUnavailable(call.method)
                NativePlaybackMethods.SEEK -> service?.seek(
                    call.requiredString("sessionId"),
                    call.requiredLong("positionMs")
                ) ?: serviceUnavailable(call.method)
                NativePlaybackMethods.SET_VOLUME -> service?.setVolume(
                    call.requiredString("sessionId"),
                    call.requiredDouble("volume").toFloat()
                ) ?: serviceUnavailable(call.method)
                NativePlaybackMethods.SET_SPEED -> service?.setSpeed(
                    call.requiredString("sessionId"),
                    call.requiredDouble("speed").toFloat()
                ) ?: serviceUnavailable(call.method)
                NativePlaybackMethods.SET_FADE_MULTIPLIER -> service?.setFadeMultiplier(
                    call.requiredString("sessionId"),
                    call.requiredDouble("multiplier").toFloat()
                ) ?: serviceUnavailable(call.method)
                NativePlaybackMethods.SET_REPEAT_ONE -> service?.setRepeatOne(repeatArguments!!)
                    ?: serviceUnavailable(call.method)
                NativePlaybackMethods.SET_AUDIO_EFFECTS -> service?.setAudioEffects(
                    audioEffectsSessionId!!,
                    audioEffects!!
                ) ?: serviceUnavailable(call.method)
                NativePlaybackMethods.REMOVE_SESSION -> service?.removeSession(call.requiredString("sessionId"))
                    ?: serviceUnavailable(call.method)
                NativePlaybackMethods.PAUSE_ALL -> service?.pauseAll()
                    ?: serviceUnavailable(call.method)
                NativePlaybackMethods.CLEAR_ALL -> service?.clearAll()
                    ?: channelSuccess(null)
                NativePlaybackMethods.SET_FOREGROUND_ENABLED -> service?.setForegroundEnabled(
                    call.argument<Boolean>("enabled") ?: true
                ) ?: serviceUnavailable(call.method)
                NativePlaybackMethods.DISMISS_NOTIFICATIONS -> service?.dismissNotifications()
                    ?: serviceUnavailable(call.method)
                NativePlaybackMethods.UNDISMISS_NOTIFICATIONS -> service?.undismissNotifications()
                    ?: serviceUnavailable(call.method)
                NativePlaybackMethods.SNAPSHOT -> service?.snapshot()
                    ?: channelSuccess(mapOf("sessions" to emptyList<Map<String, Any?>>()))
                else -> {
                    result.notImplemented()
                    return
                }
            }
        } catch (error: IllegalArgumentException) {
            channelFailure(
                code = ChannelErrorCodes.INVALID_ARGUMENT,
                message = error.message ?: "Invalid arguments.",
                details = mapOf("method" to call.method)
            )
        }
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
        attachedService?.removeStateListener(listenerId)
        attachedService = null
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
        if (!listening || service == null || attachedService === service) return
        attachedService?.removeStateListener(listenerId)
        attachedService = service
        service.addStateListener(listenerId) { snapshot ->
            events?.success(snapshot)
        }
    }
}

internal fun validatePlaybackArgumentsBeforeService(call: MethodCall) {
    val arguments = call.argumentReader()
    fun requireSessionId() {
        arguments.requiredString("sessionId")
    }
    fun requireFiniteInRange(key: String, range: ClosedRange<Double>) {
        require(arguments.requiredDouble(key) in range) {
            "Numeric argument is outside the allowed range: $key"
        }
    }
    when (call.method) {
        NativePlaybackMethods.PLAY -> {
            requireSessionId()
            require(arguments.requiredLong("transportCommandId") >= 0L) {
                "transportCommandId must not be negative."
            }
            arguments.requiredBoolean("exclusive")
        }
        NativePlaybackMethods.PAUSE -> {
            requireSessionId()
            require(arguments.requiredLong("transportCommandId") >= 0L) {
                "transportCommandId must not be negative."
            }
        }
        NativePlaybackMethods.STOP,
        NativePlaybackMethods.REMOVE_SESSION -> requireSessionId()
        NativePlaybackMethods.SEEK -> {
            requireSessionId()
            require(arguments.requiredLong("positionMs") >= 0L) {
                "positionMs must not be negative."
            }
        }
        NativePlaybackMethods.SET_VOLUME -> {
            requireSessionId()
            requireFiniteInRange("volume", 0.0..2.0)
        }
        NativePlaybackMethods.SET_SPEED -> {
            requireSessionId()
            requireFiniteInRange("speed", 0.5..2.0)
        }
        NativePlaybackMethods.SET_FADE_MULTIPLIER -> {
            requireSessionId()
            requireFiniteInRange("multiplier", 0.0..1.0)
        }
        NativePlaybackMethods.SET_FOREGROUND_ENABLED -> arguments.requiredBoolean("enabled")
    }
}

private fun serviceUnavailable(method: String): Map<String, Any?> = channelFailure(
    code = ChannelErrorCodes.SERVICE_UNAVAILABLE,
    message = "Native playback service is not ready.",
    details = mapOf("method" to method)
)

private fun MethodCall.requiresForegroundBootstrap(
    prepareArguments: NativePrepareSessionArguments?
): Boolean {
    return when (method) {
        NativePlaybackMethods.PLAY -> true
        NativePlaybackMethods.PREPARE_SESSION -> prepareArguments?.autoPlay == true
        else -> false
    }
}
