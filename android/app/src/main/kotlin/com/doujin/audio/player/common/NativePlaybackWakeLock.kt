package com.doujin.audio.player.common

import android.annotation.SuppressLint
import android.content.Context
import android.os.PowerManager

/**
 * Holds the CPU wake lock that keeps handler-driven playback timers and
 * recovery work running while the screen is off.
 *
 * ExoPlayer owns the Wi-Fi lock for network queues through its configured
 * wake mode. Keeping that responsibility in one owner avoids a second,
 * unconditional Wi-Fi lock for local playback.
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
        val currentWakeLock = wakeLock
        wakeLock = null

        try {
            if (currentWakeLock?.isHeld == true) {
                currentWakeLock.release()
                logInfo("wakelock_released")
            }
        } catch (e: RuntimeException) {
            logWarn("wakelock_release_failed", e)
        }
    }
}
