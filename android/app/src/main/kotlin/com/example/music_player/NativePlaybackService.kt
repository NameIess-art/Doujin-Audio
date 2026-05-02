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
        private const val PLAYBACK_WAKE_LOCK_TIMEOUT_MS = 6 * 60 * 1000L

        @Volatile
        private var instance: NativePlaybackService? = null

        @Volatile
        var foregroundSuppressed = false

        @Volatile
        var notificationsDismissed = false

        fun controller(): NativePlaybackService? = instance
    }

    private val sessions = linkedMapOf<String, NativePlaybackSession>()
    private val stateListeners = ConcurrentHashMap<String, (Map<String, Any?>) -> Unit>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var mediaSession: MediaSession? = null
    private var focusedSessionId: String? = null
    private var tickerScheduled = false
    private var foregroundWatchdogScheduled = false
    private var playbackSuspended = false
    private var playbackWakeLock: PowerManager.WakeLock? = null
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
                releasePlaybackWakeLock()
                stopPlaybackForeground(removeNotification = sessions.isEmpty())
                return
            }
            acquirePlaybackWakeLock()
            mainHandler.postDelayed(this, FOREGROUND_WATCHDOG_INTERVAL_MS)
        }
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
            releasePlaybackWakeLock()
            stopPlaybackForeground(removeNotification = sessions.isEmpty())
            stopSelf()
        }
    }

    override fun onDestroy() {
        stateListeners.clear()
        mainHandler.removeCallbacks(positionTicker)
        stopForegroundWatchdog()
        tickerScheduled = false
        mediaSession?.release()
        mediaSession = null
        sessions.values.forEach { it.release() }
        sessions.clear()
        releasePlaybackWakeLock()
        stopPlaybackForeground(removeNotification = true)
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

        val nativeSession = sessions.getOrPut(sessionId) {
            NativePlaybackSession(sessionId, createPlayer(sessionId))
        }
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
        syncForegroundState()
        return okResult(session.snapshot())
    }

    fun pause(sessionId: String): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.player.pause()
        publishSessionState(sessionId)
        syncForegroundState()
        return okResult(session.snapshot())
    }

    fun stop(sessionId: String): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.player.stop()
        session.player.clearMediaItems()
        publishSessionState(sessionId)
        syncForegroundState()
        return okResult(session.snapshot())
    }

    fun seek(sessionId: String, positionMs: Long): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.player.seekTo(positionMs.coerceAtLeast(0L))
        publishSessionState(sessionId)
        return okResult(session.snapshot())
    }

    fun setVolume(sessionId: String, volume: Float): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.player.volume = volume.coerceIn(0f, 1f)
        return okResult(session.snapshot())
    }

    fun setRepeatOne(sessionId: String, repeatOne: Boolean): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.player.repeatMode = if (repeatOne) {
            Player.REPEAT_MODE_ONE
        } else {
            Player.REPEAT_MODE_OFF
        }
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
            releasePlaybackWakeLock()
            stopPlaybackForeground(removeNotification = true)
            stopSelf()
        } else {
            syncForegroundState()
        }
        return okResult(null)
    }

    fun pauseAll(): Map<String, Any?> {
        notificationsDismissed = true
        sessions.values.forEach { it.player.pause() }
        publishAllSessionStates()
        stopForegroundWatchdog()
        releasePlaybackWakeLock()
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
        releasePlaybackWakeLock()
        stopPlaybackForeground(removeNotification = true)
        stopSelf()
        return okResult(null)
    }

    fun snapshot(): Map<String, Any?> {
        return mapOf(
            "sessions" to sessions.values.map { it.snapshot() },
            "focusedSessionId" to focusedSessionId
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

    private fun createPlayer(sessionId: String): ExoPlayer {
        return ExoPlayer.Builder(this).build().also { player ->
            player.setWakeMode(C.WAKE_MODE_LOCAL)
            player.addListener(object : Player.Listener {
                override fun onPlaybackStateChanged(playbackState: Int) {
                    publishSessionState(sessionId)
                    syncForegroundState()
                }

                override fun onEvents(player: Player, events: Player.Events) {
                    publishSessionState(sessionId)
                }

                override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                    publishSessionState(sessionId)
                    syncForegroundState()
                }

                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    publishSessionState(sessionId)
                    syncForegroundState()
                }

                override fun onPlayerError(error: PlaybackException) {
                    publishSessionState(sessionId)
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
            .setId("AudioPlayer")
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
            startPlaybackForeground()
            acquirePlaybackWakeLock()
            ensureForegroundWatchdog()
        } else {
            stopForegroundWatchdog()
            releasePlaybackWakeLock()
            stopPlaybackForeground(removeNotification = sessions.isEmpty())
        }
    }

    private fun startPlaybackForeground() {
        // audio_service's AudioService provides the foreground notification
        // with transport controls. Since both services run in the same
        // process, this service does not need its own startForeground() call.
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

    private fun acquirePlaybackWakeLock() {
        val existingWakeLock = playbackWakeLock
        if (existingWakeLock?.isHeld == true) {
            existingWakeLock.acquire(PLAYBACK_WAKE_LOCK_TIMEOUT_MS)
            return
        }
        val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        playbackWakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:native_playback"
        ).apply {
            setReferenceCounted(false)
            acquire(PLAYBACK_WAKE_LOCK_TIMEOUT_MS)
        }
    }

    private fun releasePlaybackWakeLock() {
        val wakeLock = playbackWakeLock
        if (wakeLock?.isHeld == true) {
            wakeLock.release()
        }
        playbackWakeLock = null
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
        stateListeners.values.forEach { listener -> listener(snapshot) }
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
        val sessionId: String,
        val player: ExoPlayer
    ) {
        var uri: String? = null
        var title: String = "Audio"
        var subtitle: String? = null
        var artUri: String? = null

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
                "error" to player.playerError?.message
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
