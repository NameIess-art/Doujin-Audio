package com.nameless.audio

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.AudioAttributes as AndroidAudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaNotification
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

import java.util.concurrent.ConcurrentHashMap

internal fun shouldPublishProgressHeartbeat(
    isScreenOn: Boolean,
    nowElapsedRealtimeMs: Long,
    lastPublishedElapsedRealtimeMs: Long,
    screenOffIntervalMs: Long
): Boolean =
    isScreenOn ||
        nowElapsedRealtimeMs - lastPublishedElapsedRealtimeMs >= screenOffIntervalMs

internal fun exclusivePlaybackSessionIdsToPause(
    targetSessionId: String,
    sessionPlaybackIntent: Map<String, Boolean>
): List<String> = sessionPlaybackIntent
    .filter { (sessionId, hasPlaybackIntent) ->
        sessionId != targetSessionId && hasPlaybackIntent
    }
    .keys
    .toList()

private val playbackRecoveryOffsetsMs = longArrayOf(
    2_000L,
    8_000L,
    30_000L,
    2 * 60 * 1000L,
    4 * 60 * 1000L,
    8 * 60 * 1000L
)

internal fun idlePlaybackSessionIdsToRelease(
    focusedSessionId: String?,
    idleSessionIds: Collection<String>
): Set<String> {
    return idleSessionIds
        .filterNot { it == focusedSessionId }
        .toSet()
}

