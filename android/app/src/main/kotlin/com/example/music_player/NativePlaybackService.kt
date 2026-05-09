package com.example.music_player

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
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

class NativePlaybackService : MediaSessionService() {
    companion object {
        const val ACTION_START = "com.example.music_player.native.START"
        private const val PLAYBACK_CHANNEL_ID = "com.example.music_player.channel.playback"
        private const val PLAYBACK_CHANNEL_NAME = "Playback"
        private const val PLAYBACK_CHANNEL_DESCRIPTION = "Playback notification controls"
        private const val PLAYBACK_GROUP_KEY = "com.example.music_player.PLAYBACK_GROUP"
        private const val FOREGROUND_NOTIFICATION_ID = 11_225
        private const val FOREGROUND_WATCHDOG_INTERVAL_MS = 4 * 60 * 1000L
        private const val STATE_PERSISTENCE_INTERVAL_MS = 60 * 1000L
        private const val STATE_PERSISTENCE_DEBOUNCE_MS = 800L

        @Volatile
        private var instance: NativePlaybackService? = null

        @Volatile
        var foregroundSuppressed = false

        @Volatile
        var notificationsDismissed = false

        fun controller(): NativePlaybackService? = instance

        fun ensureStarted(context: Context): NativePlaybackService? {
            controller()?.let { return it }
            val intent = Intent(context.applicationContext, NativePlaybackService::class.java).apply {
                action = ACTION_START
            }
            return try {
                context.applicationContext.startService(intent)
                controller()
            } catch (_: Exception) {
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
    private var wakeLock: PowerManager.WakeLock? = null
    private var pendingPersistScheduled = false
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
            if (!hasActivePlayback()) {
                foregroundWatchdogScheduled = false
                stopPlaybackForeground(removeNotification = sessions.isEmpty())
                return
            }
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
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        return START_STICKY
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        return ensureMediaSession()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (hasActivePlayback()) {
            syncForegroundState()
        } else {
            stopForegroundWatchdog()
            stopPlaybackForeground(removeNotification = sessions.isEmpty())
            stopSelf()
        }
    }

    override fun onDestroy() {
        stateListeners.clear()
        mainHandler.removeCallbacks(positionTicker)
        stopStatePersistenceTicker()
        cancelScheduledPersistSessionState()
        stopForegroundWatchdog()
        tickerScheduled = false
        mediaSession?.release()
        mediaSession = null
        sessions.values.forEach { it.release() }
        sessions.clear()
        stopPlaybackForeground(removeNotification = true)
        releaseWakeLock()
        instance = null
        super.onDestroy()
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
        val title = args["title"] as? String ?: "Audio"
        val subtitle = args["subtitle"] as? String
        val artUri = args["artUri"] as? String
        val startPositionMs = (args["startPositionMs"] as? Number)?.toLong() ?: 0L
        val autoPlay = args["autoPlay"] as? Boolean ?: false
        val volume = (args["volume"] as? Number)?.toFloat() ?: 1f
        val repeatOne = args["repeatOne"] as? Boolean ?: false
        if (autoPlay) {
            notificationsDismissed = false
            playbackSuspended = false
        }

        val nativeSession = sessions.getOrPut(sessionId) { NativePlaybackSession(sessionId) }
        return try {
            nativeSession.configure(
                uri = uri,
                title = title,
                subtitle = subtitle,
                artUri = artUri,
                startPositionMs = startPositionMs,
                volume = volume,
                repeatOne = repeatOne,
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
        notificationsDismissed = false
        playbackSuspended = false
        focusSession(sessionId)
        session.player.play()
        publishSessionState(sessionId)
        ensureTicker()
        persistSessionStateNow()
        ensureStatePersistenceTicker()
        syncForegroundState()
        return okResult(session.snapshot())
    }

    fun pause(sessionId: String): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.player.pause()
        publishSessionState(sessionId)
        persistSessionStateNow()
        syncForegroundState()
        return okResult(session.snapshot())
    }

    fun stop(sessionId: String): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.player.stop()
        session.player.clearMediaItems()
        publishSessionState(sessionId)
        persistSessionStateNow()
        syncForegroundState()
        return okResult(session.snapshot())
    }

    fun seek(sessionId: String, positionMs: Long): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.player.seekTo(positionMs.coerceAtLeast(0L))
        publishSessionState(sessionId)
        schedulePersistSessionState()
        return okResult(session.snapshot())
    }

    fun setVolume(sessionId: String, volume: Float): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.player.volume = volume.coerceIn(0f, 2f)
        schedulePersistSessionState()
        return okResult(session.snapshot())
    }

