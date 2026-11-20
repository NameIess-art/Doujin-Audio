package com.doujin.audio

import com.doujin.audio.player.service.NativePlaybackProgressHeartbeatCoordinator
import com.doujin.audio.player.service.NativePlaybackProgressHeartbeatEnvironment
import com.doujin.audio.player.service.NativePlaybackProgressHeartbeatHost
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
        val coordinator = coordinator(host, environment)

        coordinator.start()
        coordinator.ensure()

        assertFalse(coordinator.isScheduled)
        assertTrue(environment.tasks.isEmpty())
        assertTrue(host.publishedAt.isEmpty())

        environment.screenInteractive = true
        environment.dispatchScreenOn()

        assertTrue(coordinator.isScheduled)
        assertTrue(environment.hasImmediateTask())
        assertEquals(listOf(true), host.screenInteractiveEvents)
    }

    @Test
    fun `screen off event parks an active heartbeat and forwards screen state`() {
        val host = FakeHeartbeatHost()
        val environment = FakeHeartbeatEnvironment(screenInteractive = true)
        val coordinator = coordinator(host, environment)
        coordinator.start()
        coordinator.ensure()
        environment.runImmediate(nowMs = 0L)

        environment.screenInteractive = false
        environment.dispatchScreenOff()

        assertFalse(coordinator.isScheduled)
        assertTrue(environment.tasks.isEmpty())
        assertEquals(listOf(false), host.screenInteractiveEvents)

        environment.screenInteractive = true
        environment.dispatchScreenOn()

        assertTrue(coordinator.isScheduled)
        assertTrue(environment.hasImmediateTask())
        assertEquals(listOf(false, true), host.screenInteractiveEvents)
    }

    @Test
    fun `device idle mode changes are forwarded with the progress ticker parked`() {
        val host = FakeHeartbeatHost()
        val environment = FakeHeartbeatEnvironment(screenInteractive = false)
        val coordinator = coordinator(host, environment)
        coordinator.start()

        environment.deviceIdle = true
        environment.dispatchDeviceIdle(true)
        environment.deviceIdle = false
        environment.dispatchDeviceIdle(false)

        assertEquals(listOf(true, false), host.deviceIdleEvents)
        assertTrue(environment.tasks.isEmpty())
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

    private fun coordinator(
        host: FakeHeartbeatHost,
        environment: FakeHeartbeatEnvironment
    ) = NativePlaybackProgressHeartbeatCoordinator(
        host = host,
        environment = environment,
        screenOnIntervalMs = 500L
    )
}

private class FakeHeartbeatHost : NativePlaybackProgressHeartbeatHost {
    var hasListeners = true
    var hasSessions = true
    val publishedAt = mutableListOf<Long>()
    val screenInteractiveEvents = mutableListOf<Boolean>()
    val deviceIdleEvents = mutableListOf<Boolean>()
    override fun onScreenInteractiveChanged(interactive: Boolean) {
        screenInteractiveEvents += interactive
    }
    override fun onDeviceIdleModeChanged(deviceIdle: Boolean) {
        deviceIdleEvents += deviceIdle
    }
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
