package com.doujin.audio.player.service

internal const val nativePlaybackStartAction = "com.doujin.audio.native.START"
internal const val nativePlaybackTransportAction = "com.doujin.audio.native.TRANSPORT"

internal const val NATIVE_PLAYBACK_TRANSPORT_PREVIOUS = "previous"
internal const val NATIVE_PLAYBACK_TRANSPORT_PLAY_PAUSE = "play_pause"
internal const val NATIVE_PLAYBACK_TRANSPORT_NEXT = "next"

private val allowedTransportCommands = setOf(
    NATIVE_PLAYBACK_TRANSPORT_PREVIOUS,
    NATIVE_PLAYBACK_TRANSPORT_PLAY_PAUSE,
    NATIVE_PLAYBACK_TRANSPORT_NEXT
)

internal enum class NativePlaybackStartSource {
    INTERNAL,
    TRANSPORT,
    STICKY_RESTART,
    REJECTED
}

internal data class NativePlaybackStartDecision(
    val source: NativePlaybackStartSource,
    val requireForegroundBootstrap: Boolean = false,
    val transportCommand: String? = null,
    val rejectionReason: String? = null
) {
    val accepted: Boolean
        get() = source != NativePlaybackStartSource.REJECTED
    val shouldAttemptRestore: Boolean
        get() = source == NativePlaybackStartSource.INTERNAL ||
            source == NativePlaybackStartSource.STICKY_RESTART
}

internal fun evaluateNativePlaybackStart(
    intentPresent: Boolean,
    action: String?,
    presentedToken: String?,
    expectedToken: String,
    bootstrapExtraPresent: Boolean,
    bootstrapExtra: Any?,
    transportCommand: Any? = null
): NativePlaybackStartDecision {
    if (!intentPresent) {
        return NativePlaybackStartDecision(NativePlaybackStartSource.STICKY_RESTART)
    }
    if (action == nativePlaybackTransportAction) {
        if (presentedToken.isNullOrEmpty() || presentedToken != expectedToken) {
            return rejectedPlaybackStart("invalid_internal_token")
        }
        val command = transportCommand as? String
        if (command == null || command !in allowedTransportCommands) {
            return rejectedPlaybackStart("invalid_transport_command")
        }
        return NativePlaybackStartDecision(
            source = NativePlaybackStartSource.TRANSPORT,
            transportCommand = command
        )
    }
    if (action != nativePlaybackStartAction) {
        return rejectedPlaybackStart("unknown_action")
    }
    if (presentedToken.isNullOrEmpty() || presentedToken != expectedToken) {
        return rejectedPlaybackStart("invalid_internal_token")
    }
    if (bootstrapExtraPresent && bootstrapExtra !is Boolean) {
        return rejectedPlaybackStart("invalid_bootstrap_extra")
    }
    return NativePlaybackStartDecision(
        source = NativePlaybackStartSource.INTERNAL,
        requireForegroundBootstrap = bootstrapExtra as? Boolean ?: false
    )
}

private fun rejectedPlaybackStart(reason: String) = NativePlaybackStartDecision(
    source = NativePlaybackStartSource.REJECTED,
    rejectionReason = reason
)

internal enum class IdlePlaybackServiceStopAction {
    SKIP,
    DEFER,
    STOP
}

internal data class IdlePlaybackServiceStopDecision(
    val action: IdlePlaybackServiceStopAction,
    val startId: Int? = null
)

internal fun decideIdlePlaybackServiceStopAfterRestore(
    hasSessions: Boolean,
    hasPlaybackToKeepAlive: Boolean,
    restoreGeneration: Long,
    currentRestoreGeneration: Long,
    latestStartId: Int,
    hasPendingCommandDelivery: Boolean
): IdlePlaybackServiceStopDecision {
    if (hasSessions ||
        hasPlaybackToKeepAlive ||
        restoreGeneration != currentRestoreGeneration
    ) {
        return IdlePlaybackServiceStopDecision(IdlePlaybackServiceStopAction.SKIP)
    }
    return if (hasPendingCommandDelivery) {
        IdlePlaybackServiceStopDecision(
            action = IdlePlaybackServiceStopAction.DEFER,
            startId = latestStartId
        )
    } else {
        IdlePlaybackServiceStopDecision(
            action = IdlePlaybackServiceStopAction.STOP,
            startId = latestStartId
        )
    }
}

internal fun isPlaybackServiceControllerAvailable(
    instancePresent: Boolean,
    stoppingForIdleExit: Boolean
): Boolean = instancePresent && !stoppingForIdleExit
