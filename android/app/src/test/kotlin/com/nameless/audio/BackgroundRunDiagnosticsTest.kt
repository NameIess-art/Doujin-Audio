package com.nameless.audio

import android.app.ApplicationExitInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundRunDiagnosticsTest {
    @Test
    fun `detects vivo cleaner force stops`() {
        assertTrue(
            isCleanerForceStop(
                reason = ApplicationExitInfo.REASON_USER_REQUESTED,
                description = "stop com.nameless.audio due to single-cleaner"
            )
        )
    }

    @Test
    fun `does not report unrelated exits as cleaner force stops`() {
        assertFalse(
            isCleanerForceStop(
                reason = ApplicationExitInfo.REASON_LOW_MEMORY,
                description = "low memory"
            )
        )
        assertFalse(
            isCleanerForceStop(
                reason = ApplicationExitInfo.REASON_USER_REQUESTED,
                description = "removed from recents"
            )
        )
    }

    @Test
    fun `vivo settings prefer high background usage before auto start`() {
        assertEquals(
            listOf(
                "com.iqoo.powersaving.battery.high.power.jump" to "com.iqoo.powersaving",
                "com.iqoo.secure.BGSTARTUPMANAGER" to "com.vivo.permissionmanager"
            ),
            vivoBackgroundSettingsTargets("vivo")
        )
        assertTrue(vivoBackgroundSettingsTargets("VIVO").isNotEmpty())
        assertTrue(vivoBackgroundSettingsTargets("google").isEmpty())
    }

    @Test
    fun `exit reason names distinguish force stop and low memory`() {
        assertEquals(
            "user_requested",
            applicationExitReasonName(ApplicationExitInfo.REASON_USER_REQUESTED)
        )
        assertEquals(
            "low_memory",
            applicationExitReasonName(ApplicationExitInfo.REASON_LOW_MEMORY)
        )
        assertEquals("unknown", applicationExitReasonName(null))
    }
}
