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
    fun `screen-off heartbeat backs off and publishes at five second cadence`() {
        val host = FakeHeartbeatHost()
        val environment = FakeHeartbeatEnvironment(screenInteractive = false)
        val coordinator = coordinator(host, environment)

        coordinator.start()
        coordinator.ensure()
        environment.runImmediate(nowMs = 1_000L)
        environment.runDelayed(delayMs = 5_000L, nowMs = 5_000L)

        assertEquals(listOf(5_000L), host.publishedAt)
        assertEquals(listOf(5_000L), environment.delays())
    }

    @Test
    fun `screen on event pulls a parked heartbeat forward`() {
        val host = FakeHeartbeatHost()
        val environment = FakeHeartbeatEnvironment(screenInteractive = false)
        val coordinator = coordinator(host, environment)
        coordinator.start()
        coordinator.ensure()
        environment.runImmediate(nowMs = 0L)

        environment.screenInteractive = true
        environment.dispatchScreenOn()

        assertTrue(environment.hasImmediateTask())
        assertTrue(environment.delays().isEmpty())
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
    fun `keep alive heartbeat refreshes playback but defers recovery during focus loss`() {
        val host = FakeHeartbeatHost()
        val environment = FakeHeartbeatEnvironment(screenInteractive = false)
        val keepAlive = FakeKeepAliveHeartbeatHost(focusInterrupted = true)
        val coordinator = coordinator(host, environment, keepAlive)
        coordinator.start()
        coordinator.ensure()

        coordinator.onKeepAliveHeartbeat()

        assertEquals(1, keepAlive.wakeLockRefreshes)
        assertTrue(keepAlive.recoveryReasons.isEmpty())
        assertEquals(1, keepAlive.foregroundSyncs)
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
        screenOffIntervalMs = 5_000L,
        keepAliveHost = keepAliveHost
    )
}

private class FakeKeepAliveHeartbeatHost(
    override var hasPlaybackToKeepAlive: Boolean = true,
    override var foregroundStarted: Boolean = true,
    override var focusInterrupted: Boolean = false
) : NativePlaybackKeepAliveHeartbeatHost {
    var wakeLockRefreshes = 0
    val recoveryReasons = mutableListOf<String>()
    var foregroundSyncs = 0
    var alarmEnsures = 0
    override fun refreshWakeLock() { wakeLockRefreshes += 1 }
    override fun triggerRecovery(reason: String) { recoveryReasons += reason }
    override fun expireGraceIfOverdue(): Boolean = false
    override fun syncForeground() { foregroundSyncs += 1 }
    override fun cancelAlarm() = Unit
    override fun ensureAlarm() { alarmEnsures += 1 }
    override fun logHeartbeat() = Unit
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
    var screenInteractive: Boolean
) : NativePlaybackProgressHeartbeatEnvironment {
    val tasks = linkedMapOf<Runnable, Long>()
    var nowMs = 0L
    var screenOn: (() -> Unit)? = null
    var unregisterCount = 0
    override fun post(runnable: Runnable) { tasks[runnable] = 0L }
    override fun postDelayed(runnable: Runnable, delayMs: Long) { tasks[runnable] = delayMs }
    override fun remove(runnable: Runnable) { tasks.remove(runnable) }
    override fun elapsedRealtimeMs(): Long = nowMs
    override fun isScreenInteractive(): Boolean = screenInteractive
    override fun registerScreenOn(listener: () -> Unit) { screenOn = listener }
    override fun unregisterScreenOn() { if (screenOn != null) unregisterCount += 1; screenOn = null }
    fun delays(): List<Long> = tasks.values.filter { it > 0L }
    fun hasImmediateTask(): Boolean = tasks.values.any { it == 0L }
    fun runImmediate(nowMs: Long) = runTask(0L, nowMs)
    fun runDelayed(delayMs: Long, nowMs: Long) = runTask(delayMs, nowMs)
    fun dispatchScreenOn() { screenOn?.invoke() }
    private fun runTask(delayMs: Long, nowMs: Long) {
        this.nowMs = nowMs
        val task = tasks.entries.first { it.value == delayMs }.key
        tasks.remove(task)
        task.run()
    }
}
