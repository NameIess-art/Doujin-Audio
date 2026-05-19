package com.nameless.audio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes as AndroidAudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.audiofx.LoudnessEnhancer
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.audio.ChannelMappingAudioProcessor
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import java.util.concurrent.ConcurrentHashMap

private data class NativeMediaItemDescriptor(
    val path: String,
    val uri: String,
    val title: String,
    val subtitle: String?,
    val artUri: String?
)

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
        private const val MAX_ACTIVE_PLAYERS = 10
        // Grace period before releasing the wake lock / stopping foreground after
        // playback appears to have stopped. Covers brief gaps during track
        // transitions and buffering so that aggressive OEM battery managers
        // cannot kill the service in that window.
        private const val PLAYBACK_STOP_GRACE_MS = 5_000L
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
    private val stateListeners = ConcurrentHashMap<String, (Map<String, Any?>) -> Unit>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var mediaSession: MediaSession? = null
    private var focusedSessionId: String? = null
    private var tickerScheduled = false
    private var foregroundWatchdogScheduled = false
    private var statePersistenceScheduled = false
    private var playbackSuspended = false
    private var playbackForegroundStarted = false
    private var playbackForegroundSignature: String? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var audioFocusHeld = false
    private var transientAudioFocusLossActive = false
    private val pendingAudioFocusResumeSessionIds = linkedSetOf<String>()
    private var attemptedStickyPlaybackRestore = false
    private var pendingPersistScheduled = false
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
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                audioFocusHeld = false
                transientAudioFocusLossActive = true
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                audioFocusHeld = true
                val sessionIdsToResume = pendingAudioFocusResumeSessionIds
                    .filter(sessions::containsKey)
                pendingAudioFocusResumeSessionIds.clear()
                transientAudioFocusLossActive = false
                if (sessionIdsToResume.isNotEmpty() && !playbackSuspended) {
                    logInfo("audio_focus_gain_resume sessionCount=${sessionIdsToResume.size}")
                    sessionIdsToResume.forEach { sessionId ->
                        val session = sessions[sessionId] ?: return@forEach
                        focusSession(sessionId)
                        session.ensurePlayer().play()
                    }
                    publishAllSessionStates()
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
    private val positionTicker = object : Runnable {
        override fun run() {
            if (stateListeners.isEmpty() || sessions.isEmpty()) {
                tickerScheduled = false
                return
            }
            publishAllSessionStates()
            mainHandler.postDelayed(this, 750L)
        }
    }
    private val foregroundWatchdog = object : Runnable {
        override fun run() {
            if (!hasPlaybackToKeepAlive()) {
                // Don't stop the watchdog immediately — a grace-period stop may
                // already be pending.  Just reschedule; the grace runnable will
                // clean up if playback truly stopped.
                mainHandler.postDelayed(this, FOREGROUND_WATCHDOG_INTERVAL_MS)
                return
            }
            startPlaybackForeground(forceRefresh = true)
            mainHandler.postDelayed(this, FOREGROUND_WATCHDOG_INTERVAL_MS)
        }
    }
    private val statePersistenceTicker = object : Runnable {
        override fun run() {
            persistSessionStateNow()
            if (sessions.isEmpty()) {
                statePersistenceScheduled = false
                return
            }
            mainHandler.postDelayed(this, STATE_PERSISTENCE_INTERVAL_MS)
        }
    }
    private val persistSessionStateRunnable = Runnable {
        pendingPersistScheduled = false
        persistSessionStateNow()
    }

    override fun onCreate() {
        super.onCreate()
        ensurePlaybackChannel()
        instance = this
        logInfo("on_create")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        if (intent == null &&
            sessions.isEmpty() &&
            !attemptedStickyPlaybackRestore
        ) {
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
            // Do NOT call stopSelf() — let the grace-period runnable decide.
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
                "foregroundStarted=$playbackForegroundStarted wakeLockHeld=${wakeLock?.isHeld == true}"
        )
        stateListeners.clear()
        mainHandler.removeCallbacks(positionTicker)
        stopStatePersistenceTicker()
        cancelScheduledPersistSessionState()
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
        stateListeners[ownerId] = listener
        sessions.values.forEach { listener(it.snapshot()) }
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
        val repeatOne = args["repeatOne"] as? Boolean ?: false
        val queue = parseQueue(args["queue"]).ifEmpty {
            listOf(NativeMediaItemDescriptor(path, uri, title, subtitle, artUri))
        }
        val queueStartIndex = ((args["queueStartIndex"] as? Number)?.toInt() ?: 0)
            .coerceIn(0, queue.lastIndex)
        val repeatAll = args["repeatAll"] as? Boolean ?: false
        val shuffle = args["shuffle"] as? Boolean ?: false
        if (autoPlay) {
            notificationsDismissed = false
            playbackSuspended = false
        }

        val nativeSession = sessions.getOrPut(sessionId) { NativePlaybackSession(sessionId) }
        pendingAudioFocusResumeSessionIds.remove(sessionId)
        return try {
            nativeSession.configure(
                descriptor = queue[queueStartIndex],
                queue = queue,
                queueStartIndex = queueStartIndex,
                startPositionMs = startPositionMs,
                volume = volume,
                repeatOne = repeatOne,
                repeatAll = repeatAll,
                shuffleModeEnabled = shuffle,
                autoPlay = autoPlay
            )
            focusSession(sessionId)
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

    fun play(sessionId: String): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.lastUsedMs = System.currentTimeMillis()
        pendingAudioFocusResumeSessionIds.remove(sessionId)
        notificationsDismissed = false
        playbackSuspended = false
        focusSession(sessionId)
        session.ensurePlayer().play()
        evictPlayersIfNeeded()
        publishSessionState(sessionId)
        ensureTicker()
        persistSessionStateNow()
        ensureStatePersistenceTicker()
        syncForegroundState()
        return okResult(session.snapshot())
    }

    fun pause(sessionId: String): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.lastUsedMs = System.currentTimeMillis()
        pendingAudioFocusResumeSessionIds.remove(sessionId)
        session.playerOrNull()?.pause()
        publishSessionState(sessionId)
        persistSessionStateNow()
        syncForegroundState()
        return okResult(session.snapshot())
    }

    fun stop(sessionId: String): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.lastUsedMs = System.currentTimeMillis()
        pendingAudioFocusResumeSessionIds.remove(sessionId)
        val player = session.playerOrNull()
        player?.stop()
        player?.clearMediaItems()
        publishSessionState(sessionId)
        persistSessionStateNow()
        syncForegroundState()
        return okResult(session.snapshot())
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

    fun setRepeatOne(
        sessionId: String,
        repeatOne: Boolean,
        args: Map<String, Any?> = emptyMap()
    ): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.lastUsedMs = System.currentTimeMillis()
        session.repeatOne = repeatOne
        val queue = parseQueue(args["queue"])
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
        sessions.values.forEach { it.playerOrNull()?.pause() }
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
            sessions[sessionId]?.playerOrNull()?.pause()
        }
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
            focusSession(sessionId)
            session.ensurePlayer().play()
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

    fun setChannelSwap(sessionId: String, enabled: Boolean): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.lastUsedMs = System.currentTimeMillis()
        session.channelSwapEnabled = enabled
        session.applyChannelMap()
        session.reprepareCurrentMediaItem()
        publishSessionState(sessionId)
        schedulePersistSessionState()
        syncForegroundState()
        return okResult(session.snapshot())
    }

    private fun evictPlayersIfNeeded() {
        val sessionsWithPlayers = sessions.values.filter { it.hasPlayer() }
        if (sessionsWithPlayers.size <= MAX_ACTIVE_PLAYERS) return

        // Evict sessions that are NOT playing and were used longest ago
        val evictable = sessionsWithPlayers
            .filter { !it.isPlaying() }
            .sortedBy { it.lastUsedMs }

        var countToEvict = sessionsWithPlayers.size - MAX_ACTIVE_PLAYERS
        for (session in evictable) {
            if (countToEvict <= 0) break
            // Never evict the focused session if it's potentially visible
            if (session.sessionId == focusedSessionId) continue
            
            session.releasePlayer()
            countToEvict--
        }
    }

    private fun parseQueue(rawQueue: Any?): List<NativeMediaItemDescriptor> {
        val queue = rawQueue as? List<*> ?: return emptyList()
        return queue.mapNotNull { rawItem ->
            val item = rawItem as? Map<*, *> ?: return@mapNotNull null
            val uri = item["uri"] as? String ?: return@mapNotNull null
            val path = item["path"] as? String ?: uri
            val title = item["title"] as? String ?: "Audio"
            NativeMediaItemDescriptor(
                path = path,
                uri = uri,
                title = title,
                subtitle = item["subtitle"] as? String,
                artUri = item["artUri"] as? String
            )
        }
    }

    private fun createPlayer(
        sessionId: String,
        channelMappingAudioProcessor: ChannelMappingAudioProcessor
    ): ExoPlayer {
        val renderersFactory = object : DefaultRenderersFactory(this) {
            override fun buildAudioSink(
                context: Context,
                enableFloatOutput: Boolean,
                enableAudioTrackPlaybackParams: Boolean
            ) = DefaultAudioSink.Builder(context)
                .setAudioProcessors(arrayOf(channelMappingAudioProcessor))
                .setEnableFloatOutput(enableFloatOutput)
                .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
                .build()
        }

        return ExoPlayer.Builder(this, renderersFactory).build().also { player ->
            // WAKE_MODE_NETWORK keeps the CPU and WiFi lock while ExoPlayer is
            // actively decoding, covering both local files and network streams.
            player.setWakeMode(C.WAKE_MODE_NETWORK)
            // Disable ExoPlayer's built-in audio focus management.  We manage
            // focus ourselves via audioFocusChangeListener so that transient
            // focus losses (e.g. OEM screen-off sounds) do not pause playback.
            player.setAudioAttributes(
                androidx.media3.common.AudioAttributes.Builder()
                    .setUsage(androidx.media3.common.C.USAGE_MEDIA)
                    .setContentType(androidx.media3.common.C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build(),
                /* handleAudioFocus = */ false,
            )
            player.addListener(object : Player.Listener {
                override fun onPlaybackStateChanged(playbackState: Int) {
                    logInfo(
                        "player_state_changed state=${playbackStateName(playbackState)}",
                        sessions[sessionId]
                    )
                    publishSessionState(sessionId)
                    schedulePersistSessionState()
                    syncForegroundState()
                }

                override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                    sessions[sessionId]?.syncCurrentMediaItemFromPlayer()
                    logInfo(
                        "player_media_item_transition reason=$reason",
                        sessions[sessionId]
                    )
                    publishSessionState(sessionId)
                    persistSessionStateNow()
                    syncForegroundState()
                }

                override fun onEvents(player: Player, events: Player.Events) {
                    publishSessionState(sessionId)
                }

                override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                    if (
                        shouldTrackTransientAudioFocusPause(
                            playWhenReady = playWhenReady,
                            reason = reason,
                            focusLossMayResume = transientAudioFocusLossActive,
                            playbackSuspended = playbackSuspended
                        )
                    ) {
                        pendingAudioFocusResumeSessionIds.add(sessionId)
                    } else {
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

                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    logInfo("player_is_playing_changed isPlaying=$isPlaying", sessions[sessionId])
                    publishSessionState(sessionId)
                    schedulePersistSessionState()
                    syncForegroundState()
                }

                override fun onPlayerError(error: PlaybackException) {
                    pendingAudioFocusResumeSessionIds.remove(sessionId)
                    logWarn(
                        "player_error code=${error.errorCodeName} message=${error.message} " +
                            "cause=${error.cause?.javaClass?.simpleName}:${error.cause?.message}",
                        sessions[sessionId],
                        error
                    )
                    publishSessionState(sessionId)
                    persistSessionStateNow()
                    syncForegroundState()
                }

                override fun onAudioSessionIdChanged(audioSessionId: Int) {
                    sessions[sessionId]?.onAudioSessionIdChanged(audioSessionId)
                }
            })
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
        return MediaSession.Builder(this, player)
            .setId("Nameless Audio")
            .build()
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
        }
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
    }

    private fun hasActivePlayback(): Boolean {
        return sessions.values.any { 
            val p = it.playerOrNull()
            p != null && (p.isPlaying || p.playWhenReady)
        }
    }

    private fun hasPendingAudioFocusResume(): Boolean {
        return pendingAudioFocusResumeSessionIds.any(sessions::containsKey)
    }

    private fun hasPlaybackToKeepAlive(): Boolean {
        return hasActivePlayback() || hasPendingAudioFocusResume()
    }

    private fun syncForegroundState() {
        if (hasPlaybackToKeepAlive()) {
            // Playback is active — cancel any pending grace-period stop and
            // make sure the foreground service + wake lock are held.
            cancelForegroundStopGrace()
            acquireWakeLock()
            requestAudioFocusIfNeeded()
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
                buildForegroundNotification(foregroundSession),
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
            ServiceCompat.startForeground(
                this,
                FOREGROUND_NOTIFICATION_ID,
                buildBootstrapForegroundNotification(),
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

    private fun buildForegroundNotification(
        session: NativePlaybackSession
    ): Notification {
        if (!notificationsDismissed &&
            !foregroundSuppressed &&
            UnifiedPlaybackNotificationController.hasUnifiedNotifications()
        ) {
            UnifiedPlaybackNotificationController.lastRichSummaryNotification?.let {
                return it
            }
        }
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or immutablePendingIntentFlag()
            )
        }
        return NotificationCompat.Builder(this, PLAYBACK_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(session.title.ifBlank { "Nameless Audio" })
            .setContentText(
                session.subtitle
                    ?.takeIf { it.isNotBlank() }
                    ?: getString(R.string.keep_alive_playback_active)
            )
            .setContentIntent(pendingIntent)
            .setShowWhen(false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun buildBootstrapForegroundNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or immutablePendingIntentFlag()
            )
        }
        return NotificationCompat.Builder(this, PLAYBACK_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Nameless Audio")
            .setContentText(getString(R.string.keep_alive_timer_active))
            .setContentIntent(pendingIntent)
            .setShowWhen(false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun immutablePendingIntentFlag(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE
        } else {
            0
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
        if (statePersistenceScheduled) return
        if (sessions.isEmpty()) return
        statePersistenceScheduled = true
        mainHandler.postDelayed(statePersistenceTicker, STATE_PERSISTENCE_INTERVAL_MS)
    }

    private fun stopStatePersistenceTicker() {
        if (!statePersistenceScheduled) return
        mainHandler.removeCallbacks(statePersistenceTicker)
        statePersistenceScheduled = false
    }

    private fun schedulePersistSessionState() {
        mainHandler.removeCallbacks(persistSessionStateRunnable)
        pendingPersistScheduled = true
        mainHandler.postDelayed(
            persistSessionStateRunnable,
            STATE_PERSISTENCE_DEBOUNCE_MS
        )
    }

    private fun cancelScheduledPersistSessionState() {
        if (!pendingPersistScheduled) return
        mainHandler.removeCallbacks(persistSessionStateRunnable)
        pendingPersistScheduled = false
    }

    private fun persistSessionStateNow() {
        cancelScheduledPersistSessionState()
        if (sessions.isEmpty()) {
            NativePlaybackStateStore.clearSessions(this)
            return
        }
        NativePlaybackStateStore.saveSessions(
            this,
            sessions.values.map { it.storedSnapshot() }
        )
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

        val restoredSessionIds = mutableListOf<String>()
        storedSessions.forEach { stored ->
            val nativeSession = sessions.getOrPut(stored.sessionId) {
                NativePlaybackSession(stored.sessionId)
            }
            try {
                nativeSession.channelSwapEnabled = stored.channelSwapEnabled
                val queue = stored.queue.map { queueItem ->
                    NativeMediaItemDescriptor(
                        path = queueItem.path,
                        uri = queueItem.uri,
                        title = queueItem.title,
                        subtitle = queueItem.subtitle,
                        artUri = queueItem.artUri
                    )
                }.ifEmpty {
                    listOf(
                        NativeMediaItemDescriptor(
                            path = stored.path,
                            uri = stored.uri,
                            title = stored.title,
                            subtitle = stored.subtitle,
                            artUri = stored.artUri
                        )
                    )
                }
                val queueStartIndex = stored.queueStartIndex
                    .coerceIn(0, queue.lastIndex)
                nativeSession.configure(
                    descriptor = queue[queueStartIndex],
                    queue = queue,
                    queueStartIndex = queueStartIndex,
                    startPositionMs = stored.positionMs,
                    volume = stored.volume,
                    repeatOne = stored.repeatOne,
                    repeatAll = stored.repeatAll,
                    shuffleModeEnabled = stored.shuffleModeEnabled,
                    autoPlay = stored.playWhenReady || stored.playing
                )
                focusSession(stored.sessionId)
                restoredSessionIds += stored.sessionId
            } catch (error: Exception) {
                sessions.remove(stored.sessionId)
                nativeSession.release()
                logWarn("sticky_restore_session_failed sessionId=${stored.sessionId}", error = error)
            }
        }

        if (restoredSessionIds.isEmpty()) {
            logInfo("sticky_restore_skip restore_failed")
            releaseWakeLock()
            stopPlaybackForeground(
                reason = "sticky_restore_failed",
                removeNotification = true
            )
            return
        }

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
        NativePlaybackStateStore.loadSessions(this)
            .filter { it.sessionId in missingSessionIds }
            .forEach { stored ->
                val nativeSession = sessions.getOrPut(stored.sessionId) {
                    NativePlaybackSession(stored.sessionId)
                }
                try {
                    nativeSession.channelSwapEnabled = stored.channelSwapEnabled
                    val descriptor = NativeMediaItemDescriptor(
                        path = stored.path,
                        uri = stored.uri,
                        title = stored.title,
                        subtitle = stored.subtitle,
                        artUri = stored.artUri
                    )
                    val queue = stored.queue.map { queueItem ->
                        NativeMediaItemDescriptor(
                            path = queueItem.path,
                            uri = queueItem.uri,
                            title = queueItem.title,
                            subtitle = queueItem.subtitle,
                            artUri = queueItem.artUri
                        )
                    }.ifEmpty {
                        listOf(descriptor)
                    }
                    val queueStartIndex = stored.queueStartIndex
                        .coerceIn(0, queue.lastIndex)
                    nativeSession.configure(
                        descriptor = queue[queueStartIndex],
                        queue = queue,
                        queueStartIndex = queueStartIndex,
                        startPositionMs = stored.positionMs,
                        volume = stored.volume,
                        repeatOne = stored.repeatOne,
                        repeatAll = stored.repeatAll,
                        shuffleModeEnabled = stored.shuffleModeEnabled,
                        autoPlay = false
                    )
                    focusSession(stored.sessionId)
                    publishSessionState(stored.sessionId)
                } catch (_: Exception) {
                    sessions.remove(stored.sessionId)
                    nativeSession.release()
                }
            }
        persistSessionStateNow()
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
        if (wakeLock?.isHeld == true) {
            logInfo("wakelock_acquire_skip already_held")
            return
        }
        try {
            val powerManager = getSystemService(POWER_SERVICE) as? PowerManager
            wakeLock = powerManager?.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "$packageName:native_playback"
            )?.apply {
                setReferenceCounted(false)
                acquire()
            }
            logInfo("wakelock_acquired held=${wakeLock?.isHeld == true}")
        } catch (e: Exception) {
            logWarn("wakelock_acquire_failed", error = e)
            wakeLock = null
        }
    }

    private fun releaseWakeLock() {
        val currentWakeLock = wakeLock ?: run {
            logInfo("wakelock_release_skip none")
            return
        }
        try {
            if (currentWakeLock.isHeld) {
                currentWakeLock.release()
                logInfo("wakelock_released")
            } else {
                logInfo("wakelock_release_skip not_held")
            }
        } catch (e: RuntimeException) {
            logWarn("wakelock_release_failed", error = e)
            // Ignore stale wakelock state.
        } finally {
            wakeLock = null
        }
    }

    private fun logInfo(message: String, session: NativePlaybackSession? = null) {
        Log.i(LOG_TAG, "$message ${playbackLogState(session)}")
    }

    private fun logWarn(
        message: String,
        session: NativePlaybackSession? = null,
        error: Throwable? = null
    ) {
        val fullMessage = "$message ${playbackLogState(session)}"
        if (error == null) {
            Log.w(LOG_TAG, fullMessage)
        } else {
            Log.w(LOG_TAG, fullMessage, error)
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

    private fun publishSessionState(sessionId: String) {
        val session = sessions[sessionId] ?: return
        val snapshot = session.snapshot()
        for (listener in stateListeners.values) {
            try {
                listener(snapshot)
            } catch (_: Exception) {
                // Prevent one broken listener from crashing the service.
            }
        }
    }

    private fun publishAllSessionStates() {
        sessions.keys.toList().forEach { publishSessionState(it) }
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

    private inner class NativePlaybackSession(
        val sessionId: String
    ) {
        private val channelMappingAudioProcessor = ChannelMappingAudioProcessor()
        private var loudnessEnhancer: LoudnessEnhancer? = null
        private var loudnessEnhancerSessionId: Int = C.AUDIO_SESSION_ID_UNSET
        private var _player: ExoPlayer? = null
        var lastUsedMs: Long = System.currentTimeMillis()
        var path: String? = null
        var uri: String? = null
        var title: String = "Audio"
        var subtitle: String? = null
        var artUri: String? = null
        var volume: Float = 1f
        var repeatOne: Boolean = false
        var repeatAll: Boolean = false
        var shuffleModeEnabled: Boolean = false
        private var queue: List<NativeMediaItemDescriptor> = emptyList()
        var channelSwapEnabled: Boolean = false
        var lastPositionMs: Long = 0L
        var lastDurationMs: Long? = null
        var lastBufferedPositionMs: Long = 0L
        var lastIsPlaying: Boolean = false
        var lastPlayWhenReady: Boolean = false
        var lastPlaybackState: String = "idle"

        fun hasPlayer(): Boolean = _player != null

        fun playerOrNull(): ExoPlayer? = _player

        fun ensurePlayer(): ExoPlayer {
            _player?.let { return it }
            val p = createPlayer(
                sessionId,
                channelMappingAudioProcessor
            )
            _player = p
            
            val descriptors = queue.takeIf { it.isNotEmpty() }
                ?: uri?.let {
                    listOf(
                        NativeMediaItemDescriptor(
                            path = path ?: it,
                            uri = it,
                            title = title,
                            subtitle = subtitle,
                            artUri = artUri
                        )
                    )
                }
            if (!descriptors.isNullOrEmpty()) {
                p.setMediaItems(
                    descriptors.map(::buildMediaItem),
                    currentQueueIndexFor(descriptors),
                    lastPositionMs
                )
                applyVolumeToPlayer(p)
                p.repeatMode = repeatModeFor(descriptors.size)
                p.shuffleModeEnabled = shuffleModeEnabled && descriptors.size > 1
                p.playWhenReady = lastPlayWhenReady
                p.prepare()
            }
            
            return p
        }

        fun isPlaying(): Boolean = _player?.isPlaying ?: lastIsPlaying

        fun releasePlayer() {
            _player?.let { p ->
                lastPositionMs = p.currentPosition.coerceAtLeast(0L)
                lastDurationMs = durationOrNull(p.duration)
                lastBufferedPositionMs = p.bufferedPosition.coerceAtLeast(0L)
                lastIsPlaying = p.isPlaying
                lastPlayWhenReady = p.playWhenReady
                lastPlaybackState = p.playbackStateName()
                syncCurrentMediaItemFromPlayer()
                p.release()
            }
            releaseLoudnessEnhancer()
            _player = null
        }

        fun configure(
            descriptor: NativeMediaItemDescriptor,
            queue: List<NativeMediaItemDescriptor>,
            queueStartIndex: Int,
            startPositionMs: Long,
            volume: Float,
            repeatOne: Boolean,
            repeatAll: Boolean,
            shuffleModeEnabled: Boolean,
            autoPlay: Boolean
        ) {
            this.queue = queue.ifEmpty { listOf(descriptor) }
            this.path = descriptor.path
            this.uri = descriptor.uri
            this.title = descriptor.title
            this.subtitle = descriptor.subtitle
            this.artUri = descriptor.artUri
            this.lastPositionMs = startPositionMs
            this.volume = PlaybackVolumeMapper.normalize(volume)
            this.repeatOne = repeatOne
            this.repeatAll = repeatAll
            this.shuffleModeEnabled = shuffleModeEnabled
            this.lastPlayWhenReady = autoPlay
            applyChannelMap()

            val p = playerOrNull() ?: createPlayer(
                sessionId,
                channelMappingAudioProcessor
            ).also { _player = it }
            p.setMediaItems(
                this.queue.map(::buildMediaItem),
                queueStartIndex.coerceIn(0, this.queue.lastIndex),
                startPositionMs.coerceAtLeast(0L)
            )
            applyVolumeToPlayer(p)
            p.repeatMode = repeatModeFor(this.queue.size)
            p.shuffleModeEnabled = shuffleModeEnabled && this.queue.size > 1
            p.playWhenReady = autoPlay
            p.prepare()
            syncCurrentMediaItemFromPlayer()
            
            evictPlayersIfNeeded()
        }

        fun applyChannelMap() {
            channelMappingAudioProcessor.setChannelMap(
                if (channelSwapEnabled) {
                    intArrayOf(1, 0)
                } else {
                    intArrayOf(0, 1)
                }
            )
        }

        fun applyVolume(volume: Float) {
            this.volume = PlaybackVolumeMapper.normalize(volume)
            playerOrNull()?.let(::applyVolumeToPlayer)
        }

        private fun applyVolumeToPlayer(player: ExoPlayer) {
            val normalizedVolume = PlaybackVolumeMapper.normalize(volume)
            this.volume = normalizedVolume
            player.volume = PlaybackVolumeMapper.playerVolume(normalizedVolume)
            syncLoudnessEnhancer(player.audioSessionId)
        }

        fun onAudioSessionIdChanged(audioSessionId: Int) {
            syncLoudnessEnhancer(audioSessionId)
        }

        private fun syncLoudnessEnhancer(audioSessionId: Int) {
            val targetGain = PlaybackVolumeMapper.boostGainMillibels(volume)
            if (targetGain <= 0 || audioSessionId == C.AUDIO_SESSION_ID_UNSET) {
                releaseLoudnessEnhancer()
                return
            }

            val enhancer = if (loudnessEnhancerSessionId == audioSessionId) {
                loudnessEnhancer
            } else {
                releaseLoudnessEnhancer()
                try {
                    LoudnessEnhancer(audioSessionId).also {
                        loudnessEnhancer = it
                        loudnessEnhancerSessionId = audioSessionId
                    }
                } catch (e: RuntimeException) {
                    logWarn(
                        "loudness_enhancer_create_failed audioSessionId=$audioSessionId",
                        this,
                        e
                    )
                    null
                }
            } ?: return

            try {
                enhancer.setTargetGain(targetGain)
                enhancer.setEnabled(true)
            } catch (e: RuntimeException) {
                logWarn("loudness_enhancer_apply_failed gain=$targetGain", this, e)
                releaseLoudnessEnhancer()
            }
        }

        private fun releaseLoudnessEnhancer() {
            val enhancer = loudnessEnhancer ?: return
            loudnessEnhancer = null
            loudnessEnhancerSessionId = C.AUDIO_SESSION_ID_UNSET
            try {
                enhancer.setEnabled(false)
            } catch (_: RuntimeException) {
            }
            try {
                enhancer.release()
            } catch (_: RuntimeException) {
            }
        }

        fun updateQueue(
            queue: List<NativeMediaItemDescriptor>,
            queueStartIndex: Int,
            repeatOne: Boolean,
            repeatAll: Boolean,
            shuffleModeEnabled: Boolean
        ) {
            if (queue.isEmpty()) return
            val p = _player
            val currentPositionMs = p?.currentPosition?.coerceAtLeast(0L) ?: lastPositionMs
            val shouldResume = p?.let { it.playWhenReady || it.isPlaying } ?: lastPlayWhenReady
            configure(
                descriptor = queue[queueStartIndex.coerceIn(0, queue.lastIndex)],
                queue = queue,
                queueStartIndex = queueStartIndex,
                startPositionMs = currentPositionMs,
                volume = volume,
                repeatOne = repeatOne,
                repeatAll = repeatAll,
                shuffleModeEnabled = shuffleModeEnabled,
                autoPlay = shouldResume
            )
        }

        fun reprepareCurrentMediaItem() {
            val currentUri = uri ?: return
            val p = _player
            val currentPositionMs = p?.currentPosition?.coerceAtLeast(0L) ?: lastPositionMs
            val shouldResume = p?.let { it.playWhenReady || it.isPlaying } ?: lastPlayWhenReady
            val isRepeatOne = (p?.repeatMode == Player.REPEAT_MODE_ONE) || (p == null && repeatOne)
            val descriptors = queue.takeIf { it.isNotEmpty() } ?: listOf(
                NativeMediaItemDescriptor(
                    path = path ?: currentUri,
                    uri = currentUri,
                    title = title,
                    subtitle = subtitle,
                    artUri = artUri
                )
            )
            val currentIndex = p?.currentMediaItemIndex ?: currentQueueIndexFor(descriptors)

            configure(
                descriptor = descriptors[currentIndex.coerceIn(0, descriptors.lastIndex)],
                queue = descriptors,
                queueStartIndex = currentIndex,
                startPositionMs = currentPositionMs,
                volume = volume,
                repeatOne = isRepeatOne,
                repeatAll = repeatAll,
                shuffleModeEnabled = shuffleModeEnabled,
                autoPlay = shouldResume,
            )
        }

        fun snapshot(): Map<String, Any?> {
            val p = _player
            if (p != null) {
                lastPositionMs = p.currentPosition.coerceAtLeast(0L)
                lastDurationMs = durationOrNull(p.duration)
                lastBufferedPositionMs = p.bufferedPosition.coerceAtLeast(0L)
                lastIsPlaying = p.isPlaying
                lastPlayWhenReady = p.playWhenReady
                lastPlaybackState = p.playbackStateName()
                syncCurrentMediaItemFromPlayer()
            }
            
            return mapOf(
                "sessionId" to sessionId,
                "path" to path,
                "uri" to uri,
                "title" to title,
                "subtitle" to subtitle,
                "artUri" to artUri,
                "playing" to lastIsPlaying,
                "playWhenReady" to lastPlayWhenReady,
                "processingState" to lastPlaybackState,
                "positionMs" to lastPositionMs,
                "durationMs" to lastDurationMs,
                "bufferedPositionMs" to lastBufferedPositionMs,
                "volume" to volume.toDouble(),
                "boostGain" to PlaybackVolumeMapper.boostGain(volume).toDouble(),
                "channelSwap" to channelSwapEnabled,
                "error" to p?.playerError?.message
            )
        }

        fun storedSnapshot(): StoredNativePlaybackSession {
            val p = _player
            val currentPos = p?.currentPosition?.coerceAtLeast(0L) ?: lastPositionMs
            val isP = p?.isPlaying ?: lastIsPlaying
            val isPWR = p?.playWhenReady ?: lastPlayWhenReady
            if (p != null) {
                syncCurrentMediaItemFromPlayer()
            }
            
            return StoredNativePlaybackSession(
                sessionId = sessionId,
                uri = uri.orEmpty(),
                path = path ?: uri.orEmpty(),
                title = title,
                subtitle = subtitle,
                artUri = artUri,
                positionMs = currentPos,
                volume = volume,
                repeatOne = repeatOne,
                repeatAll = repeatAll,
                shuffleModeEnabled = shuffleModeEnabled,
                queueStartIndex = (p?.currentMediaItemIndex ?: currentQueueIndexFor(queue))
                    .coerceAtLeast(0),
                queue = queue.map { descriptor ->
                    StoredNativePlaybackQueueItem(
                        path = descriptor.path,
                        uri = descriptor.uri,
                        title = descriptor.title,
                        subtitle = descriptor.subtitle,
                        artUri = descriptor.artUri
                    )
                },
                channelSwapEnabled = channelSwapEnabled,
                playing = isP,
                playWhenReady = isPWR
            )
        }

        fun foregroundNotificationSignature(): String {
            val p = _player
            val playing = p?.isPlaying ?: lastIsPlaying
            val playWhenReady = p?.playWhenReady ?: lastPlayWhenReady
            return listOf(
                sessionId,
                title,
                subtitle.orEmpty(),
                playing,
                playWhenReady,
                repeatOne
            ).joinToString("|")
        }

        fun syncCurrentMediaItemFromPlayer() {
            val mediaItem = _player?.currentMediaItem ?: return
            val metadata = mediaItem.mediaMetadata
            path = mediaItem.mediaId.takeIf { it.isNotBlank() }
            uri = mediaItem.localConfiguration?.uri?.toString() ?: uri
            title = metadata.title?.toString()?.takeIf { it.isNotBlank() } ?: title
            subtitle = metadata.artist?.toString()?.takeIf { it.isNotBlank() }
            artUri = metadata.artworkUri?.toString()
        }

        private fun buildMediaItem(descriptor: NativeMediaItemDescriptor): MediaItem {
            val metadataBuilder = MediaMetadata.Builder()
                .setTitle(descriptor.title)
                .setArtist(descriptor.subtitle)
            if (!descriptor.artUri.isNullOrBlank()) {
                metadataBuilder.setArtworkUri(Uri.parse(descriptor.artUri))
            }
            return MediaItem.Builder()
                .setMediaId(descriptor.path)
                .setUri(Uri.parse(descriptor.uri))
                .setMediaMetadata(metadataBuilder.build())
                .build()
        }

        private fun repeatModeFor(queueSize: Int): Int {
            return when {
                repeatOne -> Player.REPEAT_MODE_ONE
                repeatAll && queueSize > 1 -> Player.REPEAT_MODE_ALL
                else -> Player.REPEAT_MODE_OFF
            }
        }

        fun currentRepeatMode(): Int = repeatModeFor(queue.size)

        fun currentShuffleModeEnabled(): Boolean = shuffleModeEnabled && queue.size > 1

        private fun currentQueueIndexFor(descriptors: List<NativeMediaItemDescriptor>): Int {
            val currentPath = path
            val index = descriptors.indexOfFirst { it.path == currentPath }
            return if (index >= 0) index else 0
        }

        fun release() {
            _player?.release()
            _player = null
        }
    }
}

private fun ExoPlayer.playbackStateName(): String {
    return playbackStateName(playbackState)
}

private fun playbackStateName(playbackState: Int): String {
    return when (playbackState) {
        Player.STATE_IDLE -> "idle"
        Player.STATE_BUFFERING -> "buffering"
        Player.STATE_READY -> "ready"
        Player.STATE_ENDED -> "completed"
        else -> "unknown"
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

private fun durationOrNull(duration: Long): Long? {
    return if (duration == C.TIME_UNSET || duration < 0L) null else duration
}
