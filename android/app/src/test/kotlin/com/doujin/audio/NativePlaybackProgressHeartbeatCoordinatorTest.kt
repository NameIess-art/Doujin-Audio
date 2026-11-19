package com.doujin.audio

import com.doujin.audio.player.service.NativePlaybackProgressHeartbeatCoordinator
import com.doujin.audio.player.service.NativePlaybackProgressHeartbeatEnvironment
import com.doujin.audio.player.service.NativePlaybackProgressHeartbeatHost
import com.doujin.audio.player.service.NativePlaybackKeepAliveHeartbeatHost
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackProgressHeartbeatCoordinatorTest {
    @Test
    fun `screen-on heartbeat publishes and schedules the fast cadence`() {
        val host = FakeHeartbeatHost()
        val environment = FakeHeartbeatEnvironment(screenInteractive = true)
        val coordinator = coordinator(host, environment)

        coordinator.start()
        coordinator.ensure()
        environment.runImmediate(nowMs = 100L)

        assertEquals(listOf(100L), host.publishedAt)
        assertEquals(listOf(500L), environment.delays())
        assertTrue(coordinator.isScheduled)
    }

    @Test
    fun `screen-off parks progress heartbeat completely with zero wakeups`() {
        val host = FakeHeartbeatHost()
        val environment = FakeHeartbeatEnvironment(screenInteractive = false)
        val keepAlive = FakeKeepAliveHeartbeatHost()
        val coordinator = coordinator(host, environment, keepAlive)

        coordinator.start()
        coordinator.ensure()

        assertFalse(coordinator.isScheduled)
        assertTrue(environment.tasks.isEmpty())
        assertTrue(host.publishedAt.isEmpty())

        environment.screenInteractive = true
        environment.dispatchScreenOn()

        assertTrue(coordinator.isScheduled)
        assertTrue(environment.hasImmediateTask())
        assertEquals(listOf(true), keepAlive.screenInteractiveEvents)
    }

    @Test
    fun `screen off event parks an active heartbeat and notifies keep alive host`() {
        val host = FakeHeartbeatHost()
        val environment = FakeHeartbeatEnvironment(screenInteractive = true)
        val keepAlive = FakeKeepAliveHeartbeatHost()
        val coordinator = coordinator(host, environment, keepAlive)
        coordinator.start()
        coordinator.ensure()
        environment.runImmediate(nowMs = 0L)

        environment.screenInteractive = false
        environment.dispatchScreenOff()

        assertFalse(coordinator.isScheduled)
        assertTrue(environment.tasks.isEmpty())
        assertEquals(listOf(false), keepAlive.screenInteractiveEvents)

        environment.screenInteractive = true
        environment.dispatchScreenOn()

        assertTrue(coordinator.isScheduled)
        assertTrue(environment.hasImmediateTask())
        assertEquals(listOf(false, true), keepAlive.screenInteractiveEvents)
    }

    @Test
    fun `device idle mode changes are forwarded to keep alive host`() {
        val host = FakeHeartbeatHost()
        val environment = FakeHeartbeatEnvironment(screenInteractive = false)
        val keepAlive = FakeKeepAliveHeartbeatHost()
        val coordinator = coordinator(host, environment, keepAlive)
        coordinator.start()

        environment.deviceIdle = true
        environment.dispatchDeviceIdle(true)
        environment.deviceIdle = false
        environment.dispatchDeviceIdle(false)

        assertEquals(listOf(true, false), keepAlive.deviceIdleEvents)
    }

    @Test
    fun `empty listeners stop the ticker and shutdown is idempotent`() {
        val host = FakeHeartbeatHost()
        val environment = FakeHeartbeatEnvironment(screenInteractive = true)
        val coordinator = coordinator(host, environment)
        coordinator.start()
        coordinator.ensure()
        host.hasListeners = false

        environment.runImmediate(nowMs = 100L)
        coordinator.shutdown()
        coordinator.shutdown()

        assertFalse(coordinator.isScheduled)
        assertTrue(environment.tasks.isEmpty())
        assertEquals(1, environment.unregisterCount)
    }

    @Test
    fun `keep alive heartbeat forces wake lock refresh and defers recovery during focus loss`() {
        val host = FakeHeartbeatHost()
        val environment = FakeHeartbeatEnvironment(screenInteractive = false)
        val keepAlive = FakeKeepAliveHeartbeatHost(focusInterrupted = true)
        val coordinator = coordinator(host, environment, keepAlive)
        coordinator.start()
        coordinator.ensure()

        coordinator.onKeepAliveHeartbeat()

        assertEquals(listOf(true), keepAlive.wakeLockRefreshForceFlags)
        assertTrue(keepAlive.recoveryReasons.isEmpty())
        assertEquals(1, keepAlive.foregroundSyncs)
        assertEquals(1, keepAlive.alarmEnsures)
        // Screen is off so Flutter progress ticker stays parked.
        assertFalse(coordinator.isScheduled)
    }

    @Test
    fun `keep alive heartbeat rearms alarm when recovery throws`() {
        val host = FakeHeartbeatHost()
        val environment = FakeHeartbeatEnvironment(screenInteractive = false)
        val keepAlive = FakeKeepAliveHeartbeatHost(throwOnRecovery = true)
        val coordinator = coordinator(host, environment, keepAlive)

        runCatching { coordinator.onKeepAliveHeartbeat() }

        assertEquals(1, keepAlive.alarmEnsures)
    }

    private fun coordinator(
        host: FakeHeartbeatHost,
        environment: FakeHeartbeatEnvironment,
        keepAliveHost: NativePlaybackKeepAliveHeartbeatHost? = null
    ) = NativePlaybackProgressHeartbeatCoordinator(
        host = host,
        environment = environment,
        screenOnIntervalMs = 500L,
        keepAliveHost = keepAliveHost
    )
}

