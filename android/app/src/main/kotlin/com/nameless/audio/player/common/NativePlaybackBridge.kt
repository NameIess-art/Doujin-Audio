package com.nameless.audio.player.common

import com.nameless.audio.channel.*
import com.nameless.audio.player.service.*
import com.nameless.audio.player.session.NativeAudioEffects

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class NativePlaybackBridge(
    private val context: Context
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var events: EventChannel.EventSink? = null
    private var listening = false
    private var disposed = false
    private var attachedService: NativePlaybackService? = null
    private val listenerId = "flutter-${UUID.randomUUID()}"
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingCalls = linkedSetOf<PendingServiceCall>()
    private var pendingEventAttachment: PendingEventAttachment? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.success(serviceUnavailable(call.method))
            return
        }
        if (!isSupportedNativePlaybackMethod(call.method)) {
            result.notImplemented()
            return
        }
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
        val dispatch: (NativePlaybackService) -> Map<String, Any?> = { service ->
            when (call.method) {
                NativePlaybackMethods.PREPARE_SESSION -> service.prepareSession(prepareArguments!!)
                NativePlaybackMethods.PLAY -> service.play(
                    call.requiredString("sessionId"),
                    call.requiredLong("transportCommandId"),
                    call.argument<Boolean>("exclusive") ?: false
                )
                NativePlaybackMethods.PAUSE -> service.pause(
                    call.requiredString("sessionId"),
                    call.requiredLong("transportCommandId")
                )
                NativePlaybackMethods.STOP -> service.stop(call.requiredString("sessionId"))
                NativePlaybackMethods.SEEK -> service.seek(
                    call.requiredString("sessionId"),
                    call.requiredLong("positionMs")
                )
                NativePlaybackMethods.SET_VOLUME -> service.setVolume(
                    call.requiredString("sessionId"),
                    call.requiredDouble("volume").toFloat()
                )
                NativePlaybackMethods.SET_SPEED -> service.setSpeed(
                    call.requiredString("sessionId"),
                    call.requiredDouble("speed").toFloat()
                )
                NativePlaybackMethods.SET_FADE_MULTIPLIER -> service.setFadeMultiplier(
                    call.requiredString("sessionId"),
                    call.requiredDouble("multiplier").toFloat()
                )
                NativePlaybackMethods.SET_REPEAT_ONE -> service.setRepeatOne(repeatArguments!!)
                NativePlaybackMethods.SET_AUDIO_EFFECTS -> service.setAudioEffects(
                    audioEffectsSessionId!!,
                    audioEffects!!
                )
                NativePlaybackMethods.REMOVE_SESSION -> service.removeSession(call.requiredString("sessionId"))
                NativePlaybackMethods.PAUSE_ALL -> service.pauseAll()
                NativePlaybackMethods.CLEAR_ALL -> service.clearAll()
                NativePlaybackMethods.SET_FOREGROUND_ENABLED -> service.setForegroundEnabled(
                    call.argument<Boolean>("enabled") ?: true
                )
                NativePlaybackMethods.SET_PLAYBACK_BEHAVIOR -> {
                    val reader = call.argumentReader()
                    service.setPlaybackBehavior(
                        pauseOnAudioDeviceDisconnect =
                            reader.requiredBoolean("pauseOnAudioDeviceDisconnect"),
                        pauseOnTransientAudioFocusLoss =
                            reader.requiredBoolean("pauseOnTransientAudioFocusLoss"),
                        resumeAfterTransientAudioFocusGain =
                            reader.requiredBoolean("resumeAfterTransientAudioFocusGain"),
                        resumePlaybackOnStartupRestore =
                            reader.requiredBoolean("resumePlaybackOnStartupRestore")
                    )
                }
                NativePlaybackMethods.DISMISS_NOTIFICATIONS -> service.dismissNotifications()
                NativePlaybackMethods.UNDISMISS_NOTIFICATIONS -> service.undismissNotifications()
                NativePlaybackMethods.SNAPSHOT -> service.snapshot()
                else -> error("Unsupported native playback method: ${call.method}")
            }
        }
        val pendingCall = PendingServiceCall(
            call = call,
            result = result,
            requireForegroundBootstrap = call.requiresForegroundBootstrap(prepareArguments),
            dispatch = dispatch
        )
        pendingCalls += pendingCall
        pendingCall.run()
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        if (disposed || eventSink == null) return
        listening = true
        events = eventSink
        pendingEventAttachment?.cancel()
        val attachment = PendingEventAttachment(eventSink)
        pendingEventAttachment = attachment
        attachment.run()
    }

    override fun onCancel(arguments: Any?) {
        listening = false
        pendingEventAttachment?.cancel()
        attachedService?.removeStateListener(listenerId)
        attachedService = null
        events = null
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        listening = false
        pendingEventAttachment?.cancel()
        pendingCalls.toList().forEach(PendingServiceCall::cancel)
        mainHandler.removeCallbacksAndMessages(null)
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
        )
    }

    private fun attachEventListenerIfNeeded(service: NativePlaybackService?) {
        if (disposed || !listening || service == null) return
        if (attachedService === service) {
            pendingEventAttachment?.complete()
            return
        }
        attachedService?.removeStateListener(listenerId)
        attachedService = service
        service.addStateListener(listenerId) { snapshot ->
            events?.success(snapshot)
        }
        service.settleForegroundAfterBridgeAttach()
        pendingEventAttachment?.complete()
    }

    private inner class PendingEventAttachment(
        private val eventSink: EventChannel.EventSink
    ) : Runnable {
        private val startedAtMs = SystemClock.elapsedRealtime()
        private var serviceStartRequested = false
        private var completed = false

        override fun run() {
            if (completed || disposed || !listening || events !== eventSink) {
                cancel()
                return
            }
            val service = if (serviceStartRequested) {
                NativePlaybackService.controller()
            } else {
                serviceStartRequested = true
                ensureService()
            }
            if (service != null) {
                attachEventListenerIfNeeded(service)
                return
            }
            if (SystemClock.elapsedRealtime() - startedAtMs >= SERVICE_READY_TIMEOUT_MS) {
                complete()
                if (!disposed && listening && events === eventSink) {
                    eventSink.error(
                        ChannelErrorCodes.SERVICE_UNAVAILABLE,
                        "Native playback service is not ready.",
                        null
                    )
                }
                return
            }
            mainHandler.postDelayed(this, SERVICE_READY_RETRY_DELAY_MS)
        }

        fun cancel() {
            complete()
        }

        fun complete() {
            if (completed) return
            completed = true
            mainHandler.removeCallbacks(this)
            if (pendingEventAttachment === this) {
                pendingEventAttachment = null
            }
        }
    }

    private inner class PendingServiceCall(
        private val call: MethodCall,
        private val result: MethodChannel.Result,
        private val requireForegroundBootstrap: Boolean,
        private val dispatch: (NativePlaybackService) -> Map<String, Any?>
    ) : Runnable {
        private val startedAtMs = SystemClock.elapsedRealtime()
        private var completed = false
        private var serviceStartRequested = false

        override fun run() {
            if (completed) return
            if (disposed) {
                cancel()
                return
            }
            val service = if (serviceStartRequested) {
                NativePlaybackService.controller()
            } else {
                serviceStartRequested = true
                ensureService(requireForegroundBootstrap)
            }
            if (service != null) {
                attachEventListenerIfNeeded(service)
                val response = try {
                    dispatch(service)
                } catch (error: IllegalArgumentException) {
                    channelFailure(
                        code = ChannelErrorCodes.INVALID_ARGUMENT,
                        message = error.message ?: "Invalid arguments.",
                        details = mapOf("method" to call.method)
                    )
                }
                complete(response)
                return
            }
            val elapsedMs = SystemClock.elapsedRealtime() - startedAtMs
            if (elapsedMs >= SERVICE_READY_TIMEOUT_MS) {
                complete(serviceUnavailable(call.method))
                return
            }
            mainHandler.postDelayed(this, SERVICE_READY_RETRY_DELAY_MS)
        }

        fun cancel() {
            mainHandler.removeCallbacks(this)
            complete(serviceUnavailable(call.method))
        }

        private fun complete(response: Map<String, Any?>) {
            if (completed) return
            completed = true
            mainHandler.removeCallbacks(this)
            pendingCalls.remove(this)
            result.success(response)
        }
    }

    private companion object {
        const val SERVICE_READY_RETRY_DELAY_MS = 50L
        const val SERVICE_READY_TIMEOUT_MS = 2_000L
    }
}

