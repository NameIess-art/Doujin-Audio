package com.nameless.audio.player.common

import android.annotation.SuppressLint
import android.content.Context
import android.os.PowerManager

/**
 * Holds the CPU wake lock that keeps handler-driven playback timers (progress
 * heartbeat, health check, retry backoff) running while the screen is off.
 *
 * Wi-Fi is intentionally NOT locked here. ExoPlayer's own
 * [androidx.media3.common.C.WAKE_MODE_NETWORK] handling acquires a Wi-Fi lock
 * only while a network-backed item is actually loading, so a manual
 * always-on Wi-Fi lock would just disable Wi-Fi power save for the whole
 * session - including local-file playback that needs no network at all.
 */
internal class NativePlaybackWakeLock(
    private val context: Context,
    private val logInfo: (String) -> Unit,
    private val logWarn: (String, Exception) -> Unit
) {
    private var wakeLock: PowerManager.WakeLock? = null

    fun isHeld(): Boolean = wakeLock?.isHeld == true

    @SuppressLint("WakelockTimeout")
    fun acquire() {
        // syncForegroundState() runs on nearly every player event, so a
        // short-circuit keeps this off the binder/log hot path.
        if (isHeld()) return

        if (wakeLock == null) {
            try {
                val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
                wakeLock = powerManager?.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "${context.packageName}:native_playback"
                )?.apply {
                    setReferenceCounted(false)
                }
            } catch (e: Exception) {
                logWarn("wakelock_create_failed", e)
            }
        }

        val lock = wakeLock ?: return
        try {
            lock.acquire()
        } catch (e: Exception) {
            logWarn("wakelock_acquire_failed", e)
            return
        }
        if (lock.isHeld) logInfo("wakelock_acquired")
    }

    /**
     * Re-acquires the lock if an OEM power manager revoked it underneath us.
     * A no-op while the lock is still held.
     */
    fun refresh() {
        if (isHeld()) return
        logInfo("wakelock_refresh_reacquire")
        acquire()
    }

    fun release() {
        val currentWakeLock = wakeLock ?: return
        wakeLock = null
        try {
            if (currentWakeLock.isHeld) {
                currentWakeLock.release()
                logInfo("wakelock_released")
            }
        } catch (e: RuntimeException) {
            logWarn("wakelock_release_failed", e)
        }
    }
}