private class FakeKeepAliveHeartbeatHost(
    override var hasPlaybackToKeepAlive: Boolean = true,
    override var foregroundStarted: Boolean = true,
    override var focusInterrupted: Boolean = false,
    private val throwOnRecovery: Boolean = false
) : NativePlaybackKeepAliveHeartbeatHost {
    val wakeLockRefreshForceFlags = mutableListOf<Boolean>()
    val recoveryReasons = mutableListOf<String>()
    val screenInteractiveEvents = mutableListOf<Boolean>()
    val deviceIdleEvents = mutableListOf<Boolean>()
    var foregroundSyncs = 0
    var alarmEnsures = 0
    override fun refreshWakeLock(force: Boolean) { wakeLockRefreshForceFlags += force }
    override fun triggerRecovery(reason: String) {
        recoveryReasons += reason
        if (throwOnRecovery) error("recovery failed")
    }
    override fun expireGraceIfOverdue(): Boolean = false
    override fun syncForeground() { foregroundSyncs += 1 }
    override fun cancelAlarm() = Unit
    override fun ensureAlarm() { alarmEnsures += 1 }
    override fun logHeartbeat() = Unit
    override fun onScreenInteractiveChanged(interactive: Boolean) {
        screenInteractiveEvents += interactive
    }
    override fun onDeviceIdleModeChanged(deviceIdle: Boolean) {
        deviceIdleEvents += deviceIdle
    }
}

private class FakeHeartbeatHost : NativePlaybackProgressHeartbeatHost {
    var hasListeners = true
    var hasSessions = true
    val publishedAt = mutableListOf<Long>()
    override fun shouldRunProgressHeartbeat(): Boolean = hasListeners && hasSessions
    override fun publishProgress(nowElapsedRealtimeMs: Long) {
        publishedAt += nowElapsedRealtimeMs
    }
}

private class FakeHeartbeatEnvironment(
    var screenInteractive: Boolean,
    var deviceIdle: Boolean = false
) : NativePlaybackProgressHeartbeatEnvironment {
    val tasks = linkedMapOf<Runnable, Long>()
    var nowMs = 0L
    var screenOn: (() -> Unit)? = null
    var screenOff: (() -> Unit)? = null
    var deviceIdleChanged: ((Boolean) -> Unit)? = null
    var unregisterCount = 0
    override fun post(runnable: Runnable) { tasks[runnable] = 0L }
    override fun postDelayed(runnable: Runnable, delayMs: Long) { tasks[runnable] = delayMs }
    override fun remove(runnable: Runnable) { tasks.remove(runnable) }
    override fun elapsedRealtimeMs(): Long = nowMs
    override fun isScreenInteractive(): Boolean = screenInteractive
    override fun isDeviceIdleMode(): Boolean = deviceIdle
    override fun registerPowerEvents(
        onScreenOn: () -> Unit,
        onScreenOff: () -> Unit,
        onDeviceIdleChanged: (Boolean) -> Unit
    ) {
        screenOn = onScreenOn
        screenOff = onScreenOff
        deviceIdleChanged = onDeviceIdleChanged
    }
    override fun unregisterPowerEvents() {
        if (screenOn != null) unregisterCount += 1
        screenOn = null
        screenOff = null
        deviceIdleChanged = null
    }
    fun delays(): List<Long> = tasks.values.filter { it > 0L }
    fun hasImmediateTask(): Boolean = tasks.values.any { it == 0L }
    fun runImmediate(nowMs: Long) = runTask(0L, nowMs)
    fun dispatchScreenOn() { screenOn?.invoke() }
    fun dispatchScreenOff() { screenOff?.invoke() }
    fun dispatchDeviceIdle(idle: Boolean) { deviceIdleChanged?.invoke(idle) }
    private fun runTask(delayMs: Long, nowMs: Long) {
        this.nowMs = nowMs
        val task = tasks.entries.first { it.value == delayMs }.key
        tasks.remove(task)
        task.run()
    }
}
