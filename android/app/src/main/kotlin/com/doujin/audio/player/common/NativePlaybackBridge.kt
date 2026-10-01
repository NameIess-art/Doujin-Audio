package com.doujin.audio.player.common

import com.doujin.audio.channel.*
import com.doujin.audio.player.service.*
import com.doujin.audio.player.session.*

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
    @Volatile private var disposed = false
    private var attachedService: NativePlaybackService? = null
    private var commandService: NativePlaybackService? = null
    private val listenerId = "flutter-${UUID.randomUUID()}"
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingCalls = linkedSetOf<PendingServiceCall>()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.success(serviceUnavailable(call.method))
            return
        }
        if (!isSupportedNativePlaybackMethod(call.method)) {
            result.notImplemented()
            return
        }
        val command = try {
            parsePlaybackCommand(call)
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
        command.dispatchBackground?.let { dispatch ->
            // The serial channel TaskQueue owns cold definition I/O. It must
            // never attach to a service running for another session.
            result.success(dispatch(context))
            return
        }
        val inactiveResponse = if (!command.canStartService && NativePlaybackService.controller() == null) {
            command.dispatchInactive?.invoke(context) ?: serviceUnavailable(call.method)
        } else null
        // Codec decoding and large queue validation run on the channel's serial
        // background TaskQueue. Player and service ownership stays on main.
        mainHandler.post {
            if (disposed) {
                result.success(serviceUnavailable(call.method))
                return@post
            }
            command.cancelPendingStartForSession?.let { sessionId ->
                pendingCalls.toList().filter { it.isPlaybackStartFor(sessionId) }
                    .forEach(PendingServiceCall::cancel)
            }
            if (command.cancelAllPendingStarts) pendingCalls.toList()
                .filter { it.isPlaybackStart() }.forEach(PendingServiceCall::cancel)
            if (inactiveResponse != null && NativePlaybackService.controller() == null) {
                result.success(inactiveResponse)
                return@post
            }
            val pendingCall = PendingServiceCall(
                method = call.method, result = result,
                sessionId = command.sessionId,
                canStartService = command.canStartService,
                requireForegroundBootstrap = command.requireForegroundBootstrap,
                dispatchAsync = command.dispatchAsync, dispatch = command.dispatch
            )
            pendingCalls += pendingCall
            pendingCall.run()
        }
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        if (disposed || eventSink == null) return
        listening = true
        events = eventSink
        NativePlaybackService.addControllerListener(
            listenerId,
            ::handleControllerChanged
        )
        attachEventListenerIfNeeded(NativePlaybackService.controller())
    }

    override fun onCancel(arguments: Any?) {
        listening = false
        NativePlaybackService.removeControllerListener(listenerId)
        attachedService?.removeStateListener(listenerId)
        attachedService = null
        events = null
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        listening = false
        pendingCalls.toList().forEach(PendingServiceCall::cancel)
        NativePlaybackService.removeControllerListener(listenerId)
        commandService?.clearTemporarySpeeds()
        commandService = null
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
        if (attachedService === service) return
        attachedService?.removeStateListener(listenerId)
        attachedService = service
        service.addStateListener(listenerId) { snapshot ->
            events?.success(snapshot)
        }
        service.settleForegroundAfterBridgeAttach()
    }

    private fun handleControllerChanged(service: NativePlaybackService?) {
        if (disposed || !listening) return
        if (service == null) {
            attachedService?.removeStateListener(listenerId)
            attachedService = null
            return
        }
        attachEventListenerIfNeeded(service)
    }

    private inner class PendingServiceCall(
        private val method: String,
        private val result: MethodChannel.Result,
        private val sessionId: String?,
        private val canStartService: Boolean,
        private val requireForegroundBootstrap: Boolean,
        private val dispatchAsync: ((NativePlaybackService, (Map<String, Any?>) -> Unit) -> Unit)?,
        private val dispatch: (NativePlaybackService) -> Map<String, Any?>
    ) : Runnable {
        private val startedAtMs = SystemClock.elapsedRealtime()
        private var completed = false
        private var serviceStartRequested = false

        init {
            NativePlaybackService.beginCommandDelivery()
        }

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
                if (canStartService) ensureService(requireForegroundBootstrap)
                else NativePlaybackService.controller()
            }
            if (service != null) {
                commandService = service
                attachEventListenerIfNeeded(service)
                if (dispatchAsync != null) {
                    dispatchAsync.invoke(service, ::complete)
                    return
                }
                val response = try {
                    dispatch(service)
                } catch (error: IllegalArgumentException) {
                    channelFailure(
                        code = ChannelErrorCodes.INVALID_ARGUMENT,
                        message = error.message ?: "Invalid arguments.",
                        details = mapOf("method" to method)
                    )
                }
                complete(response)
                return
            }
            if (!canStartService) {
                complete(serviceUnavailable(method))
                return
            }
            val elapsedMs = SystemClock.elapsedRealtime() - startedAtMs
            if (elapsedMs >= SERVICE_READY_TIMEOUT_MS) {
                complete(serviceUnavailable(method))
                return
            }
            mainHandler.postDelayed(this, SERVICE_READY_RETRY_DELAY_MS)
        }

        fun cancel() {
            mainHandler.removeCallbacks(this)
            complete(serviceUnavailable(method))
        }

        fun isPlaybackStartFor(targetId: String): Boolean =
            isPendingPlaybackStartForSession(method, sessionId, targetId)

        fun isPlaybackStart(): Boolean = sessionId != null && isPlaybackStartFor(sessionId)

        private fun complete(response: Map<String, Any?>) {
            if (completed) return
            completed = true
            mainHandler.removeCallbacks(this)
            pendingCalls.remove(this)
            try {
                result.success(response)
            } finally {
                NativePlaybackService.endCommandDelivery()
            }
        }
    }

    private companion object {
        const val SERVICE_READY_RETRY_DELAY_MS = 50L
        const val SERVICE_READY_TIMEOUT_MS = 5_000L
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
    NativePlaybackMethods.SET_TEMPORARY_SPEED,
    NativePlaybackMethods.SET_FADE_MULTIPLIER,
    NativePlaybackMethods.SET_REPEAT_ONE,
    NativePlaybackMethods.UPDATE_QUEUE,
    NativePlaybackMethods.SET_AUDIO_EFFECTS,
    NativePlaybackMethods.REMOVE_SESSION,
    NativePlaybackMethods.PAUSE_ALL,
    NativePlaybackMethods.CLEAR_ALL,
    NativePlaybackMethods.SET_PLAYBACK_BEHAVIOR,
    NativePlaybackMethods.SNAPSHOT
)

