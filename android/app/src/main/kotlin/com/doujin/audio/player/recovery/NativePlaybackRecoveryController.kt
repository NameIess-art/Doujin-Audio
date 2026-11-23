@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.doujin.audio.player.recovery

import com.doujin.audio.player.common.isNativePlaybackNetworkUri
import com.doujin.audio.player.service.*
import com.doujin.audio.player.session.*

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.SystemClock
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer

internal interface NativePlaybackRecoveryHost {
    val interruptionActive: Boolean get() = false
    fun session(sessionId: String): NativePlaybackSession?
    fun healthSample(
        sessionId: String,
        nowElapsedRealtimeMs: Long
    ): NativePlaybackHealthSample? = session(sessionId)?.let { session ->
        captureNativePlaybackHealthSample(session, nowElapsedRealtimeMs)
    }
    fun requestAudioFocus(): Boolean
    fun establishForegroundPlayback(sessionId: String): Boolean
    fun ensurePlayer(session: NativePlaybackSession): ExoPlayer
    fun onBeforeReleasePlayer(session: NativePlaybackSession) {}
    fun prepareRecoveryQueue(
        sessionId: String,
        queue: List<NativeMediaItemDescriptor>,
        isCurrent: () -> Boolean,
        complete: (Result<NativePlaybackQueue>) -> Unit
    )
    fun onRecoveryTimedOut(sessionId: String)
    fun publishSession(sessionId: String)
    fun persistNow()
    fun schedulePersist()
    fun syncForeground()
    fun onNetworkRecoveryTriggered() {}
    fun logInfo(message: String, session: NativePlaybackSession? = null)
    fun logWarn(message: String, session: NativePlaybackSession?)
}

internal interface NativePlaybackRecoveryEnvironment {
    fun elapsedRealtimeMs(): Long
    fun postDelayed(runnable: Runnable, delayMs: Long)
    fun remove(runnable: Runnable)
    fun startListening(onTrigger: (String) -> Unit)
    fun stopListening()
}

internal data class NativePlaybackHealthSample(
    val sessionId: String,
    val positionMs: Long,
    val bufferedPositionMs: Long,
    val durationMs: Long?,
    val mediaItemIndex: Int,
    val playbackState: Int,
    val playWhenReady: Boolean,
    val isPlaying: Boolean,
    val playbackSuppressionReason: Int,
    val hasPlayerError: Boolean,
    val capturedElapsedRealtimeMs: Long
)

internal data class NativePlaybackHealthState(
    val sample: NativePlaybackHealthSample,
    val lastActivityElapsedRealtimeMs: Long
)

internal enum class NativePlaybackStallReason(val logValue: String) {
    READY_NOT_PLAYING("ready_not_playing"),
    BUFFERING("buffering"),
    POSITION_FROZEN("position_frozen"),
    IDLE("idle")
}

internal data class NativePlaybackHealthEvaluation(
    val state: NativePlaybackHealthState,
    val stallReason: NativePlaybackStallReason?,
    val positionAdvanced: Boolean,
    val bufferAdvanced: Boolean
)