internal fun isSupportedNativePlaybackMethod(method: String): Boolean = method in setOf(
    NativePlaybackMethods.PREPARE_SESSION,
    NativePlaybackMethods.PLAY,
    NativePlaybackMethods.PAUSE,
    NativePlaybackMethods.STOP,
    NativePlaybackMethods.SEEK,
    NativePlaybackMethods.SET_VOLUME,
    NativePlaybackMethods.SET_SPEED,
    NativePlaybackMethods.SET_FADE_MULTIPLIER,
    NativePlaybackMethods.SET_REPEAT_ONE,
    NativePlaybackMethods.SET_AUDIO_EFFECTS,
    NativePlaybackMethods.REMOVE_SESSION,
    NativePlaybackMethods.PAUSE_ALL,
    NativePlaybackMethods.CLEAR_ALL,
    NativePlaybackMethods.SET_FOREGROUND_ENABLED,
    NativePlaybackMethods.SET_PLAYBACK_BEHAVIOR,
    NativePlaybackMethods.DISMISS_NOTIFICATIONS,
    NativePlaybackMethods.UNDISMISS_NOTIFICATIONS,
    NativePlaybackMethods.SNAPSHOT
)

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
        NativePlaybackMethods.SET_PLAYBACK_BEHAVIOR -> {
            arguments.requiredBoolean("pauseOnAudioDeviceDisconnect")
            arguments.requiredBoolean("pauseOnTransientAudioFocusLoss")
            arguments.requiredBoolean("resumeAfterTransientAudioFocusGain")
            arguments.requiredBoolean("resumePlaybackOnStartupRestore")
        }
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
