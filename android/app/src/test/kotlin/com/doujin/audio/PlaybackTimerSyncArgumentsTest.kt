package com.doujin.audio

import com.doujin.audio.channel.parsePlaybackTimerSyncArguments
import io.flutter.plugin.common.MethodCall
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PlaybackTimerSyncArgumentsTest {
    @Test
    fun `timer sync parser accepts required nullable keys`() {
        val parsed = parsePlaybackTimerSyncArguments(
            MethodCall("syncPlaybackTimerAlarms", validTimerArguments())
        )

        assertNull(parsed.timerModeIndex)
        assertNull(parsed.durationMs)
        assertEquals(23, parsed.autoResumeHour)
        assertEquals(listOf("session-1"), parsed.pausedSessionIds)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `timer sync parser rejects missing nullable key`() {
        parsePlaybackTimerSyncArguments(
            MethodCall(
                "syncPlaybackTimerAlarms",
                validTimerArguments().toMutableMap().apply { remove("autoResumeAtMs") }
            )
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `timer sync parser rejects invalid clock values before scheduling`() {
        parsePlaybackTimerSyncArguments(
            MethodCall(
                "syncPlaybackTimerAlarms",
                validTimerArguments().toMutableMap().apply { put("autoResumeHour", 24) }
            )
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `timer sync parser rejects malformed session ids`() {
        parsePlaybackTimerSyncArguments(
            MethodCall(
                "syncPlaybackTimerAlarms",
                validTimerArguments().toMutableMap().apply {
                    put("pausedSessionIds", listOf("session-1", 2))
                }
            )
        )
    }
}

private fun validTimerArguments(): Map<String, Any?> = mapOf(
    "timerMode" to null,
    "timerDurationMs" to null,
    "timerWaitingForPlayback" to false,
    "timerEndsAtWallClockMs" to null,
    "autoResumeEnabled" to true,
    "autoResumeHour" to 23,
    "autoResumeMinute" to 59,
    "autoResumeAtMs" to null,
    "pausedSessionIds" to listOf("session-1"),
    "generation" to 7
)