internal fun evaluateNativePlaybackHealth(
    previous: NativePlaybackHealthState?,
    current: NativePlaybackHealthSample,
    readyStallThresholdMs: Long = 30_000L,
    bufferingStallThresholdMs: Long = 45_000L,
    frozenPositionThresholdMs: Long = 30_000L,
    progressToleranceMs: Long = 250L,
    endToleranceMs: Long = 1_500L
): NativePlaybackHealthEvaluation {
    val nowMs = current.capturedElapsedRealtimeMs
    val previousSample = previous?.sample
    val mediaItemChanged = previousSample != null &&
        previousSample.mediaItemIndex != current.mediaItemIndex
    val positionAdvanced = previousSample != null &&
        current.positionMs - previousSample.positionMs >= progressToleranceMs
    // A backwards jump on the same media item means the player looped (repeat-one)
    // or was seeked - either way it is demonstrably alive. Without this, a short
    // looping track whose length is close to the sampling interval reads as a
    // frozen position and gets needlessly re-prepared mid-playback.
    val positionRewound = previousSample != null &&
        previousSample.positionMs - current.positionMs >= progressToleranceMs
    val bufferAdvanced = previousSample != null &&
        current.bufferedPositionMs - previousSample.bufferedPositionMs >= progressToleranceMs
    val nearEnd = current.durationMs?.let { durationMs ->
        durationMs > 0L && durationMs - current.positionMs <= endToleranceMs
    } ?: false
    val eligible = (current.playWhenReady || current.playbackState == Player.STATE_IDLE) &&
        !current.hasPlayerError &&
        current.playbackState != Player.STATE_ENDED &&
        current.playbackSuppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_NONE &&
        !nearEnd
    val activityAdvanced = positionAdvanced ||
        positionRewound ||
        (current.playbackState == Player.STATE_BUFFERING && bufferAdvanced)
    val stateChanged = previousSample?.playbackState != current.playbackState
    val resetBaseline = previous == null || stateChanged || mediaItemChanged || !eligible ||
        activityAdvanced
    val lastActivityMs = if (resetBaseline) {
        nowMs
    } else {
        previous.lastActivityElapsedRealtimeMs
    }
    val stalledForMs = (nowMs - lastActivityMs).coerceAtLeast(0L)
    val stallReason = when {
        !eligible || resetBaseline -> null
        current.isPlaying && stalledForMs >= frozenPositionThresholdMs ->
            NativePlaybackStallReason.POSITION_FROZEN
        current.playbackState == Player.STATE_BUFFERING &&
            stalledForMs >= bufferingStallThresholdMs ->
            NativePlaybackStallReason.BUFFERING
        current.playbackState == Player.STATE_READY &&
            !current.isPlaying &&
            stalledForMs >= readyStallThresholdMs ->
            NativePlaybackStallReason.READY_NOT_PLAYING
        current.playbackState == Player.STATE_IDLE &&
            stalledForMs >= readyStallThresholdMs ->
            NativePlaybackStallReason.IDLE
        else -> null
    }
    return NativePlaybackHealthEvaluation(
        state = NativePlaybackHealthState(
            sample = current,
            lastActivityElapsedRealtimeMs = lastActivityMs
        ),
        stallReason = stallReason,
        positionAdvanced = positionAdvanced,
        bufferAdvanced = bufferAdvanced
    )
}

internal class AndroidNativePlaybackRecoveryEnvironment(
    private val context: Context,
    private val handler: Handler,
    private val logWarn: (String, Exception) -> Unit
) : NativePlaybackRecoveryEnvironment {
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun elapsedRealtimeMs(): Long = SystemClock.elapsedRealtime()

    override fun postDelayed(runnable: Runnable, delayMs: Long) {
        handler.postDelayed(runnable, delayMs)
    }

    override fun remove(runnable: Runnable) {
        handler.removeCallbacks(runnable)
    }

    override fun startListening(onTrigger: (String) -> Unit) {
        if (networkCallback != null) return
        val manager = connectivityManager() ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            private var currentDefault = manager.activeNetwork
            private var validated = currentDefault?.let(manager::getNetworkCapabilities)
                ?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)

            override fun onAvailable(network: Network) = dispatch {
                if (currentDefault == network) return@dispatch
                currentDefault = network
                validated = null
                onTrigger("network_available")
            }

            override fun onLost(network: Network) = dispatch {
                if (currentDefault != network) return@dispatch
                currentDefault = null
                validated = null
            }

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) =
                dispatch {
                    if (currentDefault != network) return@dispatch
                    val available = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                    val regainedInternet = validated == false && available
                    validated = available
                    if (regainedInternet) onTrigger("network_available")
                }

            private fun dispatch(action: () -> Unit) {
                handler.post {
                    if (networkCallback === this) action()
                }
            }
        }
        try {
            manager.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        } catch (error: Exception) {
            logWarn("network_recovery_callback_register_failed", error)
        }
    }

    override fun stopListening() {
        val callback = networkCallback ?: return
        networkCallback = null
        try {
            connectivityManager()?.unregisterNetworkCallback(callback)
        } catch (error: Exception) {
            logWarn("network_recovery_callback_unregister_failed", error)
        }
    }

    private fun connectivityManager(): ConnectivityManager? =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
}