    fun setRepeatOne(sessionId: String, repeatOne: Boolean): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.player.repeatMode = if (repeatOne) {
            Player.REPEAT_MODE_ONE
        } else {
            Player.REPEAT_MODE_OFF
        }
        schedulePersistSessionState()
        return okResult(session.snapshot())
    }

    fun removeSession(sessionId: String): Map<String, Any?> {
        val removed = sessions.remove(sessionId) ?: return okResult(null)
        removed.release()
        if (focusedSessionId == sessionId) {
            focusedSessionId = sessions.keys.firstOrNull()
            updateMediaSessionPlayer()
        }
        if (sessions.isEmpty()) {
            stopForegroundWatchdog()
            stopStatePersistenceTicker()
            cancelScheduledPersistSessionState()
            NativePlaybackStateStore.clearSessions(this)
            NativePlaybackStateStore.clearPausedSessionIds(this)
            NativePlaybackStateStore.clearTimerCandidateSessionIds(this)
            stopPlaybackForeground(removeNotification = true)
            stopSelf()
        } else {
            persistSessionStateNow()
            syncForegroundState()
        }
        return okResult(null)
    }

    fun pauseAll(): Map<String, Any?> {
        notificationsDismissed = true
        sessions.values.forEach { it.player.pause() }
        publishAllSessionStates()
        persistSessionStateNow()
        stopForegroundWatchdog()
        mediaSession?.release()
        mediaSession = null
        playbackSuspended = true
        stopPlaybackForeground(removeNotification = sessions.isEmpty())
        return okResult(null)
    }

    fun clearAll(): Map<String, Any?> {
        notificationsDismissed = true
        sessions.values.forEach { it.release() }
        sessions.clear()
        focusedSessionId = null
        updateMediaSessionPlayer()
        stopForegroundWatchdog()
        stopStatePersistenceTicker()
        cancelScheduledPersistSessionState()
        NativePlaybackStateStore.clearSessions(this)
        NativePlaybackStateStore.clearPausedSessionIds(this)
        NativePlaybackStateStore.clearTimerCandidateSessionIds(this)
        stopPlaybackForeground(removeNotification = true)
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
            stopForegroundWatchdog()
            stopPlaybackForeground(removeNotification = true)
            mediaSession?.release()
            mediaSession = null
        } else {
            notificationsDismissed = false
            updateMediaSessionPlayer()
            if (hasActivePlayback()) {
                ensureForegroundWatchdog()
            }
        }
        return okResult(null)
    }

    fun dismissNotifications(): Map<String, Any?> {
        notificationsDismissed = true
        mediaSession?.release()
        mediaSession = null
        return okResult(null)
    }

    fun undismissNotifications(): Map<String, Any?> {
        notificationsDismissed = false
        return okResult(null)
    }

    fun pausePlayingSessionsForTimer(): List<String> {
        val pausedSessionIds = sessions.values
            .filter { it.player.isPlaying || it.player.playWhenReady }
            .map { it.sessionId }
        if (pausedSessionIds.isEmpty()) {
            syncForegroundState()
            return emptyList()
        }
        pausedSessionIds.forEach { sessionId ->
            sessions[sessionId]?.player?.pause()
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
            val session = sessions[sessionId] ?: return@forEach
            focusSession(sessionId)
            session.player.play()
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
        session.channelSwapEnabled = enabled
        session.applyChannelMap()
        session.reprepareCurrentMediaItem()
        publishSessionState(sessionId)
        schedulePersistSessionState()
        syncForegroundState()
        return okResult(session.snapshot())
    }

    private fun createPlayer(sessionId: String, audioProcessor: ChannelMappingAudioProcessor): ExoPlayer {
        val renderersFactory = object : DefaultRenderersFactory(this) {
            override fun buildAudioSink(
                context: Context,
                enableFloatOutput: Boolean,
                enableAudioTrackPlaybackParams: Boolean
            ) = DefaultAudioSink.Builder(context)
                .setAudioProcessors(arrayOf(audioProcessor))
                .setEnableFloatOutput(enableFloatOutput)
                .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
                .build()
        }

        return ExoPlayer.Builder(this, renderersFactory).build().also { player ->
            player.setWakeMode(C.WAKE_MODE_LOCAL)
            player.addListener(object : Player.Listener {
                override fun onPlaybackStateChanged(playbackState: Int) {
                    publishSessionState(sessionId)
                    schedulePersistSessionState()
                    syncForegroundState()
                }

                override fun onEvents(player: Player, events: Player.Events) {
                    publishSessionState(sessionId)
                }

                override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                    publishSessionState(sessionId)
                    schedulePersistSessionState()
                    syncForegroundState()
                }

                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    publishSessionState(sessionId)
                    schedulePersistSessionState()
                    syncForegroundState()
                }

                override fun onPlayerError(error: PlaybackException) {
                    publishSessionState(sessionId)
                    persistSessionStateNow()
                    syncForegroundState()
                }
            })
        }
    }

    private fun focusSession(sessionId: String) {
        if (!sessions.containsKey(sessionId)) return
        if (focusedSessionId == sessionId) return
        focusedSessionId = sessionId
        updateMediaSessionPlayer()
    }

    private fun ensureMediaSession(): MediaSession? {
        if (notificationsDismissed) return null
        if (foregroundSuppressed) return null
        if (playbackSuspended) return null
        mediaSession?.let { return it }
        val player = sessions[focusedSessionId]?.player ?: return null
        if (!player.playWhenReady && !player.isPlaying) return null
        return MediaSession.Builder(this, player)
            .setId("Nameless Audio")
            .build()
            .also { mediaSession = it }
    }

    private fun updateMediaSessionPlayer() {
        val nextPlayer = sessions[focusedSessionId]?.player
        val existingSession = mediaSession
        if (nextPlayer == null) {
            existingSession?.release()
            mediaSession = null
            return
        }
        if (existingSession == null) {
            ensureMediaSession()
            return
        }
        if (existingSession.player !== nextPlayer) {
            existingSession.player = nextPlayer
        }
    }

    private fun hasActivePlayback(): Boolean {
        return sessions.values.any { it.player.isPlaying || it.player.playWhenReady }
    }

    private fun syncForegroundState() {
        if (hasActivePlayback()) {
            acquireWakeLock()
            startPlaybackForeground()
            ensureForegroundWatchdog()
            ensureStatePersistenceTicker()
        } else {
            releaseWakeLock()
            stopForegroundWatchdog()
            persistSessionStateNow()
            stopPlaybackForeground(removeNotification = sessions.isEmpty())
        }
    }

    private fun startPlaybackForeground() {
        // audio_service's AudioService and PlaybackKeepAliveService provide
        // foreground notifications. This service does not need its own
        // startForeground() call since all three run in the same process.
    }

    private fun stopPlaybackForeground(removeNotification: Boolean = true) {
        if (removeNotification) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            manager?.cancel(FOREGROUND_NOTIFICATION_ID)
        }
    }

    private fun ensureForegroundWatchdog() {
        if (foregroundSuppressed) return
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
                    nativeSession.configure(
                        uri = stored.uri,
                        title = stored.title,
                        subtitle = stored.subtitle,
                        artUri = stored.artUri,
                        startPositionMs = stored.positionMs,
                        volume = stored.volume,
                        repeatOne = stored.repeatOne,
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

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val powerManager = getSystemService(POWER_SERVICE) as? PowerManager
            wakeLock = powerManager?.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "$packageName:native_playback"
            )?.apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
            wakeLock = null
        }
    }

    private fun releaseWakeLock() {
        val currentWakeLock = wakeLock ?: return
        try {
            if (currentWakeLock.isHeld) {
                currentWakeLock.release()
            }
        } catch (_: RuntimeException) {
            // Ignore stale wakelock state.
        } finally {
            wakeLock = null
        }
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
        val player: ExoPlayer = createPlayer(sessionId, channelMappingAudioProcessor)
        var uri: String? = null
        var title: String = "Audio"
        var subtitle: String? = null
        var artUri: String? = null
        var channelSwapEnabled: Boolean = false

        fun configure(
            uri: String,
            title: String,
            subtitle: String?,
            artUri: String?,
            startPositionMs: Long,
            volume: Float,
            repeatOne: Boolean,
            autoPlay: Boolean
        ) {
            this.uri = uri
            this.title = title
            this.subtitle = subtitle
            this.artUri = artUri
            applyChannelMap()

            val metadataBuilder = MediaMetadata.Builder()
                .setTitle(title)
                .setArtist(subtitle)
            if (!artUri.isNullOrBlank()) {
                metadataBuilder.setArtworkUri(Uri.parse(artUri))
            }

            val mediaItem = MediaItem.Builder()
                .setMediaId(sessionId)
                .setUri(Uri.parse(uri))
                .setMediaMetadata(metadataBuilder.build())
                .build()

            player.setMediaItem(mediaItem, startPositionMs.coerceAtLeast(0L))
            player.volume = volume.coerceIn(0f, 1f)
            player.repeatMode = if (repeatOne) {
                Player.REPEAT_MODE_ONE
            } else {
                Player.REPEAT_MODE_OFF
            }
            player.playWhenReady = autoPlay
            player.prepare()
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

        fun reprepareCurrentMediaItem() {
            val currentUri = uri ?: return
            val currentPositionMs = player.currentPosition.coerceAtLeast(0L)
            val shouldResume = player.playWhenReady || player.isPlaying
            val currentVolume = player.volume
            val repeatOne = player.repeatMode == Player.REPEAT_MODE_ONE
            configure(
                uri = currentUri,
                title = title,
                subtitle = subtitle,
                artUri = artUri,
                startPositionMs = currentPositionMs,
                volume = currentVolume,
                repeatOne = repeatOne,
                autoPlay = shouldResume
            )
        }

        fun snapshot(): Map<String, Any?> {
            return mapOf(
                "sessionId" to sessionId,
                "uri" to uri,
                "title" to title,
                "subtitle" to subtitle,
                "artUri" to artUri,
                "playing" to player.isPlaying,
                "playWhenReady" to player.playWhenReady,
                "processingState" to player.playbackStateName(),
                "positionMs" to player.currentPosition.coerceAtLeast(0L),
                "durationMs" to durationOrNull(player.duration),
                "bufferedPositionMs" to player.bufferedPosition.coerceAtLeast(0L),
                "volume" to player.volume.toDouble(),
                "channelSwap" to channelSwapEnabled,
                "error" to player.playerError?.message
            )
        }

        fun storedSnapshot(): StoredNativePlaybackSession {
            return StoredNativePlaybackSession(
                sessionId = sessionId,
                uri = uri.orEmpty(),
                title = title,
                subtitle = subtitle,
                artUri = artUri,
                positionMs = player.currentPosition.coerceAtLeast(0L),
                volume = player.volume,
                repeatOne = player.repeatMode == Player.REPEAT_MODE_ONE,
                channelSwapEnabled = channelSwapEnabled,
                playing = player.isPlaying,
                playWhenReady = player.playWhenReady
            )
        }

        fun release() {
            player.release()
        }
    }
}

private fun ExoPlayer.playbackStateName(): String {
    return when (playbackState) {
        Player.STATE_IDLE -> "idle"
        Player.STATE_BUFFERING -> "buffering"
        Player.STATE_READY -> "ready"
        Player.STATE_ENDED -> "completed"
        else -> "unknown"
    }
}

private fun durationOrNull(duration: Long): Long? {
    return if (duration == C.TIME_UNSET || duration < 0L) null else duration
}
