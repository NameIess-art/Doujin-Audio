package com.doujin.audio.player.common

import com.doujin.audio.channel.*
import com.doujin.audio.player.notification.PlaybackTimerAlarmScheduler
import com.doujin.audio.player.service.*
import com.doujin.audio.player.session.*

import android.content.Context
import android.database.sqlite.SQLiteException
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

class NativePlaybackBridge(
    private val context: Context,
    private val inactiveExecutor: Executor? = null
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var events: EventChannel.EventSink? = null
    private var listening = false
    @Volatile private var disposed = false
    private var attachedService: NativePlaybackService? = null
    private var commandService: NativePlaybackService? = null
    private val listenerId = "flutter-${UUID.randomUUID()}"
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingCalls = linkedSetOf<PendingServiceCall>()
    private val ownedInactiveExecutor: ExecutorService? = if (inactiveExecutor == null) {
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "doujin-playback-inactive").apply { isDaemon = true }
        }
    } else null
    private val offMainExecutor: Executor
        get() = inactiveExecutor ?: checkNotNull(ownedInactiveExecutor)

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
        // Codec decoding and large queue validation run on the channel's serial
        // background TaskQueue. Live vs inactive routing is decided once on main
        // so a command cannot execute both on cold storage and on a starting service.
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
            val liveService = NativePlaybackService.controller()
            val backgroundDispatch = command.dispatchBackground
            if (backgroundDispatch != null) {
                val targetSessionId = command.sessionId
                if (liveService != null && targetSessionId != null && liveService.hasSession(targetSessionId)) {
                    enqueuePendingCall(call.method, result, command)
                    return@post
                }
                command.prepareBackground?.invoke()
                dispatchOffMain(call.method, result, backgroundDispatch)
                return@post
            }
            if (!command.canStartService && liveService == null) {
                val inactiveDispatch = command.dispatchInactive
                if (inactiveDispatch != null) {
                    dispatchOffMain(call.method, result, inactiveDispatch)
                } else {
                    result.success(serviceUnavailable(call.method))
                }
                return@post
            }
            enqueuePendingCall(call.method, result, command)
        }
    }

    private fun enqueuePendingCall(
        method: String,
        result: MethodChannel.Result,
        command: ParsedPlaybackCommand
    ) {
        command.prepareForLive?.invoke()
        val pendingCall = PendingServiceCall(
            method = method,
            result = result,
            sessionId = command.sessionId,
            canStartService = command.canStartService,
            requireForegroundBootstrap = command.requireForegroundBootstrap,
            dispatchAsync = command.dispatchAsync,
            dispatch = command.dispatch
        )
        pendingCalls += pendingCall
        pendingCall.run()
    }

    private fun dispatchOffMain(
        method: String,
        result: MethodChannel.Result,
        dispatch: (Context) -> Map<String, Any?>
    ) {
        try {
            offMainExecutor.execute {
                val response = dispatchStoredPlayback(method) { dispatch(context) }
                mainHandler.post {
                    result.success(response)
                }
            }
        } catch (_: RejectedExecutionException) {
            result.success(serviceUnavailable(method))
        }
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        if (disposed || eventSink == null) return
        listening = true
        events = eventSink
        syncControllerListenerRegistration()
        attachEventListenerIfNeeded(NativePlaybackService.controller())
    }

    override fun onCancel(arguments: Any?) {
        listening = false
        syncControllerListenerRegistration()
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
        ownedInactiveExecutor?.shutdown()
    }

    private fun syncControllerListenerRegistration() {
        if (!disposed && (listening || pendingCalls.isNotEmpty())) {
            NativePlaybackService.addControllerListener(listenerId, ::handleControllerChanged)
        } else {
            NativePlaybackService.removeControllerListener(listenerId)
        }
    }

    private fun flushPendingCalls() {
        if (disposed || pendingCalls.isEmpty()) return
        pendingCalls.toList().forEach { call ->
            mainHandler.removeCallbacks(call)
            call.run()
        }
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
        if (disposed) return
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { handleControllerChangedOnMain(service) }
            return
        }
        handleControllerChangedOnMain(service)
    }

    private fun handleControllerChangedOnMain(service: NativePlaybackService?) {
        if (disposed) return
        if (service == null) {
            if (listening) {
                attachedService?.removeStateListener(listenerId)
                attachedService = null
            }
            return
        }
        if (listening) {
            attachEventListenerIfNeeded(service)
        }
        if (pendingCalls.isNotEmpty()) {
            mainHandler.post(::flushPendingCalls)
        }
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
            val service = try {
                if (serviceStartRequested) {
                    NativePlaybackService.controller()
                } else {
                    serviceStartRequested = true
                    if (canStartService) ensureService(requireForegroundBootstrap)
                    else NativePlaybackService.controller()
                }
            } catch (error: Exception) {
                complete(commandFailure(error))
                return
            }
            if (service != null) {
                commandService = service
                attachEventListenerIfNeeded(service)
                if (dispatchAsync != null) {
                    try {
                        dispatchAsync.invoke(service, ::complete)
                    } catch (error: Exception) {
                        complete(commandFailure(error))
                    }
                    return
                }
                val response = try {
                    dispatch(service)
                } catch (error: Exception) {
                    commandFailure(error)
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
            syncControllerListenerRegistration()
            mainHandler.postDelayed(this, SERVICE_READY_RETRY_DELAY_MS)
        }

        fun cancel() {
            mainHandler.removeCallbacks(this)
            complete(serviceUnavailable(method))
        }

        fun isPlaybackStartFor(targetId: String): Boolean =
            isPendingPlaybackStartForSession(method, sessionId, targetId)

        fun isPlaybackStart(): Boolean = sessionId != null && isPlaybackStartFor(sessionId)

        private fun commandFailure(error: Exception): Map<String, Any?> = when (error) {
            is IllegalArgumentException -> channelFailure(
                code = ChannelErrorCodes.INVALID_ARGUMENT,
                message = error.message ?: "Invalid arguments.",
                details = mapOf("method" to method)
            )
            else -> {
                Log.w("NativePlaybackBridge", "Native playback command failed: $method", error)
                channelFailure(
                    code = ChannelErrorCodes.PLAYER_ERROR,
                    message = error.message ?: "Native playback command failed.",
                    details = mapOf("method" to method)
                )
            }
        }

        private fun complete(response: Map<String, Any?>) {
            if (completed) return
            completed = true
            mainHandler.removeCallbacks(this)
            pendingCalls.remove(this)
            syncControllerListenerRegistration()
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

private inline fun dispatchStoredPlayback(
    method: String,
    dispatch: () -> Map<String, Any?>
): Map<String, Any?> = try {
    dispatch()
} catch (error: SQLiteException) {
    Log.w("NativePlaybackBridge", "Stored playback operation failed: $method", error)
    channelFailure(
        code = ChannelErrorCodes.PLATFORM_ERROR,
        message = "Unable to access stored playback state.",
        details = mapOf("method" to method)
    )
}

internal fun isSupportedNativePlaybackMethod(method: String): Boolean = method in setOf(
    NativePlaybackMethods.READ_USAGE,
    NativePlaybackMethods.ACKNOWLEDGE_USAGE,
    NativePlaybackMethods.RESET_USAGE,
    NativePlaybackMethods.PREPARE_SESSION,
    NativePlaybackMethods.PLAY,
    NativePlaybackMethods.PAUSE,
    NativePlaybackMethods.STOP,
    NativePlaybackMethods.SEEK,
    NativePlaybackMethods.SET_VOLUME,
    NativePlaybackMethods.SET_SPEED,
    NativePlaybackMethods.SET_TEMPORARY_SPEED,
    NativePlaybackMethods.SET_FADE_MULTIPLIER,
    NativePlaybackMethods.SET_STOP_AFTER_CURRENT_TRACK,
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
    val prepareBackground: (() -> Unit)? = null,
    val prepareForLive: (() -> Unit)? = null,
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
        NativePlaybackMethods.READ_USAGE -> ParsedPlaybackCommand(dispatchInactive = { context ->
            channelSuccess(NativePlaybackUsageLedger.get(context).read())
        }) { service -> service.readUsage() }
        NativePlaybackMethods.ACKNOWLEDGE_USAGE -> {
            val ids = arguments.requiredList("batchIds")
            require(ids.all { it is String && it.isNotEmpty() }) { "batchIds is required." }
            val batchIds = ids.map { it as String }.toSet()
            ParsedPlaybackCommand(dispatchInactive = { context ->
                NativePlaybackUsageLedger.get(context).acknowledge(batchIds)
                channelSuccess(null)
            }) { service -> service.acknowledgeUsage(batchIds) }
        }
        NativePlaybackMethods.RESET_USAGE -> ParsedPlaybackCommand(dispatchInactive = { context ->
            NativePlaybackUsageLedger.get(context).reset()
            channelSuccess(null)
        }) { service -> service.resetUsage() }

        NativePlaybackMethods.PREPARE_SESSION -> {
            val prepared = NativePlaybackCommandPayloads.parsePrepareSession(call.argumentsMap())
            var liveRevision: Long? = null
            fun versionedForLive(): NativePrepareSessionArguments {
                val revision = liveRevision ?: NativePlaybackStateStore.invalidateSession(prepared.sessionId)
                    .also { liveRevision = it }
                return prepared.copy(definitionRevision = revision)
            }
            if (prepared.deferPlayerCreation && !prepared.autoPlay) {
                val stored = prepared.storedDefinition()
                var stagedRevision: Long? = null
                return ParsedPlaybackCommand(
                    sessionId = prepared.sessionId,
                    canStartService = false,
                    prepareBackground = {
                        val revision = NativePlaybackStateStore.invalidateSession(prepared.sessionId)
                        stagedRevision = revision
                        NativePlaybackStateStore.stageSessions(
                            listOf(stored),
                            mapOf(prepared.sessionId to revision)
                        )
                    },
                    prepareForLive = {
                        liveRevision = NativePlaybackStateStore.invalidateSession(prepared.sessionId)
                    },
                    dispatchBackground = { context ->
                        val revision = stagedRevision
                        if (revision != null) {
                            NativePlaybackStateStore.upsertSessions(
                                context,
                                listOf(stored),
                                mapOf(prepared.sessionId to revision)
                            )
                        } else {
                            NativePlaybackStateStore.saveColdSession(context, stored)
                        }
                        channelSuccess(null)
                    },
                    dispatchAsync = { service, complete ->
                        service.prepareSessionAsync(versionedForLive(), complete)
                    }
                ) { service ->
                    service.prepareSession(versionedForLive())
                }
            }
            ParsedPlaybackCommand(
                sessionId = prepared.sessionId,
                canStartService = prepared.autoPlay || !prepared.deferPlayerCreation,
                requireForegroundBootstrap = prepared.autoPlay,
                prepareForLive = {
                    liveRevision = NativePlaybackStateStore.invalidateSession(prepared.sessionId)
                },
                dispatchAsync = { service, complete ->
                    service.prepareSessionAsync(versionedForLive(), complete)
                }
            ) { service ->
                service.prepareSession(versionedForLive())
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
        NativePlaybackMethods.SET_STOP_AFTER_CURRENT_TRACK -> {
            val sessionId = arguments.requiredString("sessionId")
            val enabled = arguments.requiredBoolean("enabled")
            ParsedPlaybackCommand { service -> service.setStopAfterCurrentTrack(sessionId, enabled) }
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
                val hadTimerRuntime = NativePlaybackStateStore.loadTimerRuntimeState(context) != null
                NativePlaybackStateStore.removeSession(context, sessionId)
                if (hadTimerRuntime) {
                    PlaybackTimerAlarmScheduler.rescheduleFromStoredState(context)
                }
                channelSuccess(null)
            }) { service -> service.removeSession(sessionId) }
        }
        NativePlaybackMethods.PAUSE_ALL -> ParsedPlaybackCommand(cancelAllPendingStarts = true, dispatchInactive = { context ->
            NativePlaybackStateStore.pauseStoredSessions(context)
            channelSuccess(null)
        }) { service -> service.pauseAll() }
        NativePlaybackMethods.CLEAR_ALL -> ParsedPlaybackCommand(cancelAllPendingStarts = true, dispatchInactive = { context ->
            NativePlaybackStateStore.clearSessions(context)
            NativePlaybackStateStore.clearPausedSessionIds(context)
            NativePlaybackStateStore.clearTimerCandidateSessionIds(context)
            NativePlaybackStateStore.clearTimerRuntimeState(context)
            PlaybackTimerAlarmScheduler.rescheduleFromStoredState(context)
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
