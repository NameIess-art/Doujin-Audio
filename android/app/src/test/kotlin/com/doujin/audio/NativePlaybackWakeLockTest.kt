package com.doujin.audio

import com.doujin.audio.player.common.NativePlaybackWakeLock
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class NativePlaybackWakeLockTest {
    @Test
    fun `acquire and refresh deduplicate within minRefreshIntervalMs unless forced`() {
        var nowMs = 1_000L
        val logs = mutableListOf<String>()
        val wakeLock = NativePlaybackWakeLock(
            context = RuntimeEnvironment.getApplication(),
            logInfo = logs::add,
            logWarn = { msg, err -> throw AssertionError("$msg: $err") },
            wakeLockTimeoutMs = 60 * 60 * 1000L,
            minRefreshIntervalMs = 5 * 60 * 1000L,
            elapsedRealtimeMs = { nowMs }
        )

        wakeLock.acquire()
        assertTrue(wakeLock.isHeld())
        assertEquals(listOf("wakelock_acquired"), logs)

        // Within 5 minutes, non-forced refreshes do not re-acquire or spam logs.
        nowMs += 60_000L
        wakeLock.refresh(logRefresh = true, force = false)
        assertEquals(listOf("wakelock_acquired"), logs)

        // Forced refresh (e.g. keep-alive alarm / Doze event) always renews.
        wakeLock.refresh(logRefresh = true, force = true)
        assertEquals(listOf("wakelock_acquired", "wakelock_refreshed"), logs)

        // After 5 minutes have elapsed, normal refresh renews again.
        nowMs += 5 * 60 * 1000L
        wakeLock.refresh(logRefresh = true, force = false)
        assertEquals(listOf("wakelock_acquired", "wakelock_refreshed", "wakelock_refreshed"), logs)

        wakeLock.release()
        assertFalse(wakeLock.isHeld())
        assertTrue(logs.last() == "wakelock_released")
    }

    @Test
    fun `wifi lock tracks network playback state while wake lock is held`() {
        val wakeLock = NativePlaybackWakeLock(
            context = RuntimeEnvironment.getApplication(),
            logInfo = {},
            logWarn = { msg, err -> throw AssertionError("$msg: $err") }
        )

        wakeLock.setNetworkPlaybackActive(true)
        assertFalse(wakeLock.isWifiLockHeld())

        wakeLock.acquire()
        assertTrue(wakeLock.isHeld())
        assertTrue(wakeLock.isWifiLockHeld())

        wakeLock.setNetworkPlaybackActive(false)
        assertFalse(wakeLock.isWifiLockHeld())

        wakeLock.setNetworkPlaybackActive(true)
        assertTrue(wakeLock.isWifiLockHeld())

        wakeLock.release()
        assertFalse(wakeLock.isHeld())
        assertFalse(wakeLock.isWifiLockHeld())
    }
}