internal class ParsedPlaybackCommand(
    val sessionId: String? = null,
    val cancelPendingStartForSession: String? = null,
    val cancelAllPendingStarts: Boolean = false,
    val canStartService: Boolean = false,
    val requireForegroundBootstrap: Boolean = false,
    val dispatchBackground: ((Context) -> Map<String, Any?>)? = null,
    val dispatchInactive: ((Context) -> Map<String, Any?>)? = null,
    val dispatchAsync: ((NativePlaybackService, (Map<String, Any?>) -> Unit) -> Unit)? = null,
    val dispatch: (NativePlaybackService) -> Map<String, Any?>
)

internal fun parsePlaybackCommand(call: MethodCall): ParsedPlaybackCommand {
    val arguments = call.argumentReader()
    fun finiteFloatInRange(key: String, range: ClosedRange<Double>): Float {
        val value = arguments.requiredDouble(key)
        require(value in range) {
            "Numeric argument is outside the allowed range: $key"
        }
        return value.toFloat()
    }
    return when (call.method) {
        NativePlaybackMethods.PREPARE_SESSION -> {
            val prepared = NativePlaybackCommandPayloads.parsePrepareSession(call.argumentsMap())
            if (prepared.deferPlayerCreation && !prepared.autoPlay) {
                return ParsedPlaybackCommand(dispatchBackground = { context ->
                    NativePlaybackStateStore.saveColdSession(context, prepared.storedDefinition())
                    channelSuccess(null)
                }) { channelSuccess(null) }
            }
            val versioned = prepared.copy(definitionRevision = NativePlaybackStateStore.invalidateSession(prepared.sessionId))
            ParsedPlaybackCommand(sessionId = prepared.sessionId,
                canStartService = prepared.autoPlay || !prepared.deferPlayerCreation,
                requireForegroundBootstrap = prepared.autoPlay,
                dispatchAsync = { service, complete -> service.prepareSessionAsync(versioned, complete) }
            ) { service ->
                service.prepareSession(versioned)
            }
        }
        NativePlaybackMethods.PLAY -> {
            val sessionId = arguments.requiredString("sessionId")
            val transportCommandId = arguments.requiredLong("transportCommandId")
            require(transportCommandId >= 0L) {
                "transportCommandId must not be negative."
            }
            val exclusive = arguments.requiredBoolean("exclusive")
            ParsedPlaybackCommand(sessionId = sessionId,
                canStartService = true, requireForegroundBootstrap = true,
                dispatchAsync = { service, complete -> service.playAsync(sessionId, transportCommandId, exclusive, complete) }
            ) { service ->
                service.play(sessionId, transportCommandId, exclusive)
            }
        }
        NativePlaybackMethods.PAUSE -> {
            val sessionId = arguments.requiredString("sessionId")
            val transportCommandId = arguments.requiredLong("transportCommandId")
            require(transportCommandId >= 0L) {
                "transportCommandId must not be negative."
            }
            ParsedPlaybackCommand(cancelPendingStartForSession = sessionId,
                dispatchInactive = { channelSuccess(null) }
            ) { service -> service.pause(sessionId, transportCommandId) }
        }
        NativePlaybackMethods.STOP -> {
            val sessionId = arguments.requiredString("sessionId")
            ParsedPlaybackCommand(cancelPendingStartForSession = sessionId,
                dispatchInactive = { channelSuccess(null) }
            ) { service -> service.stop(sessionId) }
        }
        NativePlaybackMethods.SEEK -> {
            val sessionId = arguments.requiredString("sessionId")
            val positionMs = arguments.requiredLong("positionMs")
            require(positionMs >= 0L) {
                "positionMs must not be negative."
            }
            ParsedPlaybackCommand { service -> service.seek(sessionId, positionMs) }
        }
        NativePlaybackMethods.SET_VOLUME -> {
            val sessionId = arguments.requiredString("sessionId")
            val volume = finiteFloatInRange("volume", 0.0..3.0)
            ParsedPlaybackCommand { service -> service.setVolume(sessionId, volume) }
        }
        NativePlaybackMethods.SET_SPEED -> {
            val sessionId = arguments.requiredString("sessionId")
            val speed = finiteFloatInRange("speed", NATIVE_PLAYBACK_SPEED_RANGE)
            ParsedPlaybackCommand { service -> service.setSpeed(sessionId, speed) }
        }
        NativePlaybackMethods.SET_TEMPORARY_SPEED -> {
            val sessionId = arguments.requiredString("sessionId")
            val speed = arguments.requiredNullableDouble("speed", NATIVE_PLAYBACK_SPEED_RANGE)
                ?.toFloat()
            ParsedPlaybackCommand { service -> service.setTemporarySpeed(sessionId, speed) }
        }
        NativePlaybackMethods.SET_FADE_MULTIPLIER -> {
            val sessionId = arguments.requiredString("sessionId")
            val multiplier = finiteFloatInRange("multiplier", 0.0..1.0)
            ParsedPlaybackCommand { service -> service.setFadeMultiplier(sessionId, multiplier) }
        }
        NativePlaybackMethods.SET_REPEAT_ONE -> {
            val repeat = NativePlaybackCommandPayloads.parseRepeatOne(call.argumentsMap())
            ParsedPlaybackCommand(dispatchAsync = { service, complete ->
                service.setRepeatOneAsync(repeat, complete)
            }) { service -> service.setRepeatOne(repeat) }
        }
        NativePlaybackMethods.UPDATE_QUEUE -> {
            val queue = NativePlaybackCommandPayloads.parseUpdateQueue(call.argumentsMap())
            ParsedPlaybackCommand(dispatchAsync = { service, complete ->
                service.updateQueueAsync(queue, complete)
            }) { service -> service.updateQueue(queue) }
        }
        NativePlaybackMethods.SET_AUDIO_EFFECTS -> {
            val sessionId = arguments.requiredString("sessionId")
            val effects = NativePlaybackCommandPayloads.parseAudioEffects(
                arguments.requiredMap("effects")
            )
            ParsedPlaybackCommand { service -> service.setAudioEffects(sessionId, effects) }
        }
        NativePlaybackMethods.REMOVE_SESSION -> {
            val sessionId = arguments.requiredString("sessionId")
            ParsedPlaybackCommand(cancelPendingStartForSession = sessionId, dispatchInactive = { context ->
                NativePlaybackStateStore.removeSession(context, sessionId)
                channelSuccess(null)
            }) { service -> service.removeSession(sessionId) }
        }
        NativePlaybackMethods.PAUSE_ALL -> ParsedPlaybackCommand(cancelAllPendingStarts = true, dispatchInactive = { context ->
            NativePlaybackStateStore.saveSessionProgress(context,
                NativePlaybackStateStore.loadSessions(context).filterNot { it.isTemporary }.map {
                    it.toStoredProgress().copy(playing = false, playWhenReady = false)
                })
            channelSuccess(null)
        }) { service -> service.pauseAll() }
        NativePlaybackMethods.CLEAR_ALL -> ParsedPlaybackCommand(cancelAllPendingStarts = true, dispatchInactive = { context ->
            NativePlaybackStateStore.clearSessions(context)
            NativePlaybackStateStore.clearPausedSessionIds(context)
            NativePlaybackStateStore.clearTimerCandidateSessionIds(context)
            NativePlaybackStateStore.clearTimerRuntimeState(context)
            channelSuccess(null)
        }) { service -> service.clearAll() }
        NativePlaybackMethods.SET_PLAYBACK_BEHAVIOR -> {
            val pauseOnAudioDeviceDisconnect =
                arguments.requiredBoolean("pauseOnAudioDeviceDisconnect")
            val requestAudioFocus = arguments.requiredBoolean("requestAudioFocus")
            val pauseOnTransientAudioFocusLoss =
                arguments.requiredBoolean("pauseOnTransientAudioFocusLoss")
            val resumeAfterTransientAudioFocusGain =
                arguments.requiredBoolean("resumeAfterTransientAudioFocusGain")
            ParsedPlaybackCommand(dispatchInactive = { context ->
                NativePlaybackStateStore.savePlaybackBehavior(context, StoredPlaybackBehavior(
                    pauseOnAudioDeviceDisconnect, requestAudioFocus,
                    pauseOnTransientAudioFocusLoss, resumeAfterTransientAudioFocusGain
                ))
                channelSuccess(null)
            }) { service ->
                service.setPlaybackBehavior(
                    pauseOnAudioDeviceDisconnect = pauseOnAudioDeviceDisconnect,
                    requestAudioFocus = requestAudioFocus,
                    pauseOnTransientAudioFocusLoss = pauseOnTransientAudioFocusLoss,
                    resumeAfterTransientAudioFocusGain = resumeAfterTransientAudioFocusGain
                )
            }
        }
        NativePlaybackMethods.SNAPSHOT -> ParsedPlaybackCommand(dispatchInactive = {
            channelSuccess(inactiveNativePlaybackRuntimeSnapshot)
        }) { service -> service.snapshot() }
        else -> throw IllegalArgumentException("Unsupported native playback method: ${call.method}")
    }
}

// Recovery files are notification/timer inputs, not authoritative live state.
internal val inactiveNativePlaybackRuntimeSnapshot: Map<String, Any?> = mapOf(
    "sessions" to emptyList<Map<String, Any?>>(), "focusedSessionId" to null
)

internal fun isPendingPlaybackStartForSession(method: String, sessionId: String?, targetId: String): Boolean =
    sessionId == targetId && method in setOf(NativePlaybackMethods.PREPARE_SESSION, NativePlaybackMethods.PLAY)

private fun serviceUnavailable(method: String): Map<String, Any?> = channelFailure(
    code = ChannelErrorCodes.SERVICE_UNAVAILABLE,
    message = "Native playback service is not ready.",
    details = mapOf("method" to method)
)
