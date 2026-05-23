package com.nameless.audio

import android.content.Context
import android.os.PowerManager

internal class NativePlaybackWakeLock(
    private val context: Context,
    private val logInfo: (String) -> Unit,
    private val logWarn: (String, Exception) -> Unit
) {
    private var wakeLock: PowerManager.WakeLock? = null

    fun isHeld(): Boolean = wakeLock?.isHeld == true

    fun acquire() {
        if (wakeLock?.isHeld == true) {
            logInfo("wakelock_acquire_skip already_held")
            return
        }
        try {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            wakeLock = powerManager?.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "${context.packageName}:native_playback"
            )?.apply {
                setReferenceCounted(false)
                acquire()
            }
            logInfo("wakelock_acquired held=${wakeLock?.isHeld == true}")
        } catch (e: Exception) {
            logWarn("wakelock_acquire_failed", e)
            wakeLock = null
        }
    }

    fun release() {
        val currentWakeLock = wakeLock ?: run {
            logInfo("wakelock_release_skip none")
            return
        }
        try {
            if (currentWakeLock.isHeld) {
                currentWakeLock.release()
                logInfo("wakelock_released")
            } else {
                logInfo("wakelock_release_skip not_held")
            }
        } catch (e: RuntimeException) {
            logWarn("wakelock_release_failed", e)
        } finally {
            wakeLock = null
        }
    }
}
