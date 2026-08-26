package com.doujin.audio.player.service

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat

internal fun startNativePlaybackService(
    context: Context,
    intent: Intent,
    requireForegroundBootstrap: Boolean,
    prepareForegroundFallback: (Intent) -> Unit,
    controller: () -> NativePlaybackService?
): NativePlaybackService? {
    try {
        if (requireForegroundBootstrap) {
            ContextCompat.startForegroundService(context.applicationContext, intent)
        } else {
            context.applicationContext.startService(intent)
        }
    } catch (initialError: Exception) {
        try {
            prepareForegroundFallback(intent)
            ContextCompat.startForegroundService(context.applicationContext, intent)
        } catch (foregroundError: Exception) {
            Log.w(
                "NativePlaybackService",
                "Unable to start native playback service",
                foregroundError
            )
            foregroundError.addSuppressed(initialError)
        }
    }
    return controller()
}

internal fun runPlaybackShutdownActions(actions: Iterable<() -> Any?>): Throwable? {
    var firstFailure: Throwable? = null
    actions.forEach { action ->
        try {
            action()
        } catch (error: Throwable) {
            if (firstFailure == null) firstFailure = error
        }
    }
    return firstFailure
}
