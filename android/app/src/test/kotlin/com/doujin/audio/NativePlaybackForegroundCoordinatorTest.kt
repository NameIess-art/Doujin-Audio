package com.doujin.audio

import com.doujin.audio.player.service.*

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlaybackForegroundCoordinatorTest {
    @Test
    fun `two phase preparation lease expires and replacement invalidates its old timeout`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost(hasPlaybackToKeepAlive = false)
        val coordinator = coordinator(host, environment)
        coordinator.holdPlaybackStart("A")
        val staleExpiry = environment.tasks.keys.single()
        coordinator.holdPlaybackStart("A")
        staleExpiry.run()
        assertTrue(coordinator.hasPendingPlaybackStarts)
        environment.runFirst(5_000L)
        assertFalse(coordinator.hasPendingPlaybackStarts)
        assertEquals(listOf(0L), environment.delays())
    }

    @Test
    fun `pause cancels only the target preparation lease and shutdown cancels all leases`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost(hasPlaybackToKeepAlive = false)
        val coordinator = coordinator(host, environment)
        coordinator.holdPlaybackStart("A")
        coordinator.holdPlaybackStart("B")
        coordinator.settlePlaybackStart("A")
        assertTrue(coordinator.hasPendingPlaybackStarts)
        assertEquals(listOf(5_000L), environment.delays())
        coordinator.shutdown()
        assertFalse(coordinator.hasPendingPlaybackStarts)
        assertTrue(environment.tasks.isEmpty())
    }
    @Test
    fun `start skips unchanged signature and force refresh starts again`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost()
        val coordinator = coordinator(host, environment)

        assertTrue(coordinator.startOrUpdate().playbackAllowed)
        assertTrue(coordinator.startOrUpdate().playbackAllowed)
        assertTrue(coordinator.startOrUpdate(forceRefresh = true).playbackAllowed)

        assertEquals(2, host.playbackStarts)
        assertTrue(coordinator.isStarted)
        assertEquals(2, host.infoMessages.size)
        assertTrue(host.infoMessages.all { it.startsWith("start_foreground_success") })
    }

    @Test
    fun `failed foreground start is reported and active resources are not acquired`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost(failPlaybackStart = true)
        val coordinator = coordinator(host, environment)

        val result = coordinator.startOrUpdate()
        coordinator.sync()

        assertEquals(NativePlaybackForegroundStartResult.FAILED, result)
        assertFalse(result.playbackAllowed)
        assertFalse(coordinator.isStarted)
        assertEquals(0, host.activeSyncs)
        assertFalse(environment.delays().contains(4_000L))
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
    fun `idle stop is scheduled once and cancelled when playback resumes`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost(hasPlaybackToKeepAlive = false)
        val coordinator = coordinator(host, environment)

        coordinator.sync()
        coordinator.sync()

        assertEquals(listOf(0L), environment.delays())

        host.hasPlaybackToKeepAlive = true
        coordinator.sync()

        assertTrue(environment.delays().contains(4_000L))
        assertFalse(environment.delays().contains(0L))
        assertEquals(1, host.activeSyncs)
    }

    @Test
    fun `idle playback requests one deferred teardown`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost(hasPlaybackToKeepAlive = false)
        val coordinator = coordinator(host, environment)
        coordinator.startBootstrap()
        coordinator.sync()

        environment.runFirst(0L)

        assertEquals(1, host.idleStopRequests)
        assertTrue(environment.tasks.isEmpty())
    }

    @Test
    fun `active sync keeps one minimal notification until playback stops`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost()
        val coordinator = coordinator(host, environment)

        repeat(3) { coordinator.sync() }
        coordinator.repairNotificationIfMissing()

        assertEquals(1, host.playbackStarts)
        assertTrue(coordinator.isStarted)
        assertEquals(0, host.foregroundStops)
    }

    @Test
    fun `watchdog keeps one schedule and does not rebuild a healthy notification`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost()
        val coordinator = coordinator(host, environment)
        coordinator.startOrUpdate()

        coordinator.sync()
        coordinator.sync()
        environment.runFirst(4_000L)

        // Still posted and signature unchanged: no re-post. A blind forceRefresh
        // here costs ~180 notification rebuilds over a 12h session.
        assertEquals(1, host.playbackStarts)
        assertEquals(listOf(4_000L), environment.delays())
    }

    @Test
    fun `watchdog rebuilds when the foreground notification went missing`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost(notificationPosted = false)
        val coordinator = coordinator(host, environment)
        coordinator.startOrUpdate()

        coordinator.sync()
        environment.runFirst(4_000L)

        assertEquals(2, host.playbackStarts)
    }

    @Test
    fun `watchdog does not rebuild when the platform notification query failed`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost(notificationPosted = null)
        val coordinator = coordinator(host, environment)
        coordinator.startOrUpdate()

        coordinator.sync()
        environment.runFirst(4_000L)

        assertEquals(1, host.playbackStarts)
    }

    @Test
    fun `watchdog stops when playback becomes idle`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost()
        val coordinator = coordinator(host, environment)
        coordinator.startOrUpdate()
        coordinator.sync()

        host.hasPlaybackToKeepAlive = false
        environment.runFirst(4_000L)

        assertTrue(environment.tasks.isEmpty())
    }

    @Test
    fun `stop removes the minimal notification and shutdown cancels tasks`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost()
        val coordinator = coordinator(host, environment)
        coordinator.startOrUpdate()
        coordinator.sync()
        host.hasPlaybackToKeepAlive = false
        coordinator.sync()

        coordinator.stop(reason = "test")
        assertTrue(environment.tasks.isEmpty())
        coordinator.shutdown()

        assertEquals(2, host.foregroundStops)
        assertTrue(environment.tasks.isEmpty())
        assertFalse(coordinator.isStarted)
    }

    @Test
    fun `idle stop defers by grace period while UI listens and tightens immediately on detach`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost(hasPlaybackToKeepAlive = false, hasActiveUiListeners = true)
        val coordinator = NativePlaybackForegroundCoordinator(
            host = host,
            environment = environment,
            watchdogIntervalMs = 4_000L,
            idleGracePeriodMs = 15_000L
        )

        coordinator.sync()
        assertEquals(listOf(15_000L), environment.delays())
        assertEquals(0, host.idleStopRequests)

        // UI detaches while waiting in grace period -> reschedule immediately to 0ms.
        host.hasActiveUiListeners = false
        coordinator.sync()
        assertEquals(listOf(0L), environment.delays())

        environment.runFirst(0L)
        assertEquals(1, host.idleStopRequests)
    }

    @Test
    fun `pausing while UI listens removes foreground notification on next tick while keeping idle grace`() {
        val environment = FakeForegroundEnvironment()
        val host = FakeForegroundHost(hasPlaybackToKeepAlive = true, hasActiveUiListeners = true)
        val coordinator = NativePlaybackForegroundCoordinator(
            host = host,
            environment = environment,
            watchdogIntervalMs = 4_000L,
            idleGracePeriodMs = 15_000L
        )
        coordinator.sync()
        assertTrue(coordinator.isStarted)
        assertEquals(1, host.playbackStarts)

        // Transient idle during a synchronous track switch cancels demotion without flicker.
        host.hasPlaybackToKeepAlive = false
        coordinator.sync()
        assertTrue(coordinator.isStarted)
        assertEquals(0, host.foregroundStops)
        host.hasPlaybackToKeepAlive = true
        coordinator.sync()
        assertTrue(coordinator.isStarted)
        assertEquals(0, host.foregroundStops)
        assertEquals(listOf(4_000L), environment.delays())

        // Real pause demotes foreground on the next looper turn (0ms) while deferring idleStop by 15s.
        host.hasPlaybackToKeepAlive = false
        coordinator.sync()
        assertTrue(environment.delays().contains(0L))
        assertTrue(environment.delays().contains(15_000L))
        environment.runFirst(0L)

        assertFalse(coordinator.isStarted)
        assertEquals(1, host.foregroundStops)
        assertEquals(listOf(15_000L), environment.delays())
        assertEquals(0, host.idleStopRequests)

        // Resuming within the grace window cancels idle stop and reposts the notification.
        host.hasPlaybackToKeepAlive = true
        coordinator.sync()
        assertTrue(coordinator.isStarted)
        assertEquals(2, host.playbackStarts)
        assertEquals(listOf(4_000L), environment.delays())
    }

    private fun coordinator(
        host: FakeForegroundHost,
        environment: FakeForegroundEnvironment
    ) = NativePlaybackForegroundCoordinator(
        host = host,
        environment = environment,
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
    override var playbackSuspended: Boolean = false,
    override var hasActiveUiListeners: Boolean = false,
    var signature: String? = "playback",
    var notificationPosted: Boolean? = true,
    var failPlaybackStart: Boolean = false
) : NativePlaybackForegroundHost {
    var activeSyncs = 0
    var idleStopRequests = 0
    var playbackStarts = 0
    var bootstrapStarts = 0
    var foregroundStops = 0
    val infoMessages = mutableListOf<String>()

    override fun playbackSignature(): String? = signature

    override fun onActiveSync() {
        activeSyncs += 1
    }

    override fun isForegroundNotificationPosted(): Boolean? = notificationPosted

    override fun onIdleStop() {
        idleStopRequests += 1
    }

    override fun startPlaybackForeground() {
        playbackStarts += 1
        if (failPlaybackStart) error("foreground start failed")
    }

    override fun startBootstrapForeground() {
        bootstrapStarts += 1
    }

    override fun stopForeground(wasStarted: Boolean) {
        foregroundStops += 1
    }

    override fun logInfo(message: String) { infoMessages += message }

    override fun logWarn(message: String, error: Throwable) = Unit
}
