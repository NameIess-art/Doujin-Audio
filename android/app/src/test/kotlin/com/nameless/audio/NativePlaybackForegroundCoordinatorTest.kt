package com.nameless.audio

import com.nameless.audio.player.service.*

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackForegroundCoordinatorTest {
    @Test
    fun `start skips unchanged signature and force refresh starts again`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost()
        val coordinator = coordinator(host, environment)

        coordinator.startOrUpdate()
        coordinator.startOrUpdate()
        coordinator.startOrUpdate(forceRefresh = true)

        assertEquals(2, host.playbackStarts)
        assertTrue(coordinator.isStarted)
    }

    @Test
    fun `suspended and missing requests do not start playback foreground`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost(playbackSuspended = true)
        val coordinator = coordinator(host, environment)

        coordinator.startOrUpdate()
        host.playbackSuspended = false
        host.signature = null
        coordinator.startOrUpdate()

        assertEquals(0, host.playbackStarts)
        assertFalse(coordinator.isStarted)
    }

    @Test
    fun `bootstrap starts once and playback replaces its signature`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost()
        val coordinator = coordinator(host, environment)

        coordinator.startBootstrap()
        coordinator.startBootstrap()
        coordinator.startOrUpdate()

        assertEquals(1, host.bootstrapStarts)
        assertEquals(1, host.playbackStarts)
        assertTrue(coordinator.isStarted)
    }

    @Test
    fun `grace is scheduled once and cancelled when playback resumes`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost(hasPlaybackToKeepAlive = false)
        val coordinator = coordinator(host, environment)

        coordinator.sync()
        coordinator.sync()

        assertEquals(listOf(10_000L), environment.delays())

        host.hasPlaybackToKeepAlive = true
        coordinator.sync()

        assertTrue(environment.delays().contains(4_000L))
        assertFalse(environment.delays().contains(10_000L))
        assertEquals(1, host.activeSyncs)
    }

    @Test
    fun `expired grace stops resources when playback remains idle`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost(
            hasPlaybackToKeepAlive = false,
            hasSessions = false
        )
        val coordinator = coordinator(host, environment)
        coordinator.startBootstrap()
        coordinator.sync()

        environment.runFirst(10_000L)

        assertEquals(1, host.graceExpiries)
        assertEquals(listOf(true), host.stopRequests)
        assertFalse(coordinator.isStarted)
    }

    @Test
    fun `watchdog refreshes active foreground and keeps one schedule`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost()
        val coordinator = coordinator(host, environment)
        coordinator.startOrUpdate()

        coordinator.ensureWatchdog()
        coordinator.ensureWatchdog()
        environment.runFirst(4_000L)

        assertEquals(1, host.watchdogRefreshes)
        assertEquals(2, host.playbackStarts)
        assertEquals(listOf(4_000L), environment.delays())
    }

    @Test
    fun `watchdog stops when playback becomes idle`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost()
        val coordinator = coordinator(host, environment)
        coordinator.startOrUpdate()
        coordinator.ensureWatchdog()

        host.hasPlaybackToKeepAlive = false
        environment.runFirst(4_000L)

        assertTrue(environment.tasks.isEmpty())
    }

    @Test
    fun `task removal preserves active sessions and stops empty service`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost()
        val coordinator = coordinator(host, environment)

        assertFalse(coordinator.onTaskRemoved())
        host.hasPlaybackToKeepAlive = false
        assertFalse(coordinator.onTaskRemoved())
        assertTrue(environment.delays().contains(10_000L))

        host.hasSessions = false
        assertTrue(coordinator.onTaskRemoved())
        assertEquals(listOf(true), host.stopRequests)
    }

    @Test
    fun `stop honours unified notification retention and shutdown cancels tasks`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost(removeForegroundNotification = false)
        val coordinator = coordinator(host, environment)
        coordinator.startOrUpdate()
        coordinator.ensureWatchdog()
        host.hasPlaybackToKeepAlive = false
        coordinator.sync()

        coordinator.stop(reason = "test", removeNotification = true)
        coordinator.shutdown()

        assertEquals(listOf(false), host.stopRequests)
        assertTrue(environment.tasks.isEmpty())
        assertFalse(coordinator.isStarted)
    }

    private fun coordinator(
        host: FakeForegroundHost,
        environment: FakeForegroundEnvironment
    ) = NativePlaybackForegroundCoordinator(
        host = host,
        environment = environment,
        stopGraceMs = 10_000L,
        watchdogIntervalMs = 4_000L
    )
}

private class FakeForegroundEnvironment : NativePlaybackForegroundEnvironment {
    val tasks = linkedMapOf<Runnable, Long>()

    override fun postDelayed(runnable: Runnable, delayMs: Long) {
        tasks[runnable] = delayMs
    }

    override fun remove(runnable: Runnable) {
        tasks.remove(runnable)
    }

    fun delays(): List<Long> = tasks.values.toList()

    fun runFirst(delayMs: Long) {
        val runnable = tasks.entries.first { it.value == delayMs }.key
        tasks.remove(runnable)
        runnable.run()
    }
}

private class FakeForegroundHost(
    override var hasPlaybackToKeepAlive: Boolean = true,
    override var hasSessions: Boolean = true,
    override var playbackSuspended: Boolean = false,
    override var foregroundSuppressed: Boolean = false,
    var signature: String? = "session|playing",
    var removeForegroundNotification: Boolean = true
) : NativePlaybackForegroundHost {
    var activeSyncs = 0
    var graceExpiries = 0
    var watchdogRefreshes = 0
    var playbackStarts = 0
    var bootstrapStarts = 0
    val stopRequests = mutableListOf<Boolean>()

    override fun playbackSignature(): String? = signature

    override fun onActiveSync() {
        activeSyncs += 1
    }

    override fun onSuppressedIdle() = Unit

    override fun onGraceExpired() {
        graceExpiries += 1
    }

    override fun onWatchdog() {
        watchdogRefreshes += 1
    }

    override fun startPlaybackForeground() {
        playbackStarts += 1
    }

    override fun startBootstrapForeground() {
        bootstrapStarts += 1
    }

    override fun shouldRemoveForegroundNotification(removeNotification: Boolean): Boolean =
        removeNotification && removeForegroundNotification

    override fun stopForeground(wasStarted: Boolean, removeNotification: Boolean) {
        stopRequests += removeNotification
    }

    override fun logInfo(message: String) = Unit

    override fun logWarn(message: String, error: Throwable) = Unit
}
