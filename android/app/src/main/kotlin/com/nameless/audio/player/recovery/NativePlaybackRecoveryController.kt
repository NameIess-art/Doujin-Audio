package com.nameless.audio.player.recovery

import com.nameless.audio.player.service.*
import com.nameless.audio.player.session.*

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.SystemClock
import androidx.core.content.ContextCompat
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer

internal interface NativePlaybackRecoveryHost {
    fun session(sessionId: String): NativePlaybackSession?
    fun healthSample(
        sessionId: String,
        nowElapsedRealtimeMs: Long
    ): NativePlaybackHealthSample? = session(sessionId)?.let { session ->
        captureNativePlaybackHealthSample(session, nowElapsedRealtimeMs)
    }
    fun requestAudioFocus(): Boolean
    fun focusSession(sessionId: String)
    fun ensurePlayer(session: NativePlaybackSession): ExoPlayer
    fun publishSession(sessionId: String)
    fun publishAllSessions()
    fun persistNow()
    fun schedulePersist()
    fun syncForeground()
    fun logInfo(message: String, session: NativePlaybackSession? = null)
    fun logWarn(message: String, session: NativePlaybackSession?, error: PlaybackException?)
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
    val bufferAdvanced = previousSample != null &&
        current.bufferedPositionMs - previousSample.bufferedPositionMs >= progressToleranceMs
    val nearEnd = current.durationMs?.let { durationMs ->
        durationMs > 0L && durationMs - current.positionMs <= endToleranceMs
    } ?: false
    val eligible = current.playWhenReady &&
        !current.hasPlayerError &&
        current.playbackState != Player.STATE_ENDED &&
        current.playbackSuppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_NONE &&
        !nearEnd
    val activityAdvanced = positionAdvanced ||
        (current.playbackState == Player.STATE_BUFFERING && bufferAdvanced)
    val resetBaseline = previous == null || mediaItemChanged || !eligible || activityAdvanced
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
    private var trigger: ((String) -> Unit)? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var networkAvailable = false
    private var screenReceiverRegistered = false
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_ON) {
                handler.post { trigger?.invoke("screen_on") }
            }
        }
    }

    override fun elapsedRealtimeMs(): Long = SystemClock.elapsedRealtime()

    override fun postDelayed(runnable: Runnable, delayMs: Long) {
        handler.postDelayed(runnable, delayMs)
    }

    override fun remove(runnable: Runnable) {
        handler.removeCallbacks(runnable)
    }

    override fun startListening(onTrigger: (String) -> Unit) {
        trigger = onTrigger
        registerScreenReceiver()
        registerNetworkCallback()
    }

    override fun stopListening() {
        networkCallback?.let { callback ->
            try {
                connectivityManager()?.unregisterNetworkCallback(callback)
            } catch (error: Exception) {
                logWarn("network_recovery_callback_unregister_failed", error)
            }
        }
        networkCallback = null
        networkAvailable = false
        if (screenReceiverRegistered) {
            try {
                context.unregisterReceiver(screenReceiver)
            } catch (error: Exception) {
                logWarn("screen_on_recovery_receiver_unregister_failed", error)
            }
            screenReceiverRegistered = false
        }
        trigger = null
    }

    private fun registerScreenReceiver() {
        if (screenReceiverRegistered) return
        try {
            ContextCompat.registerReceiver(
                context,
                screenReceiver,
                IntentFilter(Intent.ACTION_SCREEN_ON),
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
            screenReceiverRegistered = true
        } catch (error: Exception) {
            logWarn("screen_on_recovery_receiver_register_failed", error)
        }
    }

    private fun registerNetworkCallback() {
        if (networkCallback != null) return
        val manager = connectivityManager() ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = availabilityChanged(manager)
            override fun onLost(network: Network) = availabilityChanged(manager)
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) =
                availabilityChanged(manager)
        }
        try {
            networkAvailable = isValidatedNetworkAvailable(manager)
            manager.registerNetworkCallback(
                NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .build(),
                callback
            )
            networkCallback = callback
        } catch (error: Exception) {
            logWarn("network_recovery_callback_register_failed", error)
        }
    }

    private fun availabilityChanged(manager: ConnectivityManager) {
        handler.post {
            val available = isValidatedNetworkAvailable(manager)
            val becameAvailable = !networkAvailable && available
            networkAvailable = available
            if (becameAvailable) trigger?.invoke("network_available")
        }
    }

    private fun connectivityManager(): ConnectivityManager? =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

    private fun isValidatedNetworkAvailable(manager: ConnectivityManager): Boolean {
        val capabilities = manager.getNetworkCapabilities(manager.activeNetwork) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }
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
    private val recoveryWindowMs: Long,
    private val healthCheckIntervalMs: Long = 15_000L,
    private val readyStallThresholdMs: Long = 30_000L,
    private val bufferingStallThresholdMs: Long = 45_000L,
    private val frozenPositionThresholdMs: Long = 30_000L
) {
    private val intended = linkedSetOf<String>()
    private val pending = linkedSetOf<String>()
    private val attempts = mutableMapOf<String, Int>()
    private val retryTasks = mutableMapOf<String, Runnable>()
    private val expiryTasks = mutableMapOf<String, Runnable>()
    private val healthStates = mutableMapOf<String, NativePlaybackHealthState>()
    private val recoveryBaselines = mutableMapOf<String, NativePlaybackHealthSample>()
    private val recovering = linkedSetOf<String>()
    private val candidateFallbackPending = linkedSetOf<String>()
    private val stopAfterRecoveryWindow = linkedSetOf<String>()
    private var triggerInProgress = false
    private val startedAt = mutableMapOf<String, Long>()
    private var listening = false
    private var healthCheckScheduled = false
    private val healthCheckTask = object : Runnable {
        override fun run() {
            healthCheckScheduled = false
            checkPlaybackHealth("scheduled_health_check")
            ensureHealthCheck()
        }
    }

    val intendedSessionIds: Set<String> get() = intended.toSet()

    fun isIntended(sessionId: String): Boolean = sessionId in intended

    fun isPending(sessionId: String): Boolean = sessionId in pending

    fun markIntended(sessionId: String) {
        intended += sessionId
        resetHealth(sessionId, "playback_intended", cancelRecovery = true)
        ensureHealthCheck()
    }

    fun clear(sessionId: String) {
        intended -= sessionId
        healthStates -= sessionId
        recoveryBaselines -= sessionId
        recovering -= sessionId
        clearRecovery(sessionId)
        if (intended.isEmpty()) stopHealthCheck()
    }

    fun clearAll() {
        intended.clear()
        pending.toList().forEach(::clearRecovery)
        healthStates.clear()
        recoveryBaselines.clear()
        recovering.clear()
        candidateFallbackPending.clear()
        stopAfterRecoveryWindow.clear()
        stopHealthCheck()
        stopListening()
    }

    fun onPlaying(sessionId: String) {
        if (sessionId in intended) ensureHealthCheck()
    }

    fun resetHealth(
        sessionId: String,
        reason: String,
        cancelRecovery: Boolean = false
    ) {
        healthStates -= sessionId
        if (cancelRecovery && sessionId in pending) {
            recoveryBaselines -= sessionId
            host.logInfo("playback_health_reset sessionId=$sessionId reason=$reason")
            clearRecovery(sessionId)
        } else if (sessionId in pending) {
            captureHealth(sessionId)?.let { recoveryBaselines[sessionId] = it }
        } else {
            recoveryBaselines -= sessionId
        }
    }

    fun onPlayerError(
        sessionId: String,
        recoverable: Boolean,
        candidateFallbackEligible: Boolean = false,
        stopAfterRecoveryWindow: Boolean = false,
        errorCodeName: String,
        errorMessage: String?,
        causeDescription: String?,
        technicalError: PlaybackException? = null
    ) {
        val attempt = attempts.getOrDefault(sessionId, 0)
        val session = host.session(sessionId)
        host.logWarn(
            "player_error code=$errorCodeName message=$errorMessage " +
                "cause=$causeDescription " +
                "retryAttempt=$attempt recoverable=$recoverable intended=${sessionId in intended}",
            session,
            technicalError
        )
        host.publishSession(sessionId)
        host.persistNow()
        if (!recoverable || sessionId !in intended) {
            clear(sessionId)
            host.syncForeground()
            return
        }
        pending += sessionId
        if (candidateFallbackEligible && session?.hasAlternatePlaybackUri() == true) {
            candidateFallbackPending += sessionId
        }
        if (stopAfterRecoveryWindow) {
            this.stopAfterRecoveryWindow += sessionId
        } else {
            this.stopAfterRecoveryWindow -= sessionId
        }
        captureHealth(sessionId)?.let { recoveryBaselines[sessionId] = it }
        startListening()
        scheduleExpiry(sessionId)
        scheduleRetry(
            sessionId,
            attempt,
            immediate = sessionId in candidateFallbackPending
        )
        ensureHealthCheck()
        host.syncForeground()
    }

    fun trigger(reason: String) {
        if (triggerInProgress) {
            host.logInfo("playback_recovery_trigger_skipped_reentrant trigger=$reason")
            return
        }
        triggerInProgress = true
        try {
            checkPlaybackHealth(reason)
            if (pending.isNotEmpty()) {
                host.logInfo("playback_recovery_trigger trigger=$reason pending=${pending.size}")
                pending.toList().forEach { retry(it, reason) }
            }
            recoverIntendedPlayback(reason)
        } finally {
            triggerInProgress = false
        }
    }

    fun shouldKeepAlive(): Boolean = intended.any { sessionId ->
        val session = host.session(sessionId) ?: return@any false
        val player = session.playerOrNull() ?: return@any true
        shouldKeepAliveForIntendedPlayback(
            playbackState = player.playbackState,
            hasPlayerError = player.playerError != null,
            hasRecoverablePlaybackError = sessionId in pending
        )
    } || pending.any { host.session(it) != null }

    fun dispose() = clearAll()

    private fun scheduleRetry(
        sessionId: String,
        attempt: Int,
        immediate: Boolean = false
    ) {
        retryTasks.remove(sessionId)?.let(environment::remove)
        val recoveryStarted = startedAt.getOrPut(sessionId, environment::elapsedRealtimeMs)
        val delayMs = if (immediate) {
            0L
        } else {
            playbackRecoveryDelayMs(attempt, recoveryStarted, environment.elapsedRealtimeMs())
        }
        attempts[sessionId] = attempt + 1
        val task = Runnable {
            retryTasks.remove(sessionId)
            retry(sessionId, "scheduled_retry")
        }
        retryTasks[sessionId] = task
        host.logInfo("player_error_retry_scheduled sessionId=$sessionId delay=${delayMs}ms attempt=${attempt + 1}")
        environment.postDelayed(task, delayMs)
    }

    private fun retry(sessionId: String, reason: String) {
        val session = host.session(sessionId) ?: return clear(sessionId)
        if (sessionId !in intended) return clearRecovery(sessionId)
        if (sessionId in recovering) {
            host.logInfo("playback_recovery_skip_in_flight sessionId=$sessionId trigger=$reason")
            return
        }
        val currentHealth = captureHealth(sessionId)
        val recoveryBaseline = recoveryBaselines[sessionId]
        if (hasRecoveredProgress(recoveryBaseline, currentHealth)) {
            host.logInfo(
                "playback_recovery_progress_confirmed sessionId=$sessionId " +
                    "trigger=$reason position=${currentHealth?.positionMs}"
            )
            clearRecovery(sessionId)
            return
        }
        retryTasks.remove(sessionId)?.let(environment::remove)
        val attempt = attempts.getOrDefault(sessionId, 0)
        host.logInfo(
            "playback_recovery_executing sessionId=$sessionId trigger=$reason " +
                "attempt=$attempt position=${currentHealth?.positionMs} " +
                "buffered=${currentHealth?.bufferedPositionMs} " +
                "state=${currentHealth?.playbackState?.let(::playbackStateName)} " +
                "suppression=${currentHealth?.playbackSuppressionReason}"
        )
        if (!host.requestAudioFocus()) {
            clear(sessionId)
            session.playerOrNull()?.pause()
            host.publishSession(sessionId)
            host.syncForeground()
            return
        }
        recovering += sessionId
        try {
            host.focusSession(sessionId)
            session.applyFadeMultiplier(1f)
            if (candidateFallbackPending.remove(sessionId) && session.advanceToNextPlaybackUri()) {
                host.logInfo(
                    "playback_candidate_advanced sessionId=$sessionId uri=${session.uri}",
                    session
                )
            }
            session.reprepareCurrentMediaItem()
            host.ensurePlayer(session).play()
            (captureHealth(sessionId) ?: currentHealth)?.let {
                recoveryBaselines[sessionId] = it
            }
            host.publishSession(sessionId)
            host.schedulePersist()
            host.syncForeground()
            scheduleRetry(sessionId, attempts.getOrDefault(sessionId, 0))
        } catch (error: Exception) {
            host.logWarn(
                "playback_recovery_failed sessionId=$sessionId trigger=$reason",
                session,
                error as? PlaybackException
            )
            scheduleRetry(sessionId, attempts.getOrDefault(sessionId, 0))
            host.syncForeground()
        } finally {
            recovering -= sessionId
        }
    }

    private fun scheduleExpiry(sessionId: String) {
        if (sessionId in expiryTasks) return
        val recoveryStarted = startedAt.getOrPut(sessionId, environment::elapsedRealtimeMs)
        val delayMs = (recoveryStarted + recoveryWindowMs - environment.elapsedRealtimeMs()).coerceAtLeast(0L)
        val task = Runnable {
            expiryTasks.remove(sessionId)
            if (sessionId !in pending) return@Runnable
            if (sessionId in stopAfterRecoveryWindow) {
                val session = host.session(sessionId)
                clear(sessionId)
                session?.playerOrNull()?.pause()
                host.publishSession(sessionId)
                host.persistNow()
                host.syncForeground()
                return@Runnable
            }
            host.logInfo(
                "playback_recovery_low_frequency sessionId=$sessionId " +
                    "attempts=${attempts.getOrDefault(sessionId, 0)}"
            )
            host.publishSession(sessionId)
            host.persistNow()
            host.syncForeground()
        }
        expiryTasks[sessionId] = task
        environment.postDelayed(task, delayMs)
    }

    private fun clearRecovery(sessionId: String) {
        pending -= sessionId
        attempts -= sessionId
        startedAt -= sessionId
        recoveryBaselines -= sessionId
        recovering -= sessionId
        candidateFallbackPending -= sessionId
        stopAfterRecoveryWindow -= sessionId
        retryTasks.remove(sessionId)?.let(environment::remove)
        expiryTasks.remove(sessionId)?.let(environment::remove)
        if (pending.isEmpty()) stopListening()
    }

    private fun recoverIntendedPlayback(reason: String) {
        val sessionIds = intended.toList()
        if (sessionIds.isEmpty()) return
        if (!host.requestAudioFocus()) {
            sessionIds.forEach(::clear)
            host.publishAllSessions()
            return
        }
        var recovered = false
        sessionIds.forEach { sessionId ->
            val session = host.session(sessionId) ?: run {
                clear(sessionId)
                return@forEach
            }
            val player = session.playerOrNull()
            if (player == null) {
                if (session.uri == null) {
                    clear(sessionId)
                    return@forEach
                }
                host.logInfo("recover_intended_playback trigger=$reason recreate_player", session)
                host.focusSession(sessionId)
                session.applyFadeMultiplier(1f)
                host.ensurePlayer(session).play()
                recovered = true
                return@forEach
            }
            if (sessionId in pending) {
                return@forEach
            }
            val monitoredHealth = healthStates[sessionId]
            if (player.playerError == null &&
                player.playWhenReady &&
                monitoredHealth != null
            ) {
                val evaluation = evaluateNativePlaybackHealth(
                    previous = monitoredHealth,
                    current = captureHealth(sessionId) ?: monitoredHealth.sample,
                    readyStallThresholdMs = readyStallThresholdMs,
                    bufferingStallThresholdMs = bufferingStallThresholdMs,
                    frozenPositionThresholdMs = frozenPositionThresholdMs
                )
                healthStates[sessionId] = evaluation.state
                if (evaluation.stallReason == null) return@forEach
                beginStallRecovery(sessionId, evaluation)
                return@forEach
            }
            if (player.playerError == null && player.isPlaying) return@forEach
            if (!shouldRecoverIntendedPlayback(player.playbackState, player.playerError != null, sessionId in pending)) {
                if (player.playbackState == Player.STATE_ENDED) clear(sessionId)
                return@forEach
            }
            host.logInfo(
                "recover_intended_playback trigger=$reason state=${playbackStateName(player.playbackState)}",
                session
            )
            host.focusSession(sessionId)
            session.applyFadeMultiplier(1f)
            if (player.playbackState == Player.STATE_IDLE || player.playerError != null) {
                session.reprepareCurrentMediaItem()
            }
            host.ensurePlayer(session).play()
            recovered = true
        }
        if (recovered) {
            host.publishAllSessions()
            host.schedulePersist()
        }
    }

    private fun checkPlaybackHealth(trigger: String) {
        val nowMs = environment.elapsedRealtimeMs()
        intended.toList().forEach { sessionId ->
            val sample = host.healthSample(sessionId, nowMs) ?: return@forEach
            val evaluation = evaluateNativePlaybackHealth(
                previous = healthStates[sessionId],
                current = sample,
                readyStallThresholdMs = readyStallThresholdMs,
                bufferingStallThresholdMs = bufferingStallThresholdMs,
                frozenPositionThresholdMs = frozenPositionThresholdMs
            )
            healthStates[sessionId] = evaluation.state
            if (evaluation.positionAdvanced &&
                sample.isPlaying &&
                sample.playWhenReady &&
                !sample.hasPlayerError
            ) {
                if (sessionId in pending) {
                    host.logInfo(
                        "playback_health_recovered sessionId=$sessionId trigger=$trigger " +
                            "position=${sample.positionMs}"
                    )
                    clearRecovery(sessionId)
                }
                return@forEach
            }
            if (evaluation.stallReason != null) {
                beginStallRecovery(sessionId, evaluation, trigger)
            }
        }
    }

    private fun beginStallRecovery(
        sessionId: String,
        evaluation: NativePlaybackHealthEvaluation,
        trigger: String = "health_check"
    ) {
        if (sessionId in pending) return
        val sample = evaluation.state.sample
        val stalledForMs = (
            sample.capturedElapsedRealtimeMs - evaluation.state.lastActivityElapsedRealtimeMs
        ).coerceAtLeast(0L)
        host.logInfo(
            "playback_health_stalled sessionId=$sessionId trigger=$trigger " +
                "reason=${evaluation.stallReason?.logValue} stalledFor=${stalledForMs}ms " +
                "position=${sample.positionMs} buffered=${sample.bufferedPositionMs} " +
                "state=${playbackStateName(sample.playbackState)} " +
                "isPlaying=${sample.isPlaying} playWhenReady=${sample.playWhenReady} " +
                "suppression=${sample.playbackSuppressionReason}"
        )
        pending += sessionId
        recoveryBaselines[sessionId] = sample
        startListening()
        scheduleExpiry(sessionId)
        scheduleRetry(sessionId, attempts.getOrDefault(sessionId, 0))
        host.publishSession(sessionId)
        host.persistNow()
        host.syncForeground()
    }

    private fun captureHealth(sessionId: String): NativePlaybackHealthSample? {
        return host.healthSample(sessionId, environment.elapsedRealtimeMs())
    }

    private fun hasRecoveredProgress(
        baseline: NativePlaybackHealthSample?,
        current: NativePlaybackHealthSample?
    ): Boolean {
        if (baseline == null || current == null) return false
        if (current.hasPlayerError || !current.playWhenReady || !current.isPlaying) return false
        return current.mediaItemIndex != baseline.mediaItemIndex ||
            current.positionMs - baseline.positionMs >= 250L
    }

    private fun ensureHealthCheck() {
        if (healthCheckScheduled || intended.isEmpty()) return
        healthCheckScheduled = true
        environment.postDelayed(healthCheckTask, healthCheckIntervalMs)
    }

    private fun stopHealthCheck() {
        if (!healthCheckScheduled) return
        environment.remove(healthCheckTask)
        healthCheckScheduled = false
    }

    private fun startListening() {
        if (listening) return
        listening = true
        environment.startListening(::trigger)
    }

    private fun stopListening() {
        if (!listening) return
        listening = false
        environment.stopListening()
    }
}