internal fun captureNativePlaybackHealthSample(
    session: NativePlaybackSession,
    nowElapsedRealtimeMs: Long
): NativePlaybackHealthSample? {
    val player = session.playerOrNull() ?: return null
    return NativePlaybackHealthSample(
        sessionId = session.sessionId,
        positionMs = player.currentPosition.coerceAtLeast(0L),
        bufferedPositionMs = player.bufferedPosition.coerceAtLeast(0L),
        durationMs = player.duration.takeUnless { it == C.TIME_UNSET || it < 0L },
        mediaItemIndex = player.currentMediaItemIndex,
        playbackState = player.playbackState,
        playWhenReady = player.playWhenReady,
        isPlaying = player.isPlaying,
        playbackSuppressionReason = player.playbackSuppressionReason,
        hasPlayerError = player.playerError != null,
        capturedElapsedRealtimeMs = nowElapsedRealtimeMs
    )
}

internal class NativePlaybackRecoveryController(
    private val host: NativePlaybackRecoveryHost,
    private val environment: NativePlaybackRecoveryEnvironment,
    private val healthCheckIntervalMs: Long = 15_000L,
    private val readyStallThresholdMs: Long = 30_000L,
    private val bufferingStallThresholdMs: Long = 45_000L,
    private val frozenPositionThresholdMs: Long = 30_000L,
    private val maxRecoveryDurationMs: Long = 10 * 60 * 1000L,
    private val screenOffHealthCheckIntervalMs: Long = 60_000L,
    private val isScreenInteractive: () -> Boolean = { true }
) {
    private class Recovery {
        var startedAtMs: Long? = null
        var attempt = 0
        var baseline: NativePlaybackHealthSample? = null
        var task: Runnable? = null
        var inFlight: Attempt? = null
        var candidateFallback = false
        var rebuildPlayer = false
    }

    private class Attempt(private val session: NativePlaybackSession) {
        private val queueRevision = session.queueRevision
        private val definitionRevision = session.definitionRevision
        private val transportCommandId = session.transportCommandId
        private val queueIndex = session.queueIndex
        private val path = session.path
        private val uri = session.uri

        fun matches(current: NativePlaybackSession?): Boolean =
            current === session && session.queueRevision == queueRevision &&
                session.definitionRevision == definitionRevision &&
                session.transportCommandId == transportCommandId &&
                session.queueIndex == queueIndex && session.path == path && session.uri == uri
    }

    private val intended = linkedSetOf<String>()
    private val recoveries = mutableMapOf<String, Recovery>()
    private val healthStates = mutableMapOf<String, NativePlaybackHealthState>()
    private var triggering = false
    private var listening = false
    private var healthCheckScheduled = false
    private val healthCheckTask = object : Runnable {
        override fun run() {
            healthCheckScheduled = false
            trigger("scheduled_health_check")
            ensureHealthCheck()
        }
    }

    val intendedSessionIds: Set<String> get() = intended.toSet()

    fun isIntended(sessionId: String): Boolean = sessionId in intended

    fun isPending(sessionId: String): Boolean = sessionId in recoveries

    fun isRecovering(sessionId: String): Boolean = recoveries[sessionId]?.inFlight != null

    fun markIntended(sessionId: String) {
        intended += sessionId
        resetHealth(sessionId, "playback_intended", cancelRecovery = true)
        if (!listening) {
            listening = true
            environment.startListening(::trigger)
        }
        ensureHealthCheck()
    }

    fun clear(sessionId: String) {
        intended -= sessionId
        healthStates.remove(sessionId)
        clearRecovery(sessionId)
        if (intended.isEmpty()) stopMonitoring()
    }

    fun clearAll() {
        intended.clear()
        recoveries.values.forEach(::cancelTask)
        recoveries.clear()
        healthStates.clear()
        stopMonitoring()
    }

    fun resetHealth(sessionId: String, reason: String, cancelRecovery: Boolean = false) {
        healthStates.remove(sessionId)
        val recovery = recoveries[sessionId] ?: return
        if (cancelRecovery) {
            host.logInfo("playback_recovery_cancelled sessionId=$sessionId reason=$reason")
            clearRecovery(sessionId)
        } else {
            recovery.baseline = captureHealth(sessionId)
        }
    }

    fun onMediaItemTransition(sessionId: String, reason: Int) {
        resetHealth(sessionId, "media_item_transition")
        val recovery = recoveries[sessionId] ?: return
        if (reason != Player.MEDIA_ITEM_TRANSITION_REASON_AUTO &&
            reason != Player.MEDIA_ITEM_TRANSITION_REASON_REPEAT
        ) return
        val sample = recovery.baseline ?: return
        if (sample.playWhenReady && !sample.hasPlayerError) {
            confirmRecovery(sessionId, "natural_media_item_transition")
        }
    }

    fun onPlayerError(
        sessionId: String,
        recoverable: Boolean,
        candidateFallbackEligible: Boolean = false,
        rebuildPlayer: Boolean = false,
        errorCodeName: String
    ) {
        val session = host.session(sessionId)
        val attempt = recoveries[sessionId]?.attempt ?: 0
        host.logWarn(
            "player_error code=$errorCodeName retryAttempt=$attempt " +
                "recoverable=$recoverable intended=${sessionId in intended}",
            session
        )
        if (!recoverable || sessionId !in intended) {
            clear(sessionId)
        } else {
            val recovery = recoveries.getOrPut(sessionId, ::Recovery)
            recovery.candidateFallback = recovery.candidateFallback ||
                (candidateFallbackEligible && session?.hasAlternatePlaybackUri() == true)
            recovery.rebuildPlayer = recovery.rebuildPlayer || rebuildPlayer
            recovery.baseline = captureHealth(sessionId)
            if (recovery.inFlight == null) {
                val tryAlternateNow = recovery.candidateFallback && recovery.attempt == 0
                scheduleRetry(sessionId, recovery, immediate = tryAlternateNow)
            }
        }
        host.publishSession(sessionId)
        host.persistNow()
        host.syncForeground()
    }

    fun trigger(reason: String) {
        if (host.interruptionActive) {
            healthStates.clear()
            return
        }
        if (triggering) return
        triggering = true
        try {
            val networkChanged = reason == "network_available"
            val sessionIds = if (networkChanged) {
                intended.filter { isNativePlaybackNetworkUri(host.session(it)?.uri) }
            } else {
                intended.toList()
            }
            if (networkChanged && sessionIds.isNotEmpty()) host.onNetworkRecoveryTriggered()
            sessionIds.forEach { sessionId ->
                if (sessionId in intended) checkPlaybackHealth(sessionId, reason, networkChanged)
            }
        } finally {
            triggering = false
        }
    }

    fun retryNow(sessionId: String, reason: String) {
        if (sessionId !in intended) return
        val recovery = recoveries.getOrPut(sessionId) {
            Recovery().apply {
                val session = host.session(sessionId) ?: return@apply
                val error = session.playerOrNull()?.playerError ?: return@apply
                rebuildPlayer = isPlayerRebuildRequiredForErrorCode(error.errorCode)
                candidateFallback = isCandidateFallbackPlaybackErrorCode(error.errorCode) &&
                    session.hasAlternatePlaybackUri()
            }
        }
        retry(sessionId, recovery, reason)
    }

    fun shouldKeepAlive(): Boolean = intended.any { sessionId ->
        val session = host.session(sessionId) ?: return@any false
        val player = session.playerOrNull() ?: return@any true
        shouldKeepAliveForIntendedPlayback(
            playbackState = player.playbackState,
            hasPlayerError = player.playerError != null,
            hasRecoverablePlaybackError = sessionId in recoveries
        )
    }

    private fun scheduleRetry(
        sessionId: String,
        recovery: Recovery,
        immediate: Boolean = false,
        waitingForBuffer: Boolean = false
    ) {
        if (recoveries[sessionId] !== recovery) return
        val delayMs = if (host.interruptionActive) {
            // Phone calls and ducking interruptions do not count against recovery.
            recovery.startedAtMs = null
            healthCheckIntervalMs
        } else {
            val nowMs = environment.elapsedRealtimeMs()
            val startedAt = recovery.startedAtMs ?: nowMs.also { recovery.startedAtMs = it }
            val remainingMs = maxRecoveryDurationMs - (nowMs - startedAt)
            if (remainingMs <= 0L) {
                timeOut(sessionId)
                return
            }
            val retryDelay = when {
                immediate -> 0L
                waitingForBuffer -> healthCheckIntervalMs
                else -> playbackRecoveryDelayMs(recovery.attempt, startedAt, nowMs)
            }
            if (!waitingForBuffer) recovery.attempt++
            retryDelay.coerceAtMost(remainingMs)
        }
        host.logInfo(
            "playback_retry_scheduled sessionId=$sessionId delayMs=$delayMs " +
                "attempt=${recovery.attempt} interrupted=${host.interruptionActive}"
        )
        scheduleTask(sessionId, recovery, delayMs) {
            retry(sessionId, recovery, "scheduled_retry", waitForPlayback = true)
        }
    }

    private fun scheduleTask(sessionId: String, recovery: Recovery, delayMs: Long, action: () -> Unit) {
        cancelTask(recovery)
        lateinit var task: Runnable
        task = Runnable {
            if (recoveries[sessionId] !== recovery || recovery.task !== task) return@Runnable
            recovery.task = null
            action()
        }
        recovery.task = task
        environment.postDelayed(task, delayMs)
    }

    private fun cancelTask(recovery: Recovery) {
        recovery.task?.let(environment::remove)
        recovery.task = null
    }

    private fun retry(
        sessionId: String,
        recovery: Recovery,
        reason: String,
        waitForPlayback: Boolean = false
    ) {
        if (recoveries[sessionId] !== recovery || recovery.inFlight != null) return
        val session = host.session(sessionId) ?: return clear(sessionId)
        if (host.interruptionActive) {
            scheduleRetry(sessionId, recovery)
            return
        }
        val currentHealth = captureHealth(sessionId)
        if (hasRecoveredProgress(recovery.baseline, currentHealth)) {
            confirmRecovery(sessionId, reason)
            return
        }
        val nowMs = environment.elapsedRealtimeMs()
        val startedAt = recovery.startedAtMs ?: nowMs.also { recovery.startedAtMs = it }
        val remainingMs = maxRecoveryDurationMs - (nowMs - startedAt)
        if (remainingMs <= 0L) {
            timeOut(sessionId)
            return
        }
        if (waitForPlayback && currentHealth != null && !currentHealth.hasPlayerError &&
            currentHealth.playWhenReady &&
            currentHealth.playbackState == Player.STATE_BUFFERING
        ) {
            val evaluation = evaluateHealth(sessionId, currentHealth)
            if (evaluation.stallReason == null) {
                // A retry at each backoff interval could reset an active load.
                scheduleRetry(sessionId, recovery, waitingForBuffer = true)
                return
            }
        }

        // Foreground and focus changes can dispatch playback callbacks on the
        // main Looper before returning, so reserve the slot before either call.
        cancelTask(recovery)
        val attempt = Attempt(session)
        recovery.inFlight = attempt
        fun ownsAttempt() = recoveries[sessionId] === recovery && recovery.inFlight === attempt
        fun isCurrent() = ownsAttempt() && attempt.matches(host.session(sessionId))

        host.logInfo(
            "playback_retry sessionId=$sessionId trigger=$reason attempt=${recovery.attempt} " +
                "positionMs=${currentHealth?.positionMs}"
        )
        val canStart = host.establishForegroundPlayback(sessionId) && isCurrent() &&
            host.requestAudioFocus()
        if (!isCurrent()) {
            if (ownsAttempt()) clearRecovery(sessionId)
            return
        }
        if (host.interruptionActive) {
            recovery.inFlight = null
            scheduleRetry(sessionId, recovery)
            return
        }
        if (!canStart) {
            clear(sessionId)
            session.playerOrNull()?.pause()
            host.publishSession(sessionId)
            host.persistNow()
            host.syncForeground()
            return
        }

        fun completeRecovery(prepared: Result<NativePlaybackQueue>?) {
            if (!isCurrent()) {
                if (ownsAttempt()) clearRecovery(sessionId)
                return
            }
            cancelTask(recovery)
            if (host.interruptionActive) {
                recovery.inFlight = null
                scheduleRetry(sessionId, recovery)
                return
            }
            if (environment.elapsedRealtimeMs() - startedAt >= maxRecoveryDurationMs) {
                timeOut(sessionId)
                return
            }
            try {
                val preparedQueue = prepared?.getOrThrow()
                val rebuildPlayer = recovery.rebuildPlayer || recovery.attempt >= 2
                recovery.rebuildPlayer = false
                recovery.candidateFallback = false
                session.applyFadeMultiplier(1f)
                session.reprepareCurrentMediaItem(
                    preparedQueue = preparedQueue,
                    rebuildPlayer = rebuildPlayer,
                    beforeReleasePlayer = { host.onBeforeReleasePlayer(session) }
                )
                if (!ownsAttempt()) return
                if (preparedQueue != null) host.logInfo("playback_candidate_advanced sessionId=$sessionId", session)
                host.ensurePlayer(session).play()
                if (!ownsAttempt()) return
                recovery.baseline = captureHealth(sessionId) ?: currentHealth
                host.publishSession(sessionId)
                host.schedulePersist()
            } catch (error: Exception) {
                host.logWarn(
                    "playback_recovery_failed sessionId=$sessionId trigger=$reason " +
                        "exception=${error.javaClass.simpleName}",
                    session
                )
            } finally {
                if (ownsAttempt()) {
                    recovery.inFlight = null
                    scheduleRetry(sessionId, recovery)
                    host.syncForeground()
                }
            }
        }
        val candidateQueue = if (recovery.candidateFallback) session.nextPlaybackCandidateQueue() else null
        if (candidateQueue == null) {
            completeRecovery(null)
        } else {
            scheduleTask(sessionId, recovery, remainingMs) {
                if (!isCurrent()) {
                    if (ownsAttempt()) clearRecovery(sessionId)
                } else if (host.interruptionActive) {
                    recovery.inFlight = null
                    scheduleRetry(sessionId, recovery)
                } else {
                    timeOut(sessionId)
                }
            }
            try {
                host.prepareRecoveryQueue(sessionId, candidateQueue, ::isCurrent, ::completeRecovery)
            } catch (error: Exception) {
                completeRecovery(Result.failure(error))
            }
        }
    }

    private fun checkPlaybackHealth(sessionId: String, trigger: String, networkChanged: Boolean) {
        val sample = captureHealth(sessionId)
        if (sample?.playbackState == Player.STATE_ENDED) {
            clear(sessionId)
            return
        }
        val recovery = recoveries[sessionId]
        if (recovery != null && hasRecoveredProgress(recovery.baseline, sample)) {
            confirmRecovery(sessionId, trigger)
            return
        }
        val evaluation = sample?.let { evaluateHealth(sessionId, it) }
        if (recovery != null) {
            if (recovery.inFlight?.matches(host.session(sessionId)) == false) {
                clearRecovery(sessionId)
                return
            }
            // Handler timers use uptime. A power callback can run before an
            // overdue timer after suspend, so enforce the elapsed-time limit.
            val startedAt = recovery.startedAtMs
            if (startedAt != null &&
                environment.elapsedRealtimeMs() - startedAt >= maxRecoveryDurationMs
            ) {
                timeOut(sessionId)
                return
            }
            // Failed loads can retry early on the new route. Media3 can
            // continue a healthy or still-buffering stream on its own.
            if (networkChanged && (sample == null || sample.hasPlayerError ||
                    sample.playbackState == Player.STATE_IDLE)
            ) {
                retry(sessionId, recovery, trigger)
            }
            return
        }
        if (sample == null) {
            if (host.session(sessionId)?.uri != null) retryNow(sessionId, trigger)
            return
        }
        if (sample.playbackState == Player.STATE_READY && !sample.playWhenReady &&
            !sample.hasPlayerError &&
            sample.playbackSuppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_NONE
        ) {
            resumeUnexpectedPause(sessionId)
        } else if (evaluation?.stallReason != null) {
            val stalled = Recovery().apply {
                baseline = sample
                rebuildPlayer = evaluation.stallReason != NativePlaybackStallReason.BUFFERING
            }
            recoveries[sessionId] = stalled
            host.logInfo(
                "playback_stalled sessionId=$sessionId trigger=$trigger reason=${evaluation.stallReason.logValue} " +
                    "positionMs=${sample.positionMs} bufferedMs=${sample.bufferedPositionMs}"
            )
            scheduleRetry(sessionId, stalled)
            host.publishSession(sessionId)
            host.persistNow()
            host.syncForeground()
        }
    }

    private fun evaluateHealth(
        sessionId: String,
        sample: NativePlaybackHealthSample
    ): NativePlaybackHealthEvaluation = evaluateNativePlaybackHealth(
        previous = healthStates[sessionId],
        current = sample,
        readyStallThresholdMs = readyStallThresholdMs,
        bufferingStallThresholdMs = bufferingStallThresholdMs,
        frozenPositionThresholdMs = frozenPositionThresholdMs
    ).also { healthStates[sessionId] = it.state }

    private fun resumeUnexpectedPause(sessionId: String) {
        val session = host.session(sessionId) ?: return
        val player = session.playerOrNull() ?: return
        if (!host.establishForegroundPlayback(sessionId) || !host.requestAudioFocus()) return
        if (host.interruptionActive || sessionId !in intended || sessionId in recoveries ||
            host.session(sessionId) !== session || session.playerOrNull() !== player
        ) return
        host.logInfo("playback_resuming_unexpected_pause sessionId=$sessionId", session)
        player.play()
    }

    private fun captureHealth(sessionId: String): NativePlaybackHealthSample? =
        host.healthSample(sessionId, environment.elapsedRealtimeMs())

    private fun hasRecoveredProgress(
        baseline: NativePlaybackHealthSample?,
        current: NativePlaybackHealthSample?
    ): Boolean {
        if (baseline == null || current == null || current.hasPlayerError ||
            !current.playWhenReady || !current.isPlaying
        ) return false
        return current.mediaItemIndex != baseline.mediaItemIndex ||
            kotlin.math.abs(current.positionMs - baseline.positionMs) >= 250L
    }

    private fun confirmRecovery(sessionId: String, trigger: String) {
        host.logInfo("playback_recovered sessionId=$sessionId trigger=$trigger")
        clearRecovery(sessionId)
    }

    private fun clearRecovery(sessionId: String) {
        recoveries.remove(sessionId)?.let(::cancelTask)
    }

    private fun timeOut(sessionId: String) {
        host.logInfo("playback_recovery_timed_out sessionId=$sessionId durationMs=$maxRecoveryDurationMs")
        clear(sessionId)
        host.onRecoveryTimedOut(sessionId)
    }

    fun onScreenInteractiveChanged() {
        if (!healthCheckScheduled || intended.isEmpty()) return
        environment.remove(healthCheckTask)
        healthCheckScheduled = false
        ensureHealthCheck()
    }

    private fun currentHealthCheckIntervalMs(): Long {
        if (isScreenInteractive() || recoveries.isNotEmpty()) return healthCheckIntervalMs
        val anyBuffering = intended.any { sessionId ->
            host.session(sessionId)?.playerOrNull()?.playbackState == Player.STATE_BUFFERING
        }
        return if (anyBuffering) healthCheckIntervalMs else screenOffHealthCheckIntervalMs
    }

    private fun ensureHealthCheck() {
        if (healthCheckScheduled || intended.isEmpty()) return
        healthCheckScheduled = true
        environment.postDelayed(healthCheckTask, currentHealthCheckIntervalMs())
    }

    private fun stopMonitoring() {
        environment.remove(healthCheckTask)
        healthCheckScheduled = false
        if (listening) {
            listening = false
            environment.stopListening()
        }
    }
}
