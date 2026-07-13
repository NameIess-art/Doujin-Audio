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
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer

internal interface NativePlaybackRecoveryHost {
    fun session(sessionId: String): NativePlaybackSession?
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

internal class NativePlaybackRecoveryController(
    private val host: NativePlaybackRecoveryHost,
    private val environment: NativePlaybackRecoveryEnvironment,
    private val recoveryWindowMs: Long
) {
    private val intended = linkedSetOf<String>()
    private val pending = linkedSetOf<String>()
    private val attempts = mutableMapOf<String, Int>()
    private val retryTasks = mutableMapOf<String, Runnable>()
    private val expiryTasks = mutableMapOf<String, Runnable>()
    private val startedAt = mutableMapOf<String, Long>()
    private var listening = false

    val intendedSessionIds: Set<String> get() = intended.toSet()

    fun isIntended(sessionId: String): Boolean = sessionId in intended

    fun isPending(sessionId: String): Boolean = sessionId in pending

    fun markIntended(sessionId: String) {
        intended += sessionId
    }

    fun clear(sessionId: String) {
        intended -= sessionId
        clearRecovery(sessionId)
    }

    fun clearAll() {
        intended.clear()
        pending.toList().forEach(::clearRecovery)
        stopListening()
    }

    fun onPlaying(sessionId: String) {
        clearRecovery(sessionId)
    }

    fun onPlayerError(
        sessionId: String,
        recoverable: Boolean,
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
        startListening()
        scheduleExpiry(sessionId)
        scheduleRetry(sessionId, attempt)
        host.syncForeground()
    }

    fun trigger(reason: String) {
        if (pending.isNotEmpty()) {
            host.logInfo("playback_recovery_trigger trigger=$reason pending=${pending.size}")
            pending.toList().forEach { retry(it, reason) }
        }
        recoverIntendedPlayback(reason)
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

    private fun scheduleRetry(sessionId: String, attempt: Int) {
        retryTasks.remove(sessionId)?.let(environment::remove)
        val recoveryStarted = startedAt.getOrPut(sessionId, environment::elapsedRealtimeMs)
        val delayMs = playbackRecoveryDelayMs(attempt, recoveryStarted, environment.elapsedRealtimeMs())
            ?: run {
                host.logInfo("player_error_retry_waiting_for_trigger sessionId=$sessionId attempts=$attempt")
                return
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
        val player = session.playerOrNull()
        if (player != null && player.isPlaying && player.playerError == null) {
            clearRecovery(sessionId)
            return
        }
        retryTasks.remove(sessionId)?.let(environment::remove)
        host.logInfo("player_error_retry_executing sessionId=$sessionId trigger=$reason")
        if (!host.requestAudioFocus()) {
            clear(sessionId)
            session.playerOrNull()?.pause()
            host.publishSession(sessionId)
            host.syncForeground()
            return
        }
        try {
            host.focusSession(sessionId)
            session.applyFadeMultiplier(1f)
            session.reprepareCurrentMediaItem()
            host.ensurePlayer(session).play()
            host.publishSession(sessionId)
            host.schedulePersist()
            host.syncForeground()
        } catch (error: Exception) {
            host.logWarn("player_error_retry_failed sessionId=$sessionId trigger=$reason", session, error as? PlaybackException)
            scheduleRetry(sessionId, attempts.getOrDefault(sessionId, 0))
            host.syncForeground()
        }
    }

    private fun scheduleExpiry(sessionId: String) {
        if (sessionId in expiryTasks) return
        val recoveryStarted = startedAt.getOrPut(sessionId, environment::elapsedRealtimeMs)
        val delayMs = (recoveryStarted + recoveryWindowMs - environment.elapsedRealtimeMs()).coerceAtLeast(0L)
        val task = Runnable {
            expiryTasks.remove(sessionId)
            if (sessionId !in pending) return@Runnable
            host.logInfo("playback_recovery_expired sessionId=$sessionId")
            clear(sessionId)
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
            if (sessionId in pending || (player.isPlaying || player.playWhenReady) && player.playerError == null) {
                return@forEach
            }
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
