package com.doujin.audio.player.service

internal const val nativePlaybackStartAction = "com.doujin.audio.native.START"

internal enum class NativePlaybackStartSource {
    INTERNAL,
    STICKY_RESTART,
    REJECTED
}

internal data class NativePlaybackStartDecision(
    val source: NativePlaybackStartSource,
    val requireForegroundBootstrap: Boolean = false,
    val rejectionReason: String? = null
) {
    val accepted: Boolean
        get() = source != NativePlaybackStartSource.REJECTED
    val shouldAttemptRestore: Boolean
        get() = accepted
}

internal fun evaluateNativePlaybackStart(
    intentPresent: Boolean,
    action: String?,
    presentedToken: String?,
    expectedToken: String,
    bootstrapExtraPresent: Boolean,
    bootstrapExtra: Any?
): NativePlaybackStartDecision {
    if (!intentPresent) {
        return NativePlaybackStartDecision(NativePlaybackStartSource.STICKY_RESTART)
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