class NativePlaybackService : MediaSessionService() {
    companion object {
        const val ACTION_START = "com.nameless.audio.native.START"
        private const val EXTRA_REQUIRE_FOREGROUND_BOOTSTRAP =
            "require_foreground_bootstrap"
        private const val PLAYBACK_CHANNEL_ID = "com.nameless.audio.channel.playback"
        private const val PLAYBACK_CHANNEL_NAME = "Playback"
        private const val PLAYBACK_CHANNEL_DESCRIPTION = "Playback notification controls"
        private const val FOREGROUND_NOTIFICATION_ID =
            UnifiedPlaybackNotificationController.foregroundServiceNotificationId
        private const val FOREGROUND_WATCHDOG_INTERVAL_MS = 4 * 60 * 1000L
        private const val STATE_PERSISTENCE_INTERVAL_MS = 15 * 1000L
        private const val STATE_PERSISTENCE_DEBOUNCE_MS = 800L
        // Grace period before releasing the wake lock / stopping foreground after
        // playback appears to have stopped. Android's background-audio guidance
        // recommends keeping a mediaPlayback foreground service alive through
        // transient buffering/focus failures under 10 minutes; a short grace
        // window lets screen-off playback get killed during those gaps.
        private const val PLAYBACK_STOP_GRACE_MS = 10 * 60 * 1000L
        private const val PLAYBACK_RECOVERY_WINDOW_MS = 10 * 60 * 1000L
        private const val PROGRESS_HEARTBEAT_INTERVAL_MS = 500L
        private const val SCREEN_OFF_PROGRESS_HEARTBEAT_INTERVAL_MS = 5000L
        private const val LOG_TAG = "NativePlaybackService"

        @Volatile
        private var instance: NativePlaybackService? = null

        @Volatile
        var foregroundSuppressed = false

        @Volatile
        var notificationsDismissed = false

        fun controller(): NativePlaybackService? = instance

        fun ensureStarted(
            context: Context,
            requireForegroundBootstrap: Boolean = false
        ): NativePlaybackService? {
            controller()?.let { return it }
            val intent = Intent(context.applicationContext, NativePlaybackService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_REQUIRE_FOREGROUND_BOOTSTRAP, requireForegroundBootstrap)
            }
            return try {
                if (requireForegroundBootstrap) {
                    ContextCompat.startForegroundService(context.applicationContext, intent)
                } else {
                    context.applicationContext.startService(intent)
                }
                controller()
            } catch (_: Exception) {
                try {
                    ContextCompat.startForegroundService(context.applicationContext, intent.apply {
                        putExtra(EXTRA_REQUIRE_FOREGROUND_BOOTSTRAP, true)
                    })
                } catch (_: Exception) {
                    // Best effort; callers retry while a BroadcastReceiver async
                    // result is alive.
                }
                controller()
            }
        }
    }

    private val sessions = linkedMapOf<String, NativePlaybackSession>()
    private val fileCacheOperations by lazy { FileCacheOperations(applicationContext) }
    private val stateListeners = ConcurrentHashMap<String, (Map<String, Any?>) -> Unit>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val progressPublisher by lazy {
        NativePlaybackProgressPublisher(
            mainHandler = mainHandler,
            anchors = { sessions.values.map(NativePlaybackSession::progressAnchorSnapshot) },
            currentAnchors = {
                sessions.mapValues { (_, session) -> session.progressAnchorSnapshot() }
            },
            listeners = { stateListeners.values }
        )
    }
    private val statePersistence by lazy {
        NativePlaybackStatePersistenceCoordinator(
            context = applicationContext,
            mainHandler = mainHandler,
            intervalMs = STATE_PERSISTENCE_INTERVAL_MS,
            debounceMs = STATE_PERSISTENCE_DEBOUNCE_MS,
            hasSessions = { sessions.isNotEmpty() },
            storedSessions = {
                val intendedSessionIds = intendedPlaybackSessionIds.toSet()
                sessions.values.map { session ->
                    session.storedSnapshot().let { stored ->
                        if (session.sessionId in intendedSessionIds) {
                            stored.copy(playWhenReady = true)
                        } else {
                            stored
                        }
                    }
                }
            }
        )
    }
    private val playbackWakeLock by lazy {
        NativePlaybackWakeLock(
            context = this,
            logInfo = ::logInfo,
            logWarn = { message, error -> logWarn(message, error = error) }
        )
    }
    private val foregroundNotificationFactory by lazy {
        NativeForegroundNotificationFactory(this, PLAYBACK_CHANNEL_ID)
    }
    private val playerFactory by lazy {
        NativePlayerFactory(
            context = this,
            callbacks = object : NativePlayerEventCallbacks {
                override fun onPlaybackStateChanged(sessionId: String, playbackState: Int) {
                    handlePlaybackStateChanged(sessionId, playbackState)
                }

                override fun onMediaItemTransition(sessionId: String, reason: Int) {
                    handleMediaItemTransition(sessionId, reason)
                }

                override fun onPlayerEvents(sessionId: String) {
                    publishSessionState(sessionId)
                }

                override fun onPlayWhenReadyChanged(
                    sessionId: String,
                    playWhenReady: Boolean,
                    reason: Int
                ) {
                    handlePlayWhenReadyChanged(sessionId, playWhenReady, reason)
                }

                override fun onIsPlayingChanged(sessionId: String, isPlaying: Boolean) {
                    handleIsPlayingChanged(sessionId, isPlaying)
                }

                override fun onPlayerError(sessionId: String, error: PlaybackException) {
                    handlePlayerError(sessionId, error)
                }

                override fun onAudioSessionIdChanged(sessionId: String, audioSessionId: Int) {
                    publishSessionState(sessionId)
                }
            }
        )
    }
    private val sessionRestorer by lazy {
        NativePlaybackSessionRestorer(
            getOrCreateSession = { sessionId ->
                sessions.getOrPut(sessionId) { createNativePlaybackSession(sessionId) }
            },
            removeSession = { sessionId -> sessions.remove(sessionId) },
            focusSession = ::focusSession,
            logRestoreFailure = { sessionId, error ->
                logWarn("restore_session_failed sessionId=$sessionId", error = error)
            }
        )
    }
    private var mediaSession: MediaSession? = null
    private var dummyPlayer: ExoPlayer? = null

    fun currentMediaSession(): MediaSession? {
        return mediaSession
    }

    private fun ensureMediaSessionForBootstrap() {
        if (mediaSession != null) return
        try {
            val player = ExoPlayer.Builder(this).build()
            dummyPlayer = player
            mediaSession = MediaSession.Builder(this, player)
                .setId("Nameless Audio Bootstrap")
                .build()
        } catch (e: Exception) {
            logWarn("ensure_media_session_for_bootstrap_failed", error = e)
        }
    }

    var focusedSessionId: String? = null
        private set
    private var tickerScheduled = false
    private var foregroundWatchdogScheduled = false
    private var playbackSuspended = false
    private var playbackForegroundStarted = false
    private var playbackForegroundSignature: String? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var audioFocusHeld = false
    private var transientAudioFocusLossActive = false
    private val pendingAudioFocusResumeSessionIds = linkedSetOf<String>()
    private val intendedPlaybackSessionIds = linkedSetOf<String>()
    private val pendingRecoverySessionIds = linkedSetOf<String>()
    private var attemptedStickyPlaybackRestore = false
    private val errorRetryAttempts = mutableMapOf<String, Int>()
    private val errorRetryRunnables = mutableMapOf<String, Runnable>()
    private val recoveryExpiryRunnables = mutableMapOf<String, Runnable>()
    private val recoveryStartedElapsedRealtimeMs = mutableMapOf<String, Long>()
    private var recoveryNetworkCallback: ConnectivityManager.NetworkCallback? = null
    private var recoveryNetworkAvailable = false
    private var screenOnReceiverRegistered = false
    private val screenOnReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != Intent.ACTION_SCREEN_ON) return
            mainHandler.post { handlePlaybackRecoveryTrigger("screen_on") }
        }
    }
    // Whether a deferred foreground-stop is pending (grace period after
    // playback appears to have stopped).
    private var foregroundStopGracePending = false
    private val audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { change ->
        logInfo("audio_focus_change focus=${audioFocusChangeName(change)}")
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                // Mark focus as no longer held so the next syncForegroundState
                // call will re-request it when playback resumes.
                audioFocusHeld = false
                transientAudioFocusLossActive = false
                pendingAudioFocusResumeSessionIds.clear()
                intendedPlaybackSessionIds.clear()
                clearAllPlaybackRecovery()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                if (shouldPauseForAudioFocusChange(change)) {
                    audioFocusHeld = false
                    transientAudioFocusLossActive = true
                    sessions.values.forEach { session ->
                        val player = session.playerOrNull()
                        if (player != null && (player.isPlaying || player.playWhenReady)) {
                            pendingAudioFocusResumeSessionIds.add(session.sessionId)
                            player.pause()
                        }
                    }
                } else {
                    // The focus request explicitly opts into ducking instead
                    // of pausing. Some vendor builds still dispatch this
                    // callback; pausing here can leave playback waiting until
                    // the screen wakes and focus is granted again.
                    logInfo("audio_focus_duck_continue")
                }
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                audioFocusHeld = true
                transientAudioFocusLossActive = false
                if (resumePendingAudioFocusSessionsIfPossible("audio_focus_gain")) {
                    schedulePersistSessionState()
                    syncForegroundState()
                }
            }
        }
    }
    // Deferred runnable that actually stops the foreground service and releases
    // the wake lock after the grace period expires.  If playback resumes within
    // the grace window this runnable is cancelled.
    private val foregroundStopGraceRunnable = Runnable {
        foregroundStopGracePending = false
        if (!hasPlaybackToKeepAlive()) {
            logInfo("foreground_stop_grace_expired executing_deferred_stop")
            abandonAudioFocus(reason = "grace_expired_no_active_playback")
            releaseWakeLock()
            stopForegroundWatchdog()
            persistSessionStateNow()
            stopPlaybackForeground(
                reason = "grace_expired_no_active_playback",
                removeNotification = sessions.isEmpty()
            )
        } else {
            logInfo("foreground_stop_grace_expired playback_resumed_skip")
        }
    }
    private var lastProgressHeartbeatElapsedRealtimeMs = 0L

    private val positionTicker = object : Runnable {
        override fun run() {
            if (stateListeners.isEmpty() || sessions.isEmpty()) {
                tickerScheduled = false
                return
            }
            
            val nowElapsedRealtimeMs = SystemClock.elapsedRealtime()
            val powerManager = getSystemService(POWER_SERVICE) as? PowerManager
            val isScreenOn = powerManager?.isInteractive ?: true

            if (shouldPublishProgressHeartbeat(
                isScreenOn = isScreenOn,
                nowElapsedRealtimeMs = nowElapsedRealtimeMs,
                lastPublishedElapsedRealtimeMs = lastProgressHeartbeatElapsedRealtimeMs,
                screenOffIntervalMs = SCREEN_OFF_PROGRESS_HEARTBEAT_INTERVAL_MS
            )) {
                publishProgressSessionStatesAsync(nowElapsedRealtimeMs)
                lastProgressHeartbeatElapsedRealtimeMs = nowElapsedRealtimeMs
            }

            mainHandler.postDelayed(this, PROGRESS_HEARTBEAT_INTERVAL_MS)
        }
    }
    private val foregroundWatchdog = object : Runnable {
        override fun run() {
            if (!hasPlaybackToKeepAlive()) {
                // Don't stop the watchdog immediately 鈥?a grace-period stop may
                // already be pending.  Just reschedule; the grace runnable will
                // clean up if playback truly stopped.
                mainHandler.postDelayed(this, FOREGROUND_WATCHDOG_INTERVAL_MS)
                return
            }
            
            playbackWakeLock.refresh()
            handlePlaybackRecoveryTrigger("foreground_watchdog")

            if (playbackForegroundStarted) {
                startPlaybackForeground(forceRefresh = true)
            } else {
                startPlaybackForeground(forceRefresh = true)
            }
            mainHandler.postDelayed(this, FOREGROUND_WATCHDOG_INTERVAL_MS)
        }
    }
    override fun onCreate() {
        super.onCreate()
        ensurePlaybackChannel()
        instance = this
        logInfo("on_create")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        if (shouldAttemptStickyPlaybackRestore(sessions.isNotEmpty(), attemptedStickyPlaybackRestore)) {
            attemptedStickyPlaybackRestore = true
            restorePersistedPlaybackAfterServiceRestart()
        }
        if (intent?.action == ACTION_START &&
            intent.getBooleanExtra(EXTRA_REQUIRE_FOREGROUND_BOOTSTRAP, false) &&
            !hasPlaybackToKeepAlive()
        ) {
            logInfo("on_start_command foreground_bootstrap_requested")
            startBootstrapForeground()
        }
        return START_STICKY
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        return ensureMediaSession()
    }

    override fun onUpdateNotification(session: MediaSession, startInForeground: Boolean) {
        // We manage the foreground service and notification manually using
        // UnifiedPlaybackNotificationController and startPlaybackForeground().
        // Doing nothing here prevents Media3 from automatically posting notifications
        // and accidentally calling stopForeground(), which drops the foreground
        // status and causes Doze mode to suspend the app during screen-off.
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        logInfo("on_task_removed hasActivePlayback=${hasPlaybackToKeepAlive()}")
        if (hasPlaybackToKeepAlive()) {
            // Keep the foreground service alive; stopWithTask="false" in the
            // manifest already prevents the OS from stopping us, but we also
            // explicitly re-sync to be safe.
            syncForegroundState()
        } else if (sessions.isNotEmpty()) {
            // Sessions exist but nothing is actively playing right now (e.g.
            // the user swiped the app away during a brief buffering gap).
            // Do NOT call stopSelf() 鈥?let the grace-period runnable decide.
            // The foreground service will keep us alive until the grace window
            // expires or playback resumes.
            logInfo("on_task_removed sessions_present_deferring_stop")
            scheduleForegroundStopGrace()
        } else {
            stopForegroundWatchdog()
            cancelForegroundStopGrace()
            stopPlaybackForeground(
                reason = "task_removed_no_sessions",
                removeNotification = true
            )
            stopSelf()
        }
    }

    override fun onDestroy() {
        logInfo(
            "on_destroy_begin sessions=${sessions.size} " +
                "foregroundStarted=$playbackForegroundStarted wakeLockHeld=${playbackWakeLock.isHeld()}"
        )
        stateListeners.clear()
        mainHandler.removeCallbacks(positionTicker)
        progressPublisher.shutdown()
        statePersistence.shutdown()
        clearAllPlaybackRecovery()
        cancelForegroundStopGrace()
        stopForegroundWatchdog()
        tickerScheduled = false
        releaseMediaSession("on_destroy")
        sessions.values.forEach { it.release() }
        sessions.clear()
        stopPlaybackForeground(reason = "on_destroy", removeNotification = true)
        abandonAudioFocus(reason = "on_destroy")
        releaseWakeLock()
        instance = null
        super.onDestroy()
        logInfo("on_destroy_end")
    }

    fun addStateListener(ownerId: String, listener: (Map<String, Any?>) -> Unit) {
        val isNewOwner = stateListeners.put(ownerId, listener) == null
        if (isNewOwner) {
            sessions.values.forEach { listener(it.snapshot()) }
        }
        ensureTicker()
    }

    fun removeStateListener(ownerId: String) {
        stateListeners.remove(ownerId)
        if (stateListeners.isEmpty()) {
            mainHandler.removeCallbacks(positionTicker)
            tickerScheduled = false
        }
    }

    fun prepareSession(args: Map<String, Any?>): Map<String, Any?> {
        val sessionId = args["sessionId"] as? String ?: return errorResult("Missing sessionId.")
        val uri = args["uri"] as? String ?: return errorResult("Missing uri.")
        val path = args["path"] as? String ?: uri
        val title = args["title"] as? String ?: "Audio"
        val subtitle = args["subtitle"] as? String
        val artUri = args["artUri"] as? String
        val startPositionMs = (args["startPositionMs"] as? Number)?.toLong() ?: 0L
        val autoPlay = args["autoPlay"] as? Boolean ?: false
        val volume = (args["volume"] as? Number)?.toFloat() ?: 1f
        val speed = (args["speed"] as? Number)?.toFloat() ?: 1f
        val audioEffects = NativePlaybackCommandPayloads.parseAudioEffects(
            args["audioEffects"] as? Map<*, *> ?: emptyMap<Any?, Any?>()
        )
        val repeatOne = args["repeatOne"] as? Boolean ?: false
        val queue = NativePlaybackCommandPayloads.parseQueue(args["queue"]).ifEmpty {
            listOf(NativeMediaItemDescriptor(path, uri, title, subtitle, artUri))
        }
        val queueStartIndex = ((args["queueStartIndex"] as? Number)?.toInt() ?: 0)
            .coerceIn(0, queue.lastIndex)
        val repeatAll = args["repeatAll"] as? Boolean ?: false
        val shuffle = args["shuffle"] as? Boolean ?: false
        val deferPlayerCreation = args["deferPlayerCreation"] as? Boolean ?: false
        if (autoPlay) {
            notificationsDismissed = false
            playbackSuspended = false
            markPlaybackIntended(sessionId)
        } else {
            clearPlaybackIntent(sessionId)
        }

        val nativeSession = sessions.getOrPut(sessionId) {
            createNativePlaybackSession(sessionId)
        }
        pendingAudioFocusResumeSessionIds.remove(sessionId)
        return try {
            nativeSession.applyAudioEffects(audioEffects)
            nativeSession.configure(
                descriptor = queue[queueStartIndex],
                queue = queue,
                queueStartIndex = queueStartIndex,
                startPositionMs = startPositionMs,
                volume = volume,
                speed = speed,
                repeatOne = repeatOne,
                repeatAll = repeatAll,
                shuffleModeEnabled = shuffle,
                autoPlay = autoPlay,
                deferPlayerCreation = deferPlayerCreation
            )
            if (!deferPlayerCreation) {
                focusSession(sessionId)
                ensureFocusedMediaSession()
            }
            evictPlayersIfNeeded()
            publishSessionState(sessionId)
            ensureTicker()
            persistSessionStateNow()
            ensureStatePersistenceTicker()
            syncForegroundState()
            okResult(nativeSession.snapshot())
        } catch (e: Exception) {
            sessions.remove(sessionId)
            nativeSession.release()
            if (focusedSessionId == sessionId) {
                focusedSessionId = sessions.keys.firstOrNull()
                updateMediaSessionPlayer()
            }
            syncForegroundState()
            errorResult("Failed to prepare session: ${e.message}")
        }
    }

    fun play(
        sessionId: String,
        transportCommandId: Long = 0L,
        exclusive: Boolean = false
    ): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        val pausedSessionIds = if (exclusive) {
            exclusivePlaybackSessionIdsToPause(
                targetSessionId = sessionId,
                sessionPlaybackIntent = sessions.mapValues { (candidateId, candidate) ->
                    val player = candidate.playerOrNull()
                    candidateId in intendedPlaybackSessionIds ||
                        player?.isPlaying == true ||
                        player?.playWhenReady == true
                }
            )
        } else {
            emptyList()
        }
        pausedSessionIds.forEach { pausedSessionId ->
            val pausedSession = sessions[pausedSessionId] ?: return@forEach
            if (transportCommandId > 0L) {
                pausedSession.transportCommandId = transportCommandId
            }
            pendingAudioFocusResumeSessionIds.remove(pausedSessionId)
            clearPlaybackIntent(pausedSessionId)
            pausedSession.playerOrNull()?.pause()
        }
        session.lastUsedMs = System.currentTimeMillis()
        if (transportCommandId > 0L) {
            session.transportCommandId = transportCommandId
        }
        pendingAudioFocusResumeSessionIds.remove(sessionId)
        notificationsDismissed = false
        playbackSuspended = false
        markPlaybackIntended(sessionId)
        session.applyFadeMultiplier(1f)
        focusSession(sessionId)
        ensureFocusedPlayer(session).play()
        evictPlayersIfNeeded()
        pausedSessionIds.forEach(::publishSessionState)
        val snapshot = publishSessionState(sessionId)
        ensureTicker()
        schedulePersistSessionState()
        ensureStatePersistenceTicker()
        syncForegroundState()
        return okResult(snapshot)
    }

    fun pause(
        sessionId: String,
        transportCommandId: Long = 0L
    ): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.lastUsedMs = System.currentTimeMillis()
        if (transportCommandId > 0L) {
            session.transportCommandId = transportCommandId
        }
        pendingAudioFocusResumeSessionIds.remove(sessionId)
        clearPlaybackIntent(sessionId)
        session.playerOrNull()?.pause()
        evictPlayersIfNeeded()
        val snapshot = publishSessionState(sessionId)
        schedulePersistSessionState()
        syncForegroundState()
        return okResult(snapshot)
    }

    fun stop(sessionId: String): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.lastUsedMs = System.currentTimeMillis()
        pendingAudioFocusResumeSessionIds.remove(sessionId)
        clearPlaybackIntent(sessionId)
        val player = session.playerOrNull()
        player?.stop()
        player?.clearMediaItems()
        evictPlayersIfNeeded()
        publishSessionState(sessionId)
        persistSessionStateNow()
        syncForegroundState()
        return okResult(session.snapshot())
    }

    fun skipToNext(sessionId: String): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Session not found")
        session.lastUsedMs = System.currentTimeMillis()
        focusSession(sessionId)
        ensureFocusedPlayer(session).seekToNextMediaItem()
        evictPlayersIfNeeded()
        publishSessionState(sessionId)
        persistSessionStateNow()
        syncForegroundState()
        return okResult(session.snapshot())
    }

    fun skipToPrevious(sessionId: String): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Session not found")
        session.lastUsedMs = System.currentTimeMillis()
        focusSession(sessionId)
        ensureFocusedPlayer(session).seekToPreviousMediaItem()
        evictPlayersIfNeeded()
        publishSessionState(sessionId)
        persistSessionStateNow()
        syncForegroundState()
        return okResult(session.snapshot())
    }

    fun togglePlayPause(sessionId: String): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Session not found")
        session.lastUsedMs = System.currentTimeMillis()
        pendingAudioFocusResumeSessionIds.remove(sessionId)
        notificationsDismissed = false
        playbackSuspended = false
        focusSession(sessionId)
        val player = ensureFocusedPlayer(session)
        if (player.playWhenReady) {
            clearPlaybackIntent(sessionId)
            player.pause()
        } else {
            markPlaybackIntended(sessionId)
            session.applyFadeMultiplier(1f)
            player.play()
        }
        evictPlayersIfNeeded()
        publishSessionState(sessionId)
        ensureTicker()
        persistSessionStateNow()
        ensureStatePersistenceTicker()
        syncForegroundState()
        return okResult(session.snapshot())
    }

    fun executeNotificationAction(
        action: String,
        requestedSessionId: String
    ): Map<String, Any?> {
        val storedSessions = if (
            requestedSessionId.isBlank() ||
            !sessions.containsKey(requestedSessionId)
        ) {
            NativePlaybackStateStore.loadSessions(this)
        } else {
            emptyList()
        }
        val sessionId = resolveNotificationSessionId(
            requestedSessionId = requestedSessionId,
            focusedSessionId = focusedSessionId,
            activeSessionIds = sessions.values
                .filter { it.isPlaying() }
                .map { it.sessionId },
            existingSessionIds = sessions.keys,
            storedActiveSessionIds = storedSessions
                .filter { it.playing || it.playWhenReady }
                .map { it.sessionId },
            storedSessionIds = storedSessions.map { it.sessionId }
        )
        if (sessionId.isEmpty()) return errorResult("No focused session")
        restorePersistedSessionForNotification(sessionId, storedSessions)
        return when (action) {
            NotificationCommand.toggle.actionName -> togglePlayPause(sessionId)
            NotificationCommand.previous.actionName -> skipToPrevious(sessionId)
            NotificationCommand.next.actionName -> skipToNext(sessionId)
            else -> errorResult("Unknown notification action")
        }
    }

    fun seek(sessionId: String, positionMs: Long): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.ensurePlayer().seekTo(positionMs.coerceAtLeast(0L))
        publishSessionState(sessionId)
        schedulePersistSessionState()
        return okResult(session.snapshot())
    }

    fun setVolume(sessionId: String, volume: Float): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.applyVolume(volume)
        publishSessionState(sessionId)
        schedulePersistSessionState()
        return okResult(session.snapshot())
    }

    fun setFadeMultiplier(sessionId: String, multiplier: Float): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.applyFadeMultiplier(multiplier)
        // Note: we don't necessarily need to persist this, as it's transient
        return okResult(session.snapshot())
    }

    fun setSpeed(sessionId: String, speed: Float): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.applySpeed(speed)
        publishSessionState(sessionId)
        schedulePersistSessionState()
        return okResult(session.snapshot())
    }

    fun setAudioEffects(sessionId: String, effectsMap: Map<String, Any?>): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        val previousChannelSwap = session.channelSwapEnabled
        session.applyAudioEffects(NativePlaybackCommandPayloads.parseAudioEffects(effectsMap))
        if (previousChannelSwap != session.channelSwapEnabled) {
            session.reprepareCurrentMediaItem()
        }
        publishSessionState(sessionId)
        schedulePersistSessionState()
        syncForegroundState()
        return okResult(session.snapshot())
    }

    fun setRepeatOne(
        sessionId: String,
        repeatOne: Boolean,
        args: Map<String, Any?> = emptyMap()
    ): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.lastUsedMs = System.currentTimeMillis()
        session.repeatOne = repeatOne
        val queue = NativePlaybackCommandPayloads.parseQueue(args["queue"])
        if (queue.isNotEmpty()) {
            val queueStartIndex = ((args["queueStartIndex"] as? Number)?.toInt() ?: 0)
                .coerceIn(0, queue.lastIndex)
            session.updateQueue(
                queue = queue,
                queueStartIndex = queueStartIndex,
                repeatOne = repeatOne,
                repeatAll = args["repeatAll"] as? Boolean ?: false,
                shuffleModeEnabled = args["shuffle"] as? Boolean ?: false
            )
        } else {
            session.repeatAll = args["repeatAll"] as? Boolean ?: session.repeatAll
            session.shuffleModeEnabled = args["shuffle"] as? Boolean ?: session.shuffleModeEnabled
            session.playerOrNull()?.repeatMode = if (repeatOne) {
                Player.REPEAT_MODE_ONE
            } else {
                session.currentRepeatMode()
            }
            session.playerOrNull()?.shuffleModeEnabled = session.currentShuffleModeEnabled()
        }
        schedulePersistSessionState()
        return okResult(session.snapshot())
    }

    fun removeSession(sessionId: String): Map<String, Any?> {
        pendingAudioFocusResumeSessionIds.remove(sessionId)
        clearPlaybackIntent(sessionId)
        val removed = sessions.remove(sessionId) ?: return okResult(null)
        removed.release()
        if (focusedSessionId == sessionId) {
            focusedSessionId = sessions.keys.firstOrNull()
            updateMediaSessionPlayer()
        }
        if (sessions.isEmpty()) {
            cancelForegroundStopGrace()
            stopForegroundWatchdog()
            stopStatePersistenceTicker()
            cancelScheduledPersistSessionState()
            NativePlaybackStateStore.clearSessions(this)
            NativePlaybackStateStore.clearPausedSessionIds(this)
            NativePlaybackStateStore.clearTimerCandidateSessionIds(this)
            NativePlaybackStateStore.clearTimerRuntimeState(this)
            releaseMediaSession("remove_session_empty")
            abandonAudioFocus(reason = "remove_session_empty")
            stopPlaybackForeground(reason = "remove_session_empty", removeNotification = true)
            stopSelf()
        } else {
            persistSessionStateNow()
            syncForegroundState()
        }
        return okResult(null)
    }

    fun pauseAll(): Map<String, Any?> {
        notificationsDismissed = true
        transientAudioFocusLossActive = false
        pendingAudioFocusResumeSessionIds.clear()
        intendedPlaybackSessionIds.clear()
        clearAllPlaybackRecovery()
        sessions.values.forEach { it.playerOrNull()?.pause() }
        evictPlayersIfNeeded()
        publishAllSessionStates()
        persistSessionStateNow()
        cancelForegroundStopGrace()
        stopForegroundWatchdog()
        playbackSuspended = true
        abandonAudioFocus(reason = "pause_all")
        releaseWakeLock()
        stopPlaybackForeground(reason = "pause_all", removeNotification = sessions.isEmpty())
        return okResult(null)
    }

    fun clearAll(): Map<String, Any?> {
        notificationsDismissed = true
        transientAudioFocusLossActive = false
        pendingAudioFocusResumeSessionIds.clear()
        intendedPlaybackSessionIds.clear()
        clearAllPlaybackRecovery()
        sessions.values.forEach { it.release() }
        sessions.clear()
        focusedSessionId = null
        releaseMediaSession("clear_all")
        cancelForegroundStopGrace()
        stopForegroundWatchdog()
        stopStatePersistenceTicker()
        cancelScheduledPersistSessionState()
        NativePlaybackStateStore.clearSessions(this)
        NativePlaybackStateStore.clearPausedSessionIds(this)
        NativePlaybackStateStore.clearTimerCandidateSessionIds(this)
        NativePlaybackStateStore.clearTimerRuntimeState(this)
        abandonAudioFocus(reason = "clear_all")
        stopPlaybackForeground(reason = "clear_all", removeNotification = true)
        stopSelf()
        return okResult(null)
    }

    fun snapshot(): Map<String, Any?> {
        return okResult(
            mapOf(
                "sessions" to sessions.values.map { it.snapshot() },
                "focusedSessionId" to focusedSessionId
            )
        )
    }

    fun setForegroundEnabled(enabled: Boolean): Map<String, Any?> {
        foregroundSuppressed = !enabled
        if (!enabled) {
            notificationsDismissed = true
            if (hasPlaybackToKeepAlive()) {
                acquireWakeLock()
                updateMediaSessionPlayer()
                requestAudioFocusIfNeeded()
                startPlaybackForeground(forceRefresh = true)
                ensureForegroundWatchdog()
            } else {
                stopForegroundWatchdog()
                stopPlaybackForeground(
                    reason = "foreground_disabled_no_active_playback",
                    removeNotification = true
                )
            }
        } else {
            notificationsDismissed = false
            updateMediaSessionPlayer()
            if (hasPlaybackToKeepAlive()) {
                acquireWakeLock()
                requestAudioFocusIfNeeded()
                startPlaybackForeground(forceRefresh = true)
                ensureForegroundWatchdog()
            }
        }
        return okResult(null)
    }

    fun dismissNotifications(): Map<String, Any?> {
        notificationsDismissed = true
        if (hasPlaybackToKeepAlive()) {
            startPlaybackForeground(forceRefresh = true)
            ensureForegroundWatchdog()
        }
        return okResult(null)
    }

    fun undismissNotifications(): Map<String, Any?> {
        notificationsDismissed = false
        return okResult(null)
    }

    fun pausePlayingSessionsForTimer(): List<String> {
        val pausedSessionIds = sessions.values
            .filter { val p = it.playerOrNull(); p != null && (p.isPlaying || p.playWhenReady) }
            .map { it.sessionId }
        if (pausedSessionIds.isEmpty()) {
            syncForegroundState()
            return emptyList()
        }
        transientAudioFocusLossActive = false
        pausedSessionIds.forEach { sessionId ->
            pendingAudioFocusResumeSessionIds.remove(sessionId)
            clearPlaybackIntent(sessionId)
            sessions[sessionId]?.let { session ->
                session.playerOrNull()?.pause()
                session.applyFadeMultiplier(1f)
            }
        }
        evictPlayersIfNeeded()
        publishAllSessionStates()
        persistSessionStateNow()
        syncForegroundState()
        return pausedSessionIds
    }

    fun resumeSessionsForTimer(sessionIds: List<String>): List<String> {
        if (sessionIds.isEmpty()) return emptyList()
        restorePersistedSessionsForTimer(sessionIds)
        notificationsDismissed = false
        playbackSuspended = false
        val resumedSessionIds = mutableListOf<String>()
        sessionIds.forEach { sessionId ->
            pendingAudioFocusResumeSessionIds.remove(sessionId)
            val session = sessions[sessionId] ?: return@forEach
            markPlaybackIntended(sessionId)
            session.applyFadeMultiplier(1f)
            focusSession(sessionId)
            ensureFocusedPlayer(session).play()
            resumedSessionIds += sessionId
        }
        if (resumedSessionIds.isNotEmpty()) {
            ensureTicker()
            ensureStatePersistenceTicker()
            publishAllSessionStates()
            persistSessionStateNow()
        }
        syncForegroundState()
        return resumedSessionIds
    }

    private fun evictPlayersIfNeeded() {
        val idleSessions = sessions.values
            .filter { session ->
                val player = session.playerOrNull() ?: return@filter false
                !player.isPlaying &&
                    !player.playWhenReady &&
                    session.sessionId !in intendedPlaybackSessionIds &&
                    session.sessionId !in pendingAudioFocusResumeSessionIds &&
                    session.sessionId !in pendingRecoverySessionIds
            }
        val releaseIds = idlePlaybackSessionIdsToRelease(
            focusedSessionId = focusedSessionId,
            idleSessionIds = idleSessions.map { it.sessionId }
        )
        idleSessions
            .filter { it.sessionId in releaseIds }
            .sortedBy { it.lastUsedMs }
            .forEach(NativePlaybackSession::releasePlayer)
    }

    private fun createNativePlaybackSession(sessionId: String): NativePlaybackSession {
        return NativePlaybackSession(
            sessionId = sessionId,
            createPlayer = playerFactory::create,
            logWarn = { message, session, error -> logWarn(message, session, error) },
            resolveUriToPath = { uri -> fileCacheOperations.contentUriToFilePath(uri) }
        )
    }

    private fun handlePlaybackStateChanged(sessionId: String, playbackState: Int) {
        if (playbackState == Player.STATE_ENDED) {
            clearPlaybackIntent(sessionId)
        }
        logInfo(
            "player_state_changed state=${playbackStateName(playbackState)}",
            sessions[sessionId]
        )
        publishSessionState(sessionId)
        schedulePersistSessionState()
        syncForegroundState()
    }

    private fun handleMediaItemTransition(sessionId: String, reason: Int) {
        sessions[sessionId]?.syncCurrentMediaItemFromPlayer()
        logInfo(
            "player_media_item_transition reason=$reason",
            sessions[sessionId]
        )
        publishSessionState(sessionId)
        persistSessionStateNow()
        syncForegroundState()
    }

    private fun handlePlayWhenReadyChanged(
        sessionId: String,
        playWhenReady: Boolean,
        reason: Int
    ) {
        val preservePendingTransientFocusResume =
            shouldPreservePendingAudioFocusResume(
                playWhenReady = playWhenReady,
                focusLossMayResume = transientAudioFocusLossActive,
                alreadyPending = pendingAudioFocusResumeSessionIds.contains(sessionId)
            )
        if (
            shouldTrackTransientAudioFocusPause(
                playWhenReady = playWhenReady,
                reason = reason,
                focusLossMayResume = transientAudioFocusLossActive,
                playbackSuspended = playbackSuspended
            )
        ) {
            pendingAudioFocusResumeSessionIds.add(sessionId)
        } else if (!preservePendingTransientFocusResume) {
            pendingAudioFocusResumeSessionIds.remove(sessionId)
        }
        logInfo(
            "player_play_when_ready_changed playWhenReady=$playWhenReady " +
                "reason=${playWhenReadyReasonName(reason)}",
            sessions[sessionId]
        )
        publishSessionState(sessionId)
        schedulePersistSessionState()
        syncForegroundState()
    }

    private fun handleIsPlayingChanged(sessionId: String, isPlaying: Boolean) {
        logInfo("player_is_playing_changed isPlaying=$isPlaying", sessions[sessionId])
        if (isPlaying) clearPlaybackRecovery(sessionId)
        publishSessionState(sessionId)
        schedulePersistSessionState()
        syncForegroundState()
    }

    private fun handlePlayerError(sessionId: String, error: PlaybackException) {
        pendingAudioFocusResumeSessionIds.remove(sessionId)
        val attempts = errorRetryAttempts.getOrDefault(sessionId, 0)
        val recoverable = isRecoverablePlaybackErrorCode(error.errorCode)
        val intended = intendedPlaybackSessionIds.contains(sessionId)
        logWarn(
            "player_error code=${error.errorCodeName} message=${error.message} " +
                "cause=${error.cause?.javaClass?.simpleName}:${error.cause?.message} " +
                "retryAttempt=$attempts recoverable=$recoverable intended=$intended",
            sessions[sessionId],
            error
        )
        publishSessionState(sessionId)
        persistSessionStateNow()
        if (recoverable && intended) {
            pendingRecoverySessionIds.add(sessionId)
            ensurePlaybackRecoveryCallbacks()
            scheduleRecoveryExpiry(sessionId)
            scheduleErrorRetry(sessionId, attempts)
        } else {
            clearPlaybackIntent(sessionId)
        }
        syncForegroundState()
    }

    private fun scheduleErrorRetry(sessionId: String, attempts: Int) {
        errorRetryRunnables.remove(sessionId)?.let(mainHandler::removeCallbacks)
        val startedAt = recoveryStartedElapsedRealtimeMs.getOrPut(sessionId) {
            SystemClock.elapsedRealtime()
        }
        val delayMs = playbackRecoveryDelayMs(
            attempt = attempts,
            recoveryStartedElapsedRealtimeMs = startedAt,
            nowElapsedRealtimeMs = SystemClock.elapsedRealtime()
        ) ?: run {
            logInfo("player_error_retry_waiting_for_trigger sessionId=$sessionId attempts=$attempts")
            return
        }
        errorRetryAttempts[sessionId] = attempts + 1
        val runnable = Runnable {
            errorRetryRunnables.remove(sessionId)
            retryPlaybackAfterError(sessionId, "scheduled_retry")
        }
        errorRetryRunnables[sessionId] = runnable
        logInfo(
            "player_error_retry_scheduled sessionId=$sessionId " +
                "delay=${delayMs}ms attempt=${attempts + 1}"
        )
        mainHandler.postDelayed(runnable, delayMs)
    }

    private fun retryPlaybackAfterError(sessionId: String, trigger: String) {
        val session = sessions[sessionId] ?: run {
            clearPlaybackRecovery(sessionId)
            return
        }
        if (!intendedPlaybackSessionIds.contains(sessionId)) {
            clearPlaybackRecovery(sessionId)
            return
        }
        val player = session.playerOrNull()
        if (player != null && player.isPlaying && player.playerError == null) {
            clearPlaybackRecovery(sessionId)
            return
        }
        errorRetryRunnables.remove(sessionId)?.let(mainHandler::removeCallbacks)
        logInfo("player_error_retry_executing sessionId=$sessionId trigger=$trigger")
        try {
            focusSession(sessionId)
            session.applyFadeMultiplier(1f)
            session.reprepareCurrentMediaItem()
            ensureFocusedPlayer(session).play()
            publishSessionState(sessionId)
            schedulePersistSessionState()
            syncForegroundState()
        } catch (e: Exception) {
            logWarn(
                "player_error_retry_failed sessionId=$sessionId trigger=$trigger",
                session,
                e as? PlaybackException
            )
            scheduleErrorRetry(sessionId, errorRetryAttempts.getOrDefault(sessionId, 0))
            syncForegroundState()
        }
    }

    private fun focusSession(sessionId: String) {
        val session = sessions[sessionId] ?: return
        session.lastUsedMs = System.currentTimeMillis()
        if (focusedSessionId == sessionId) return
        focusedSessionId = sessionId
        updateMediaSessionPlayer()
    }

    private fun ensureMediaSession(): MediaSession? {
        val session = mediaSessionCandidate()
        val player = session?.playerOrNull() ?: return mediaSession
        mediaSession?.let { existingSession ->
            if (existingSession.player !== player) {
                logInfo("media_session_switch_player", session)
                existingSession.player = player
            }
            return existingSession
        }
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = launchIntent?.let {
            val pendingIntentFlags = PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
            PendingIntent.getActivity(this, 0, it, pendingIntentFlags)
        }
        val builder = MediaSession.Builder(this, player)
            .setId("Nameless Audio")
        if (pendingIntent != null) {
            builder.setSessionActivity(pendingIntent)
        }
        return builder.build()
            .also {
                mediaSession = it
                logInfo("media_session_create", session)
            }
    }

    private fun updateMediaSessionPlayer() {
        val nextPlayer = mediaSessionCandidate()?.playerOrNull()
        val existingSession = mediaSession
        if (nextPlayer == null) {
            if (sessions.isEmpty()) {
                releaseMediaSession("no_media_session_candidate")
            }
            return
        }
        if (existingSession == null) {
            ensureMediaSession()
            return
        }
        if (existingSession.player !== nextPlayer) {
            logInfo("media_session_switch_player")
            existingSession.player = nextPlayer
            dummyPlayer?.release()
            dummyPlayer = null
        }
    }

    private fun ensureFocusedPlayer(session: NativePlaybackSession): ExoPlayer {
        val player = session.ensurePlayer()
        ensureFocusedMediaSession()
        return player
    }

    private fun ensureFocusedMediaSession(): MediaSession? {
        updateMediaSessionPlayer()
        return ensureMediaSession()
    }

    private fun mediaSessionCandidate(): NativePlaybackSession? {
        sessions[focusedSessionId]?.takeIf { it.playerOrNull() != null }?.let {
            return it
        }
        return sessions.values.firstOrNull { it.playerOrNull() != null }
    }

    private fun releaseMediaSession(reason: String) {
        val existingSession = mediaSession ?: return
        logInfo("media_session_release reason=$reason")
        existingSession.release()
        mediaSession = null
        dummyPlayer?.release()
        dummyPlayer = null
    }

    private fun hasActivePlayback(): Boolean {
        return sessions.values.any { 
            val p = it.playerOrNull()
            p != null && (p.isPlaying || p.playWhenReady)
        }
    }

    private fun markPlaybackIntended(sessionId: String) {
        intendedPlaybackSessionIds.add(sessionId)
    }

    private fun clearPlaybackIntent(sessionId: String) {
        intendedPlaybackSessionIds.remove(sessionId)
        clearPlaybackRecovery(sessionId)
    }

    private fun scheduleRecoveryExpiry(sessionId: String) {
        if (recoveryExpiryRunnables.containsKey(sessionId)) return
        val startedAt = recoveryStartedElapsedRealtimeMs.getOrPut(sessionId) {
            SystemClock.elapsedRealtime()
        }
        val delayMs = (
            startedAt + PLAYBACK_RECOVERY_WINDOW_MS - SystemClock.elapsedRealtime()
        ).coerceAtLeast(0L)
        val runnable = Runnable {
            recoveryExpiryRunnables.remove(sessionId)
            if (!pendingRecoverySessionIds.contains(sessionId)) return@Runnable
            logInfo("playback_recovery_expired sessionId=$sessionId")
            clearPlaybackIntent(sessionId)
            publishSessionState(sessionId)
            persistSessionStateNow()
            syncForegroundState()
        }
        recoveryExpiryRunnables[sessionId] = runnable
        mainHandler.postDelayed(runnable, delayMs)
    }

    private fun clearPlaybackRecovery(sessionId: String) {
        pendingRecoverySessionIds.remove(sessionId)
        errorRetryAttempts.remove(sessionId)
        recoveryStartedElapsedRealtimeMs.remove(sessionId)
        errorRetryRunnables.remove(sessionId)?.let(mainHandler::removeCallbacks)
        recoveryExpiryRunnables.remove(sessionId)?.let(mainHandler::removeCallbacks)
        if (pendingRecoverySessionIds.isEmpty()) {
            unregisterPlaybackRecoveryCallbacks()
        }
    }

    private fun clearAllPlaybackRecovery() {
        errorRetryRunnables.values.forEach(mainHandler::removeCallbacks)
        recoveryExpiryRunnables.values.forEach(mainHandler::removeCallbacks)
        errorRetryRunnables.clear()
        recoveryExpiryRunnables.clear()
        errorRetryAttempts.clear()
        recoveryStartedElapsedRealtimeMs.clear()
        pendingRecoverySessionIds.clear()
        unregisterPlaybackRecoveryCallbacks()
    }

    private fun ensurePlaybackRecoveryCallbacks() {
        if (pendingRecoverySessionIds.isEmpty()) return
        registerScreenOnRecoveryReceiver()
        registerNetworkRecoveryCallback()
    }

    private fun registerScreenOnRecoveryReceiver() {
        if (screenOnReceiverRegistered) return
        try {
            ContextCompat.registerReceiver(
                this,
                screenOnReceiver,
                IntentFilter(Intent.ACTION_SCREEN_ON),
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
            screenOnReceiverRegistered = true
        } catch (e: Exception) {
            logWarn("screen_on_recovery_receiver_register_failed", error = e)
        }
    }

    private fun registerNetworkRecoveryCallback() {
        if (recoveryNetworkCallback != null) return
        val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                mainHandler.post { handleRecoveryNetworkAvailabilityChanged(manager) }
            }

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities
            ) {
                mainHandler.post { handleRecoveryNetworkAvailabilityChanged(manager) }
            }

            override fun onLost(network: Network) {
                mainHandler.post { handleRecoveryNetworkAvailabilityChanged(manager) }
            }
        }
        try {
            recoveryNetworkAvailable = isValidatedNetworkAvailable(manager)
            manager.registerNetworkCallback(
                NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .build(),
                callback
            )
            recoveryNetworkCallback = callback
        } catch (e: Exception) {
            logWarn("network_recovery_callback_register_failed", error = e)
        }
    }

    private fun unregisterPlaybackRecoveryCallbacks() {
        recoveryNetworkCallback?.let { callback ->
            try {
                (getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager)
                    ?.unregisterNetworkCallback(callback)
            } catch (e: Exception) {
                logWarn("network_recovery_callback_unregister_failed", error = e)
            }
        }
        recoveryNetworkCallback = null
        recoveryNetworkAvailable = false
        if (screenOnReceiverRegistered) {
            try {
                unregisterReceiver(screenOnReceiver)
            } catch (e: Exception) {
                logWarn("screen_on_recovery_receiver_unregister_failed", error = e)
            }
            screenOnReceiverRegistered = false
        }
    }

    private fun handleRecoveryNetworkAvailabilityChanged(manager: ConnectivityManager) {
        val available = isValidatedNetworkAvailable(manager)
        val becameAvailable = !recoveryNetworkAvailable && available
        recoveryNetworkAvailable = available
        if (becameAvailable) {
            handlePlaybackRecoveryTrigger("network_available")
        }
    }

    private fun isValidatedNetworkAvailable(manager: ConnectivityManager): Boolean {
        val capabilities = manager.getNetworkCapabilities(manager.activeNetwork) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    private fun handlePlaybackRecoveryTrigger(trigger: String) {
        if (pendingRecoverySessionIds.isEmpty()) {
            recoverIntendedPlaybackIfStalled(trigger)
            return
        }
        logInfo(
            "playback_recovery_trigger trigger=$trigger " +
                "pending=${pendingRecoverySessionIds.size}"
        )
        pendingRecoverySessionIds.toList().forEach { sessionId ->
            retryPlaybackAfterError(sessionId, trigger)
        }
        recoverIntendedPlaybackIfStalled(trigger)
    }

    private fun hasPendingAudioFocusResume(): Boolean {
        return pendingAudioFocusResumeSessionIds.any(sessions::containsKey)
    }

    private fun hasIntendedPlaybackToRecover(): Boolean {
        return intendedPlaybackSessionIds.any { sessionId ->
            val session = sessions[sessionId] ?: return@any false
            val player = session.playerOrNull() ?: return@any true
            shouldKeepAliveForIntendedPlayback(
                playbackState = player.playbackState,
                hasPlayerError = player.playerError != null,
                hasRecoverablePlaybackError = pendingRecoverySessionIds.contains(sessionId)
            )
        }
    }

    private fun hasPlaybackToKeepAlive(): Boolean {
        return hasActivePlayback() ||
            hasPendingAudioFocusResume() ||
            hasIntendedPlaybackToRecover() ||
            pendingRecoverySessionIds.any(sessions::containsKey)
    }

    private fun recoverIntendedPlaybackIfStalled(trigger: String) {
        val sessionIds = intendedPlaybackSessionIds.toList()
        if (sessionIds.isEmpty()) return

        var recoveredAny = false
        sessionIds.forEach { sessionId ->
            val session = sessions[sessionId] ?: run {
                intendedPlaybackSessionIds.remove(sessionId)
                return@forEach
            }
            val player = session.playerOrNull()
            if (player == null) {
                if (session.uri == null) {
                    intendedPlaybackSessionIds.remove(sessionId)
                    return@forEach
                }
                logInfo("recover_intended_playback trigger=$trigger recreate_player", session)
                focusSession(sessionId)
                session.applyFadeMultiplier(1f)
                ensureFocusedPlayer(session).play()
                recoveredAny = true
                return@forEach
            }
            if (pendingRecoverySessionIds.contains(sessionId)) {
                return@forEach
            }
            if ((player.isPlaying || player.playWhenReady) && player.playerError == null) {
                return@forEach
            }
            if (!shouldRecoverIntendedPlayback(
                    playbackState = player.playbackState,
                    hasPlayerError = player.playerError != null,
                    hasRecoverablePlaybackError = pendingRecoverySessionIds.contains(sessionId)
                )
            ) {
                if (player.playbackState == Player.STATE_ENDED) {
                    intendedPlaybackSessionIds.remove(sessionId)
                }
                return@forEach
            }
            logInfo(
                "recover_intended_playback trigger=$trigger " +
                    "state=${playbackStateName(player.playbackState)}",
                session
            )
            focusSession(sessionId)
            session.applyFadeMultiplier(1f)
            if (player.playbackState == Player.STATE_IDLE || player.playerError != null) {
                session.reprepareCurrentMediaItem()
            }
            ensureFocusedPlayer(session).play()
            recoveredAny = true
        }

        if (recoveredAny) {
            publishAllSessionStates()
            schedulePersistSessionState()
        }
    }

    private fun syncForegroundState() {
        if (hasPlaybackToKeepAlive()) {
            // Playback is active 鈥?cancel any pending grace-period stop and
            // make sure the foreground service + wake lock are held.
            cancelForegroundStopGrace()
            acquireWakeLock()
            requestAudioFocusIfNeeded()
            if (resumePendingAudioFocusSessionsIfPossible("foreground_sync_focus_available")) {
                schedulePersistSessionState()
            }
            recoverIntendedPlaybackIfStalled("foreground_sync")
            startPlaybackForeground()
            ensureForegroundWatchdog()
            ensureStatePersistenceTicker()
        } else if (foregroundSuppressed) {
            // Foreground is intentionally suppressed (notification control
            // disabled). No foreground service to stop, just release resources.
            cancelForegroundStopGrace()
            abandonAudioFocus(reason = "suppressed_no_active_playback")
            releaseWakeLock()
            persistSessionStateNow()
        } else {
            // Playback is not active right now, but it may be a transient gap
            // (track transition, buffering, seek).  Schedule a grace-period
            // stop instead of releasing resources immediately.  If playback
            // resumes within the window the grace runnable will be cancelled.
            scheduleForegroundStopGrace()
        }
    }

    private fun scheduleForegroundStopGrace() {
        if (foregroundStopGracePending) return
        foregroundStopGracePending = true
        logInfo("foreground_stop_grace_scheduled delay=${PLAYBACK_STOP_GRACE_MS}ms")
        mainHandler.postDelayed(foregroundStopGraceRunnable, PLAYBACK_STOP_GRACE_MS)
    }

    private fun cancelForegroundStopGrace() {
        if (!foregroundStopGracePending) return
        mainHandler.removeCallbacks(foregroundStopGraceRunnable)
        foregroundStopGracePending = false
        logInfo("foreground_stop_grace_cancelled")
    }

    private fun startPlaybackForeground() {
        startPlaybackForeground(forceRefresh = false)
    }

    private fun startPlaybackForeground(forceRefresh: Boolean) {
        if (playbackSuspended) {
            logInfo("start_foreground_skip playback_suspended forceRefresh=$forceRefresh")
            return
        }
        if (foregroundSuppressed) {
            logInfo("start_foreground_minimal foreground_suppressed forceRefresh=$forceRefresh")
        }
        val foregroundSession = sessions[focusedSessionId]
            ?: sessions.values.firstOrNull { session ->
                val player = session.playerOrNull()
                player != null && (player.isPlaying || player.playWhenReady)
            }
            ?: sessions.values.firstOrNull()
            ?: run {
                logInfo("start_foreground_skip no_session")
                return
            }
        val mediaSession = ensureFocusedMediaSession()
        val usesUnifiedNotification =
            !notificationsDismissed &&
                !foregroundSuppressed &&
                UnifiedPlaybackNotificationController.hasUnifiedNotifications()
        val signature = if (usesUnifiedNotification) {
            "unified|$FOREGROUND_NOTIFICATION_ID"
        } else {
            foregroundSession.foregroundNotificationSignature()
        }
        if (!forceRefresh && playbackForegroundStarted && playbackForegroundSignature == signature) {
            logInfo("start_foreground_skip unchanged signature=$signature", foregroundSession)
            return
        }
        try {
            ServiceCompat.startForeground(
                this,
                FOREGROUND_NOTIFICATION_ID,
                foregroundNotificationFactory.buildPlaybackNotification(
                    title = foregroundSession.title,
                    subtitle = foregroundSession.subtitle,
                    mediaSession = mediaSession,
                    allowRichSummary = usesUnifiedNotification
                ),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
            playbackForegroundStarted = true
            playbackForegroundSignature = signature
            logInfo(
                "start_foreground_success forceRefresh=$forceRefresh " +
                    "notificationId=$FOREGROUND_NOTIFICATION_ID signature=$signature",
                foregroundSession
            )
        } catch (e: Exception) {
            logWarn(
                "start_foreground_failed forceRefresh=$forceRefresh " +
                    "notificationId=$FOREGROUND_NOTIFICATION_ID signature=$signature",
                foregroundSession,
                e
            )
            // Keep ExoPlayer and our wake lock alive best-effort if a device
            // rejects a foreground-service refresh from its current state.
        }
    }

    private fun startBootstrapForeground() {
        if (playbackForegroundStarted) {
            logInfo("start_bootstrap_foreground_skip already_started")
            return
        }
        try {
            ensureMediaSessionForBootstrap()
            ServiceCompat.startForeground(
                this,
                FOREGROUND_NOTIFICATION_ID,
                foregroundNotificationFactory.buildBootstrapNotification(
                    currentMediaSession()
                ),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
            playbackForegroundStarted = true
            playbackForegroundSignature = "bootstrap|$FOREGROUND_NOTIFICATION_ID"
            acquireWakeLock()
            logInfo("start_bootstrap_foreground_success notificationId=$FOREGROUND_NOTIFICATION_ID")
        } catch (e: Exception) {
            logWarn(
                "start_bootstrap_foreground_failed notificationId=$FOREGROUND_NOTIFICATION_ID",
                error = e
            )
            // If the bootstrap foreground notification is rejected, the alarm
            // receiver still retries delivery while its async result is alive.
        }
    }

    private fun stopPlaybackForeground(
        reason: String,
        removeNotification: Boolean = true
    ) {
        val shouldRemoveNotification =
            UnifiedPlaybackNotificationController.shouldRemoveForegroundNotification(
                removeNotification
            )
        logInfo(
            "stop_foreground reason=$reason removeNotification=$removeNotification " +
                "shouldRemoveNotification=$shouldRemoveNotification " +
                "wasStarted=$playbackForegroundStarted"
        )
        if (playbackForegroundStarted) {
            stopForegroundCompat(removeNotification = shouldRemoveNotification)
        }
        playbackForegroundStarted = false
        playbackForegroundSignature = null
        if (shouldRemoveNotification) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            manager?.cancel(FOREGROUND_NOTIFICATION_ID)
        }
    }

    private fun stopForegroundCompat(removeNotification: Boolean) {
        val behavior = if (removeNotification) {
            STOP_FOREGROUND_REMOVE
        } else {
            STOP_FOREGROUND_DETACH
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(behavior)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(removeNotification)
        }
    }

    private fun ensureForegroundWatchdog() {
        if (foregroundWatchdogScheduled) return
        foregroundWatchdogScheduled = true
        mainHandler.postDelayed(foregroundWatchdog, FOREGROUND_WATCHDOG_INTERVAL_MS)
    }

    private fun stopForegroundWatchdog() {
        if (!foregroundWatchdogScheduled) return
        mainHandler.removeCallbacks(foregroundWatchdog)
        foregroundWatchdogScheduled = false
    }

    private fun ensureStatePersistenceTicker() {
        statePersistence.ensureTicker()
    }

    private fun stopStatePersistenceTicker() {
        statePersistence.stopTicker()
    }

    private fun schedulePersistSessionState() {
        statePersistence.schedulePersist()
    }

    private fun cancelScheduledPersistSessionState() {
        statePersistence.cancelScheduledPersist()
    }

    private fun persistSessionStateNow() {
        statePersistence.persistNow()
    }

    private fun restorePersistedPlaybackAfterServiceRestart() {
        val storedSessions = NativePlaybackStateStore.loadSessions(this)
            .filter { it.playing || it.playWhenReady }
        if (storedSessions.isEmpty()) {
            logInfo("sticky_restore_skip no_active_sessions")
            return
        }

        logInfo("sticky_restore_begin sessionCount=${storedSessions.size}")
        startBootstrapForeground()
        notificationsDismissed = false
        playbackSuspended = false

        val restoredSessionIds = sessionRestorer.restore(
            storedSessions = storedSessions,
            autoPlay = { stored -> stored.playWhenReady || stored.playing }
        )

        if (restoredSessionIds.isEmpty()) {
            logInfo("sticky_restore_skip restore_failed")
            releaseWakeLock()
            stopPlaybackForeground(
                reason = "sticky_restore_failed",
                removeNotification = true
            )
            return
        }

        restoredSessionIds.forEach(::markPlaybackIntended)
        evictPlayersIfNeeded()
        restoredSessionIds.forEach(::publishSessionState)
        ensureTicker()
        ensureStatePersistenceTicker()
        persistSessionStateNow()
        syncForegroundState()
        logInfo("sticky_restore_complete restored=${restoredSessionIds.size}")
    }

    private fun restorePersistedSessionsForTimer(sessionIds: List<String>) {
        val missingSessionIds = sessionIds.filterNot { sessions.containsKey(it) }.toSet()
        if (missingSessionIds.isEmpty()) return
        sessionRestorer.restore(
            storedSessions = NativePlaybackStateStore.loadSessions(this)
                .filter { it.sessionId in missingSessionIds },
            autoPlay = { false },
            onRestored = ::publishSessionState
        )
        evictPlayersIfNeeded()
        persistSessionStateNow()
    }

    private fun restorePersistedSessionForNotification(
        sessionId: String,
        loadedSessions: List<StoredNativePlaybackSession>
    ) {
        if (sessions.containsKey(sessionId)) return
        sessionRestorer.restore(
            storedSessions = loadedSessions.filter { it.sessionId == sessionId },
            autoPlay = { false },
            onRestored = ::publishSessionState
        )
    }

    private fun requestAudioFocusIfNeeded() {
        if (audioFocusHeld) return
        val manager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: run {
            logInfo("audio_focus_request_skip no_audio_manager")
            return
        }
        val result = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request = audioFocusRequest ?: AudioFocusRequest.Builder(
                    AudioManager.AUDIOFOCUS_GAIN
                )
                    .setAudioAttributes(
                        AndroidAudioAttributes.Builder()
                            .setUsage(AndroidAudioAttributes.USAGE_MEDIA)
                            .setContentType(AndroidAudioAttributes.CONTENT_TYPE_MUSIC)
                            .build()
                    )
                    .setAcceptsDelayedFocusGain(false)
                    .setWillPauseWhenDucked(false)
                    .setOnAudioFocusChangeListener(audioFocusChangeListener, mainHandler)
                    .build()
                    .also { audioFocusRequest = it }
                manager.requestAudioFocus(request)
            } else {
                @Suppress("DEPRECATION")
                manager.requestAudioFocus(
                    audioFocusChangeListener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN
                )
            }
        } catch (e: RuntimeException) {
            logWarn("audio_focus_request_failed", error = e)
            AudioManager.AUDIOFOCUS_REQUEST_FAILED
        }
        audioFocusHeld = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        logInfo(
            "audio_focus_request_result result=${audioFocusRequestResultName(result)} " +
                "held=$audioFocusHeld"
        )
    }

    private fun resumePendingAudioFocusSessionsIfPossible(trigger: String): Boolean {
        if (!shouldResumePendingAudioFocusPause(
                audioFocusHeld = audioFocusHeld,
                hasPendingAudioFocusResume = hasPendingAudioFocusResume(),
                playbackSuspended = playbackSuspended
            )
        ) {
            return false
        }
        val sessionIdsToResume = pendingAudioFocusResumeSessionIds
            .filter(sessions::containsKey)
        pendingAudioFocusResumeSessionIds.clear()
        if (sessionIdsToResume.isEmpty()) return false
        logInfo(
            "audio_focus_pending_resume trigger=$trigger " +
                "sessionCount=${sessionIdsToResume.size}"
        )
        sessionIdsToResume.forEach { sessionId ->
            val session = sessions[sessionId] ?: return@forEach
            focusSession(sessionId)
            ensureFocusedPlayer(session).play()
        }
        publishAllSessionStates()
        ensureTicker()
        return true
    }

    private fun abandonAudioFocus(reason: String) {
        if (!audioFocusHeld && audioFocusRequest == null) return
        val manager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: run {
            logInfo("audio_focus_abandon_skip no_audio_manager reason=$reason")
            audioFocusHeld = false
            return
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest?.let(manager::abandonAudioFocusRequest)
            } else {
                @Suppress("DEPRECATION")
                manager.abandonAudioFocus(audioFocusChangeListener)
            }
            logInfo("audio_focus_abandoned reason=$reason")
        } catch (e: RuntimeException) {
            logWarn("audio_focus_abandon_failed reason=$reason", error = e)
        } finally {
            audioFocusHeld = false
        }
    }

    private fun acquireWakeLock() {
        playbackWakeLock.acquire()
    }

    private fun releaseWakeLock() {
        playbackWakeLock.release()
    }

    private fun logInfo(message: String, session: NativePlaybackSession? = null) {
        AppFileLogger.info(applicationContext, LOG_TAG, "$message ${playbackLogState(session)}")
    }

    private fun logWarn(
        message: String,
        session: NativePlaybackSession? = null,
        error: Throwable? = null
    ) {
        val fullMessage = "$message ${playbackLogState(session)}"
        if (error == null) {
            AppFileLogger.warn(applicationContext, LOG_TAG, fullMessage)
        } else {
            AppFileLogger.warn(applicationContext, LOG_TAG, fullMessage, error)
        }
    }

    private fun playbackLogState(session: NativePlaybackSession? = null): String {
        val target = session
            ?: sessions[focusedSessionId]
            ?: sessions.values.firstOrNull { candidate ->
                val player = candidate.playerOrNull()
                player != null && (player.isPlaying || player.playWhenReady)
            }
            ?: sessions.values.firstOrNull()
        val player = target?.playerOrNull()
        val title = target?.title
            ?.replace('\n', ' ')
            ?.replace('\r', ' ')
            ?.take(80)
            ?: "<none>"
        return "sessionId=${target?.sessionId ?: "<none>"} " +
            "title=\"$title\" " +
            "playWhenReady=${player?.playWhenReady ?: target?.lastPlayWhenReady} " +
            "isPlaying=${player?.isPlaying ?: target?.lastIsPlaying} " +
            "playbackState=${player?.playbackStateName() ?: target?.lastPlaybackState} " +
            "foregroundStarted=$playbackForegroundStarted " +
            "activePlayback=${hasActivePlayback()} " +
            "keepAlivePlayback=${hasPlaybackToKeepAlive()}"
    }

    private fun ensurePlaybackChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (manager.getNotificationChannel(PLAYBACK_CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            PLAYBACK_CHANNEL_ID,
            PLAYBACK_CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = PLAYBACK_CHANNEL_DESCRIPTION
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun publishSessionState(sessionId: String): Map<String, Any?>? {
        val session = sessions[sessionId] ?: return null
        return publishNativePlaybackSessionState(session, stateListeners.values)
    }

    private fun publishAllSessionStates() {
        sessions.keys.toList().forEach { publishSessionState(it) }
    }

    private fun publishProgressSessionStatesAsync(nowElapsedRealtimeMs: Long) {
        progressPublisher.publishAsync(nowElapsedRealtimeMs)
    }

    private fun ensureTicker() {
        if (tickerScheduled || stateListeners.isEmpty()) return
        tickerScheduled = true
        mainHandler.post(positionTicker)
    }

    private fun okResult(value: Any?): Map<String, Any?> {
        return mapOf("ok" to true, "value" to value)
    }

    private fun errorResult(message: String): Map<String, Any?> {
        return mapOf("ok" to false, "error" to message)
    }


}

internal fun resolveNotificationSessionId(
    requestedSessionId: String,
    focusedSessionId: String?,
    activeSessionIds: Collection<String>,
    existingSessionIds: Collection<String>,
    storedActiveSessionIds: Collection<String>,
    storedSessionIds: Collection<String>
): String {
    return requestedSessionId.ifBlank {
        focusedSessionId
            ?: activeSessionIds.firstOrNull()
            ?: existingSessionIds.firstOrNull()
            ?: storedActiveSessionIds.firstOrNull()
            ?: storedSessionIds.firstOrNull()
            ?: ""
    }
}

private fun playWhenReadyReasonName(reason: Int): String {
    return when (reason) {
        Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST -> "user_request"
        Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS -> "audio_focus_loss"
        Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY -> "audio_becoming_noisy"
        Player.PLAY_WHEN_READY_CHANGE_REASON_REMOTE -> "remote"
        Player.PLAY_WHEN_READY_CHANGE_REASON_END_OF_MEDIA_ITEM -> "end_of_media_item"
        else -> "unknown($reason)"
    }
}

internal fun shouldTrackTransientAudioFocusPause(
    playWhenReady: Boolean,
    reason: Int,
    focusLossMayResume: Boolean,
    playbackSuspended: Boolean
): Boolean {
    return !playWhenReady &&
        reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS &&
        focusLossMayResume &&
        !playbackSuspended
}

internal fun shouldPauseForAudioFocusChange(change: Int): Boolean {
    return change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT
}

internal fun shouldPreservePendingAudioFocusResume(
    playWhenReady: Boolean,
    focusLossMayResume: Boolean,
    alreadyPending: Boolean
): Boolean {
    return !playWhenReady && focusLossMayResume && alreadyPending
}

internal fun shouldResumePendingAudioFocusPause(
    audioFocusHeld: Boolean,
    hasPendingAudioFocusResume: Boolean,
    playbackSuspended: Boolean
): Boolean {
    return audioFocusHeld &&
        hasPendingAudioFocusResume &&
        !playbackSuspended
}

private fun audioFocusChangeName(change: Int): String {
    return when (change) {
        AudioManager.AUDIOFOCUS_GAIN -> "gain"
        AudioManager.AUDIOFOCUS_LOSS -> "loss"
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> "loss_transient"
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> "loss_transient_can_duck"
        else -> "unknown($change)"
    }
}

private fun audioFocusRequestResultName(result: Int): String {
    return when (result) {
        AudioManager.AUDIOFOCUS_REQUEST_GRANTED -> "granted"
        AudioManager.AUDIOFOCUS_REQUEST_FAILED -> "failed"
        AudioManager.AUDIOFOCUS_REQUEST_DELAYED -> "delayed"
        else -> "unknown($result)"
    }
}

internal fun shouldAttemptStickyPlaybackRestore(
    hasSessions: Boolean,
    attemptedStickyPlaybackRestore: Boolean
): Boolean {
    return !hasSessions && !attemptedStickyPlaybackRestore
}

internal fun shouldKeepAliveForIntendedPlayback(
    playbackState: Int,
    hasPlayerError: Boolean,
    hasRecoverablePlaybackError: Boolean = false
): Boolean {
    return playbackState != Player.STATE_ENDED &&
        (!hasPlayerError || hasRecoverablePlaybackError)
}

internal fun shouldRecoverIntendedPlayback(
    playbackState: Int,
    hasPlayerError: Boolean,
    hasRecoverablePlaybackError: Boolean = false
): Boolean {
    return shouldKeepAliveForIntendedPlayback(
        playbackState = playbackState,
        hasPlayerError = hasPlayerError,
        hasRecoverablePlaybackError = hasRecoverablePlaybackError
    )
}

internal fun playbackRecoveryDelayMs(
    attempt: Int,
    recoveryStartedElapsedRealtimeMs: Long,
    nowElapsedRealtimeMs: Long
): Long? {
    val offsetMs = playbackRecoveryOffsetsMs.getOrNull(attempt) ?: return null
    return (recoveryStartedElapsedRealtimeMs + offsetMs - nowElapsedRealtimeMs)
        .coerceAtLeast(0L)
}

internal fun isRecoverablePlaybackErrorCode(errorCode: Int): Boolean {
    return when (errorCode) {
        PlaybackException.ERROR_CODE_IO_UNSPECIFIED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
        PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
        PlaybackException.ERROR_CODE_AUDIO_TRACK_INIT_FAILED,
        PlaybackException.ERROR_CODE_AUDIO_TRACK_WRITE_FAILED -> true
        else -> false
    }
}
