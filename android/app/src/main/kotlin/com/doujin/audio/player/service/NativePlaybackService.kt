@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.doujin.audio.player.service

import com.doujin.audio.channel.*
import com.doujin.audio.common.*
import com.doujin.audio.player.common.*
import com.doujin.audio.player.notification.*
import com.doujin.audio.player.recovery.*
import com.doujin.audio.player.session.*
import com.doujin.audio.player.video.*
import com.doujin.audio.storage.*

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.ComponentName
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.ServiceCompat
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaNotification
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

import java.util.concurrent.ConcurrentHashMap
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger


class NativePlaybackService : MediaSessionService() {
    companion object {
        private const val EXTRA_REQUIRE_FOREGROUND_BOOTSTRAP =
            "require_foreground_bootstrap"
        private const val EXTRA_INTERNAL_START_TOKEN = "internal_start_token"
        private const val PLAYBACK_CHANNEL_ID = "com.doujin.audio.channel.playback"
        private const val PLAYBACK_CHANNEL_NAME = "Playback"
        private const val PLAYBACK_CHANNEL_DESCRIPTION = "Playback notification controls"
        private const val FOREGROUND_NOTIFICATION_ID =
            UnifiedPlaybackNotificationController.foregroundServiceNotificationId
        private const val FOREGROUND_WATCHDOG_INTERVAL_MS = 4 * 60 * 1000L
        private const val STATE_PERSISTENCE_INTERVAL_MS = 15 * 1000L
        private const val STATE_PERSISTENCE_DEBOUNCE_MS = 800L
        private const val PLAYBACK_STOP_GRACE_MS = 10 * 60 * 1000L
        private const val PROGRESS_HEARTBEAT_INTERVAL_MS = 500L
        private const val SCREEN_OFF_PROGRESS_HEARTBEAT_INTERVAL_MS = 5000L
        private const val LOG_TAG = "NativePlaybackService"
        private val internalStartToken = UUID.randomUUID().toString()
        private val pendingCommandDeliveries = AtomicInteger(0)
        private val controllerListeners =
            ConcurrentHashMap<String, (NativePlaybackService?) -> Unit>()

        @Volatile
        private var instance: NativePlaybackService? = null

        @Volatile
        var foregroundSuppressed = false

        @Volatile
        var notificationsDismissed = false

        fun controller(): NativePlaybackService? = instance?.takeIf {
            isPlaybackServiceControllerAvailable(
                instancePresent = true,
                stoppingForIdleExit = it.stoppingForIdleExit
            )
        }

        internal fun addControllerListener(
            ownerId: String,
            listener: (NativePlaybackService?) -> Unit
        ) {
            controllerListeners[ownerId] = listener
        }

        internal fun removeControllerListener(ownerId: String) {
            controllerListeners.remove(ownerId)
        }

        internal fun publishController(service: NativePlaybackService?) {
            controllerListeners.values.forEach { listener ->
                runCatching { listener(service) }
            }
        }

        internal fun beginCommandDelivery() {
            pendingCommandDeliveries.incrementAndGet()
        }

        internal fun endCommandDelivery() {
            val remaining = pendingCommandDeliveries.updateAndGet { current ->
                (current - 1).coerceAtLeast(0)
            }
            if (remaining == 0) {
                controller()?.restoreCoordinator?.onPendingCommandDeliveriesSettled()
            }
        }

        internal fun hasPendingCommandDelivery(): Boolean =
            pendingCommandDeliveries.get() > 0

        fun ensureStarted(
            context: Context,
            requireForegroundBootstrap: Boolean = false
        ): NativePlaybackService? {
            controller()?.let { return it }
            val intent = Intent(context.applicationContext, NativePlaybackService::class.java).apply {
                action = nativePlaybackStartAction
                putExtra(EXTRA_INTERNAL_START_TOKEN, internalStartToken)
                putExtra(EXTRA_REQUIRE_FOREGROUND_BOOTSTRAP, requireForegroundBootstrap)
            }
            return startNativePlaybackService(
                context = context,
                intent = intent,
                requireForegroundBootstrap = requireForegroundBootstrap,
                prepareForegroundFallback = {
                    it.putExtra(EXTRA_REQUIRE_FOREGROUND_BOOTSTRAP, true)
                },
                controller = ::controller
            )
        }
    }

    private val sessions = linkedMapOf<String, NativePlaybackSession>()
    private val fileCacheOperations by lazy { FileCacheOperations(applicationContext) }
    private val stateListeners = ConcurrentHashMap<String, (Map<String, Any?>) -> Unit>()
    private val videoOutputs = NativeVideoOutputRegistry<Player>(
        playerForSession = { sessionId -> sessions[sessionId]?.playerOrNull() },
        shouldKeepScreenOn = { player ->
            player.playWhenReady &&
                player.playbackState != Player.STATE_IDLE &&
                player.playbackState != Player.STATE_ENDED
        }
    )
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile
    private var stoppingForIdleExit = false
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
            hasActivePlayback = ::hasActivePlayback,
            storedSessions = {
                val intendedSessionIds = playbackRecovery.intendedSessionIds
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
    private val mediaSessionHost by lazy {
        NativeMediaSessionHost(
            context = this,
            candidate = ::mediaSessionCandidate,
            handlePlayerCommandRequest = ::handleMediaSessionPlayerCommandRequest,
            logSecurityEvent = ::logSecurityEvent,
            logInfo = ::logInfo,
            logWarn = { message, error -> logWarn(message, error = error) }
        )
    }
    private val progressHeartbeat by lazy {
        NativePlaybackProgressHeartbeatCoordinator(
            host = object : NativePlaybackProgressHeartbeatHost {
                override fun shouldRunProgressHeartbeat(): Boolean =
                    stateListeners.isNotEmpty() && sessions.isNotEmpty()

                override fun publishProgress(nowElapsedRealtimeMs: Long) {
                    progressPublisher.publishAsync(nowElapsedRealtimeMs)
                }
            },
            environment = AndroidNativePlaybackProgressHeartbeatEnvironment(this, mainHandler),
            screenOnIntervalMs = PROGRESS_HEARTBEAT_INTERVAL_MS,
            screenOffIntervalMs = SCREEN_OFF_PROGRESS_HEARTBEAT_INTERVAL_MS,
            keepAliveHost = object : NativePlaybackKeepAliveHeartbeatHost {
                override val hasPlaybackToKeepAlive: Boolean
                    get() = this@NativePlaybackService.hasPlaybackToKeepAlive()
                override val foregroundStarted: Boolean
                    get() = foregroundCoordinator.isStarted
                override val focusInterrupted: Boolean
                    get() = focusRecovery.interruptionActive
                override fun refreshWakeLock() = playbackWakeLock.refresh()
                override fun triggerRecovery(reason: String) = playbackRecovery.trigger(reason)
                override fun expireGraceIfOverdue(): Boolean =
                    foregroundCoordinator.expireGraceIfOverdue()
                override fun syncForeground() = syncForegroundState()
                override fun cancelAlarm() =
                    PlaybackKeepAliveAlarmScheduler.cancel(this@NativePlaybackService)
                override fun ensureAlarm() =
                    PlaybackKeepAliveAlarmScheduler.ensureScheduled(this@NativePlaybackService)
                override fun logHeartbeat() {
                    logInfo(
                        "keep_alive_heartbeat wakeLockHeld=${playbackWakeLock.isHeld()} " +
                            "playback=${hasPlaybackToKeepAlive()} " +
                            "foregroundStarted=${foregroundCoordinator.isStarted}"
                    )
                }
            }
        )
    }
    private val restoreCoordinator by lazy {
        NativePlaybackRestoreCoordinator(
            environment = AndroidNativePlaybackRestoreEnvironment(
                context = applicationContext,
                mainHandler = mainHandler
            ),
            restoreSessions = { storedSessions, autoPlay, onRestored ->
                sessionRestorer.restore(storedSessions, autoPlay, onRestored)
            },
            resumePlaybackOnStartupRestore = {
                playbackBehavior.resumePlaybackOnStartupRestore
            },
            requestAudioFocus = { focusRecovery.requestIfNeeded() },
            startBootstrap = foregroundCoordinator::startBootstrap,
            resetRestoreState = {
                notificationsDismissed = false
                playbackSuspended = false
            },
            completeRestore = { restoredSessionIds, autoPlay ->
                if (autoPlay) {
                    restoredSessionIds.forEach(::markPlaybackIntended)
                } else {
                    restoredSessionIds.forEach(::clearPlaybackIntent)
                }
                evictPlayersIfNeeded()
                restoredSessionIds.forEach(::publishSessionState)
                progressHeartbeat.ensure()
                ensureStatePersistenceTicker()
                persistSessionStateNow()
                syncForegroundState()
            },
            hasSessions = { sessions.isNotEmpty() },
            hasPlaybackToKeepAlive = ::hasPlaybackToKeepAlive,
            hasPendingCommandDelivery = ::hasPendingCommandDelivery,
            stopIdleService = ::stopIdleServiceAfterRestore,
            onTimerSessionsRestored = { restoredSessionIds ->
                restoredSessionIds.forEach(::publishSessionState)
                evictPlayersIfNeeded()
                persistSessionStateNow()
            },
            onNotificationSessionRestored = ::publishSessionState,
            logInfo = ::logInfo
        )
    }

    fun currentMediaSession(): MediaSession? = mediaSessionHost.current()

    var focusedSessionId: String? = null
        private set
    private var playbackSuspended = false
    private val audioFocusController: NativeAudioFocusController by lazy {
        NativeAudioFocusController(
            context = applicationContext,
            handler = mainHandler,
            logInfo = ::logInfo,
            logWarn = { message, error -> logWarn(message, error = error) },
            onFocusChange = { focusRecovery.onFocusChange(it) }
        )
    }
    private val focusRecovery: NativePlaybackFocusRecoveryCoordinator by lazy {
        NativePlaybackFocusRecoveryCoordinator(
            host = object : NativePlaybackFocusRecoveryHost {
                override val behavior: StoredPlaybackBehavior
                    get() = playbackBehavior
                override val playbackSuspended: Boolean
                    get() = this@NativePlaybackService.playbackSuspended
                override fun activePlaybackSessionIds(): List<String> = sessions.values
                    .filter { it.playerOrNull()?.let { player ->
                        player.isPlaying || player.playWhenReady
                    } == true }
                    .map(NativePlaybackSession::sessionId)
                override fun sessionExists(sessionId: String): Boolean =
                    sessions.containsKey(sessionId)
                override fun pause(sessionId: String) {
                    sessions[sessionId]?.playerOrNull()?.pause()
                }
                override fun play(sessionId: String) {
                    sessions[sessionId]?.let { ensureFocusedPlayer(it).play() }
                }
                override fun focus(sessionId: String) = focusSession(sessionId)
                override fun clearPlaybackIntent(sessionId: String) =
                    this@NativePlaybackService.clearPlaybackIntent(sessionId)
                override fun clearAllPlaybackRecovery() = playbackRecovery.clearAll()
                override fun applyFocusDuckMultiplier(multiplier: Float) {
                    sessions.values.forEach { it.applyFocusDuckMultiplier(multiplier) }
                }
                override fun publishAllSessions() = publishAllSessionStates()
                override fun persistNow() = persistSessionStateNow()
                override fun schedulePersist() = schedulePersistSessionState()
                override fun syncForeground() = syncForegroundState()
                override fun ensureProgressHeartbeat() = progressHeartbeat.ensure()
                override fun logInfo(message: String) = this@NativePlaybackService.logInfo(message)
            },
            audioFocus = audioFocusController
        )
    }
    private val audioDeviceDisconnectMonitor by lazy {
        NativePlaybackAudioDeviceDisconnectMonitor(
            context = applicationContext,
            onDisconnected = focusRecovery::onAudioDeviceDisconnected
        )
    }
    private val playbackRecovery: NativePlaybackRecoveryController by lazy {
        NativePlaybackRecoveryController(
            host = object : NativePlaybackRecoveryHost {
                override fun session(sessionId: String) = sessions[sessionId]
                override fun requestAudioFocus() = focusRecovery.requestIfNeeded()
                override fun focusSession(sessionId: String) = this@NativePlaybackService.focusSession(sessionId)
                override fun ensurePlayer(session: NativePlaybackSession) = ensureFocusedPlayer(session)
                override fun publishSession(sessionId: String) {
                    publishSessionState(sessionId)
                }
                override fun publishAllSessions() = publishAllSessionStates()
                override fun persistNow() = persistSessionStateNow()
                override fun schedulePersist() = schedulePersistSessionState()
                override fun syncForeground() = syncForegroundState()
                override fun logInfo(message: String, session: NativePlaybackSession?) =
                    this@NativePlaybackService.logInfo(message, session)

                override fun logWarn(
                    message: String,
                    session: NativePlaybackSession?,
                    error: PlaybackException?
                ) = this@NativePlaybackService.logWarn(message, session, error)
            },
            environment = AndroidNativePlaybackRecoveryEnvironment(
                context = this,
                handler = mainHandler,
                logWarn = { message, error -> logWarn(message, error = error) }
            ),
        )
    }
    private val foregroundCoordinator by lazy {
        NativePlaybackForegroundCoordinator(
            host = object : NativePlaybackForegroundHost {
                override val hasPlaybackToKeepAlive: Boolean
                    get() = this@NativePlaybackService.hasPlaybackToKeepAlive()
                override val hasSessions: Boolean
                    get() = sessions.isNotEmpty()
                override val playbackSuspended: Boolean
                    get() = this@NativePlaybackService.playbackSuspended
                override val foregroundSuppressed: Boolean
                    get() = NativePlaybackService.foregroundSuppressed

                override fun playbackSignature(): String? {
                    val foregroundSession = foregroundSession() ?: return null
                    return if (usesUnifiedForegroundNotification()) {
                        "unified|$FOREGROUND_NOTIFICATION_ID|" +
                            foregroundSession.foregroundNotificationSignature()
                    } else {
                        foregroundSession.foregroundNotificationSignature()
                    }
                }

                override fun onActiveSync() {
                    acquireWakeLock()
                    PlaybackKeepAliveAlarmScheduler.ensureScheduled(
                        this@NativePlaybackService
                    )
                    if (!focusRecovery.interruptionActive) {
                        focusRecovery.requestIfNeeded()
                        if (focusRecovery.resumePendingIfPossible("foreground_sync_focus_available")) {
                            schedulePersistSessionState()
                        }
                    }
                    ensureStatePersistenceTicker()
                }

                override fun onIdleGraceBegan() {
                    releaseWakeLock()
                    PlaybackKeepAliveAlarmScheduler.ensureScheduled(
                        this@NativePlaybackService
                    )
                    persistSessionStateNow()
                }

                override fun isForegroundNotificationPosted(): Boolean? =
                    isPlaybackNotificationPosted()

                override fun onSuppressedIdle() {
                    focusRecovery.abandon(reason = "suppressed_no_active_playback")
                    releaseWakeLock()
                    PlaybackKeepAliveAlarmScheduler.cancel(this@NativePlaybackService)
                    persistSessionStateNow()
                }

                override fun onGraceExpired() {
                    focusRecovery.abandon(reason = "grace_expired_no_active_playback")
                    releaseWakeLock()
                    PlaybackKeepAliveAlarmScheduler.cancel(this@NativePlaybackService)
                    persistSessionStateNow()
                }

                override fun onWatchdog() {
                    playbackWakeLock.refresh()
                    PlaybackKeepAliveAlarmScheduler.ensureScheduled(
                        this@NativePlaybackService
                    )
                    if (!focusRecovery.interruptionActive) {
                        playbackRecovery.trigger("foreground_watchdog")
                    }
                }

                override fun startPlaybackForeground() {
                    val foregroundSession = foregroundSession()
                        ?: error("No playback session is available for foreground notification")
                    ServiceCompat.startForeground(
                        this@NativePlaybackService,
                        FOREGROUND_NOTIFICATION_ID,
                        foregroundNotificationFactory.buildPlaybackNotification(
                            sessionId = foregroundSession.sessionId,
                            title = foregroundSession.title,
                            subtitle = foregroundSession.subtitle,
                            mediaSession = ensureFocusedMediaSession(),
                            playing = foregroundSession.playerOrNull()?.let { player ->
                                player.isPlaying || player.playWhenReady
                            } ?: false,
                            hasPrevious = foregroundSession.hasPreviousMediaItem(),
                            hasNext = foregroundSession.hasNextMediaItem()
                        ),
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                    )
                }

                override fun startBootstrapForeground() {
                    mediaSessionHost.ensureBootstrap()
                    ServiceCompat.startForeground(
                        this@NativePlaybackService,
                        FOREGROUND_NOTIFICATION_ID,
                        foregroundNotificationFactory.buildBootstrapNotification(
                            currentMediaSession()
                        ),
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                    )
                    acquireWakeLock()
                }

                override fun shouldRemoveForegroundNotification(
                    removeNotification: Boolean
                ): Boolean =
                    UnifiedPlaybackNotificationController.shouldRemoveForegroundNotification(
                        removeNotification
                    )

                override fun stopForeground(wasStarted: Boolean, removeNotification: Boolean) {
                    if (wasStarted) {
                        stopForegroundCompat(removeNotification = removeNotification)
                    }
                    if (removeNotification) {
                        val manager =
                            getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                        manager?.cancel(FOREGROUND_NOTIFICATION_ID)
                    }
                }

                override fun logInfo(message: String) {
                    this@NativePlaybackService.logInfo(message, foregroundSession())
                }

                override fun logWarn(message: String, error: Throwable) {
                    this@NativePlaybackService.logWarn(
                        message,
                        foregroundSession(),
                        error
                    )
                }
            },
            environment = object : NativePlaybackForegroundEnvironment {
                override fun postDelayed(runnable: Runnable, delayMs: Long) {
                    mainHandler.postDelayed(runnable, delayMs)
                }

                override fun remove(runnable: Runnable) {
                    mainHandler.removeCallbacks(runnable)
                }

                override fun elapsedRealtimeMs(): Long = SystemClock.elapsedRealtime()
            },
            stopGraceMs = PLAYBACK_STOP_GRACE_MS,
            watchdogIntervalMs = FOREGROUND_WATCHDOG_INTERVAL_MS
        )
    }
    private var attemptedStickyPlaybackRestore = false
    private var playbackBehavior = StoredPlaybackBehavior()
    override fun onCreate() {
        super.onCreate()
        playbackBehavior = NativePlaybackStateStore.loadPlaybackBehavior(this)
        audioDeviceDisconnectMonitor.start()
        progressHeartbeat.start()
        foregroundNotificationFactory.ensureChannel(
            PLAYBACK_CHANNEL_NAME,
            PLAYBACK_CHANNEL_DESCRIPTION
        )
        instance = this
        publishController(this)
        logInfo("on_create")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val startDecision = nativePlaybackStartDecision(
            intent = intent,
            expectedToken = internalStartToken,
            tokenExtra = EXTRA_INTERNAL_START_TOKEN,
            bootstrapExtra = EXTRA_REQUIRE_FOREGROUND_BOOTSTRAP,
            onUnreadableExtras = {
                logSecurityEvent("playback_service_start_extras_unreadable", null)
            }
        )
        if (!startDecision.accepted) {
            logSecurityEvent(
                "playback_service_start_rejected reason=${startDecision.rejectionReason}",
                null
            )
            return rejectedStartResult(startId)
        }
        restoreCoordinator.acceptStart(startId)
        if (stoppingForIdleExit) {
            stoppingForIdleExit = false
            publishController(this)
        }
        super.onStartCommand(intent, flags, startId)
        if (startDecision.requireForegroundBootstrap) {
            logInfo("on_start_command foreground_bootstrap_requested")
            foregroundCoordinator.startBootstrap()
        }
        if (startDecision.shouldAttemptRestore &&
            shouldAttemptStickyPlaybackRestore(sessions.isNotEmpty(), attemptedStickyPlaybackRestore)
        ) {
            attemptedStickyPlaybackRestore = true
            restoreCoordinator.restoreAfterServiceRestart(startId)
        }
        return START_STICKY
    }

    private fun rejectedStartResult(startId: Int): Int {
        if (sessions.isNotEmpty() || hasPlaybackToKeepAlive() || foregroundCoordinator.isStarted) {
            return START_STICKY
        }
        stopSelfResult(startId)
        return START_NOT_STICKY
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        ensureMediaSession()

    override fun onUpdateNotification(session: MediaSession, startInForeground: Boolean) {
        // Foreground state and notifications are owned by the dedicated
        // coordinator. Letting Media3 publish here can call stopForeground()
        // and suspend screen-off playback under Doze.
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        logInfo("on_task_removed hasActivePlayback=${hasPlaybackToKeepAlive()}")
        if (foregroundCoordinator.onTaskRemoved()) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        logInfo(
            "on_destroy_begin sessions=${sessions.size} " +
                "foregroundStarted=${foregroundCoordinator.isStarted} " +
                "wakeLockHeld=${playbackWakeLock.isHeld()}"
        )
        var firstFailure = runPlaybackShutdownActions(
            listOf(
                stateListeners::clear,
                videoOutputs::clear,
                restoreCoordinator::shutdown,
                audioDeviceDisconnectMonitor::shutdown,
                progressHeartbeat::shutdown,
                progressPublisher::shutdown,
                statePersistence::shutdown,
                playbackRecovery::dispose,
                { mediaSessionHost.release("on_destroy") },
                {
                    runPlaybackShutdownActions(sessions.values.map { session -> session::release })
                        ?.let { throw it }
                },
                sessions::clear,
                foregroundCoordinator::shutdown,
                { focusRecovery.abandon(reason = "on_destroy") },
                ::releaseWakeLock,
                { PlaybackKeepAliveAlarmScheduler.cancel(this) },
                {
                    if (instance === this) {
                        instance = null
                        publishController(null)
                    }
                }
            )
        )
        try {
            super.onDestroy()
        } catch (error: Throwable) {
            if (firstFailure == null) firstFailure = error
        }
        logInfo("on_destroy_end")
        firstFailure?.let { throw it }
    }

    fun addStateListener(ownerId: String, listener: (Map<String, Any?>) -> Unit) {
        stateListeners[ownerId] = listener
        sessions.values.forEach { listener(it.snapshot()) }
        progressHeartbeat.ensure()
    }

    fun removeStateListener(ownerId: String) {
        stateListeners.remove(ownerId)
        progressHeartbeat.stopIfUnobserved()
    }

    internal fun registerVideoOutput(
        sessionId: String,
        ownerId: String,
        output: NativeVideoOutputBinding<Player>
    ) {
        videoOutputs.register(sessionId, ownerId, output)
    }

    internal fun refreshVideoOutput(
        sessionId: String,
        ownerId: String,
        forceRebind: Boolean = false
    ): Boolean {
        return videoOutputs.refresh(sessionId, ownerId, forceRebind)
    }

    internal fun unregisterVideoOutput(sessionId: String, ownerId: String) {
        videoOutputs.unregister(sessionId, ownerId)
    }

    internal fun settleForegroundAfterBridgeAttach() {
        syncForegroundState()
    }

    internal fun prepareSession(args: NativePrepareSessionArguments): Map<String, Any?> {
        val sessionId = args.sessionId
        val queue = args.queue.toMutableList()
        if (args.candidateUris.isNotEmpty()) {
            val currentIndex = args.queueStartIndex.coerceIn(0, queue.lastIndex)
            queue[currentIndex] = queue[currentIndex]
                .withPlaybackCandidateUris(args.candidateUris)
        }
        val shouldAutoPlay = shouldAutoPlayWithAudioFocus(args.autoPlay) {
            focusRecovery.requestIfNeeded()
        }
        val autoPlayFocusDenied = args.autoPlay && !shouldAutoPlay
        if (shouldAutoPlay) {
            notificationsDismissed = false
            playbackSuspended = false
            markPlaybackIntended(sessionId)
        } else {
            clearPlaybackIntent(sessionId)
        }

        val nativeSession = sessions.getOrPut(sessionId) {
            createNativePlaybackSession(sessionId)
        }
        focusRecovery.removePending(sessionId)
        return try {
            nativeSession.applyAudioEffects(args.audioEffects)
            nativeSession.configure(
                descriptor = queue[args.queueStartIndex],
                queue = queue,
                queueStartIndex = args.queueStartIndex,
                startPositionMs = args.startPositionMs,
                volume = args.volume,
                speed = args.speed,
                repeatOne = args.repeatOne,
                repeatAll = args.repeatAll,
                shuffleModeEnabled = args.shuffle,
                autoPlay = shouldAutoPlay,
                deferPlayerCreation = args.deferPlayerCreation
            )
            if (!args.deferPlayerCreation) {
                focusSession(sessionId)
                ensureFocusedMediaSession()
            }
            evictPlayersIfNeeded()
            publishSessionState(sessionId)
            progressHeartbeat.ensure()
            persistSessionStateNow()
            ensureStatePersistenceTicker()
            syncForegroundState()
            if (autoPlayFocusDenied) {
                errorResult("Audio focus was denied.")
            } else {
                okResult(nativeSession.snapshot())
            }
        } catch (e: Exception) {
            sessions.remove(sessionId)
            nativeSession.release()
            clearPlaybackIntent(sessionId)
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
        if (!focusRecovery.requestIfNeeded()) {
            clearPlaybackIntent(sessionId)
            session.playerOrNull()?.pause()
            publishSessionState(sessionId)
            return errorResult("Audio focus was denied.")
        }
        val pausedSessionIds = if (exclusive) {
            exclusivePlaybackSessionIdsToPause(
                targetSessionId = sessionId,
                sessionPlaybackIntent = sessions.mapValues { (candidateId, candidate) ->
                    val player = candidate.playerOrNull()
                    playbackRecovery.isIntended(candidateId) ||
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
            focusRecovery.removePending(pausedSessionId)
            clearPlaybackIntent(pausedSessionId)
            pausedSession.playerOrNull()?.pause()
        }
        session.lastUsedMs = System.currentTimeMillis()
        if (transportCommandId > 0L) {
            session.transportCommandId = transportCommandId
        }
        focusRecovery.removePending(sessionId)
        notificationsDismissed = false
        playbackSuspended = false
        val playerBeforePlay = session.playerOrNull()
        val needsImmediateRecovery = playerBeforePlay != null &&
            (playerBeforePlay.playerError != null ||
                playerBeforePlay.playbackState == Player.STATE_IDLE)
        markPlaybackIntended(sessionId)
        session.applyFadeMultiplier(1f)
        session.applyFocusDuckMultiplier(1f)
        focusSession(sessionId)
        if (needsImmediateRecovery) {
            playbackRecovery.retryNow(sessionId, "user_retry")
        }
        ensureFocusedPlayer(session).play()
        evictPlayersIfNeeded()
        pausedSessionIds.forEach(::publishSessionState)
        val snapshot = publishSessionState(sessionId)
        progressHeartbeat.ensure()
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
        focusRecovery.removePending(sessionId)
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
        focusRecovery.removePending(sessionId)
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
        playbackRecovery.resetHealth(sessionId, "skip_next", cancelRecovery = true)
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
        playbackRecovery.resetHealth(sessionId, "skip_previous", cancelRecovery = true)
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
        focusRecovery.removePending(sessionId)
        notificationsDismissed = false
        playbackSuspended = false
        focusSession(sessionId)
        val player = ensureFocusedPlayer(session)
        if (player.playWhenReady) {
            clearPlaybackIntent(sessionId)
            player.pause()
        } else {
            if (!focusRecovery.requestIfNeeded()) {
                clearPlaybackIntent(sessionId)
                player.pause()
                publishSessionState(sessionId)
                return errorResult("Audio focus was denied.")
            }
            markPlaybackIntended(sessionId)
            session.applyFadeMultiplier(1f)
            session.applyFocusDuckMultiplier(1f)
            player.play()
        }
        evictPlayersIfNeeded()
        publishSessionState(sessionId)
        progressHeartbeat.ensure()
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
        restoreCoordinator.restoreSessionForNotification(
            sessionId = sessionId,
            loadedSessions = storedSessions,
            sessionExists = sessions.containsKey(sessionId)
        )
        return when (action) {
            NotificationCommand.toggle.actionName -> togglePlayPause(sessionId)
            NotificationCommand.previous.actionName -> skipToPrevious(sessionId)
            NotificationCommand.next.actionName -> skipToNext(sessionId)
            else -> errorResult("Unknown notification action")
        }
    }

    fun seek(sessionId: String, positionMs: Long): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        playbackRecovery.resetHealth(sessionId, "seek", cancelRecovery = true)
        session.seekTo(positionMs)
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
        return okResult(session.snapshot())
    }

    fun setSpeed(sessionId: String, speed: Float): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.applySpeed(speed)
        publishSessionState(sessionId)
        schedulePersistSessionState()
        return okResult(session.snapshot())
    }

    fun setTemporarySpeed(sessionId: String, speed: Float?): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.applyTemporarySpeed(speed)
        publishSessionState(sessionId)
        return okResult(session.snapshot())
    }

    fun clearTemporarySpeeds() {
        sessions.values.forEach { session ->
            session.applyTemporarySpeed(null)
            session.snapshot()
        }
    }

    internal fun setAudioEffects(sessionId: String, effects: NativeAudioEffects): Map<String, Any?> {
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        val previousChannelSwap = session.channelSwapEnabled
        session.applyAudioEffects(effects)
        if (shouldEnsurePlayerForAudioEffects(effects, session.hasPlayer())) {
            session.ensurePlayer()
        }
        if (previousChannelSwap != session.channelSwapEnabled) {
            session.reprepareCurrentMediaItem()
        }
        publishSessionState(sessionId)
        schedulePersistSessionState()
        syncForegroundState()
        return okResult(session.snapshot())
    }

    internal fun setRepeatOne(args: NativeRepeatOneArguments): Map<String, Any?> {
        val sessionId = args.sessionId
        val repeatOne = args.repeatOne
        val session = sessions[sessionId] ?: return errorResult("Unknown session.")
        session.lastUsedMs = System.currentTimeMillis()
        session.repeatOne = repeatOne
        val queue = args.queue
        if (queue.isNotEmpty()) {
            session.updateQueue(
                queue = queue,
                queueStartIndex = args.queueStartIndex,
                repeatOne = repeatOne,
                repeatAll = args.repeatAll,
                shuffleModeEnabled = args.shuffle
            )
        } else {
            session.repeatAll = args.repeatAll
            session.shuffleModeEnabled = args.shuffle
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
        focusRecovery.removePending(sessionId)
        clearPlaybackIntent(sessionId)
        val removed = sessions.remove(sessionId) ?: return okResult(null)
        removed.release()
        if (focusedSessionId == sessionId) {
            focusedSessionId = sessions.keys.firstOrNull()
            updateMediaSessionPlayer()
        }
        if (sessions.isEmpty()) {
            foregroundCoordinator.cancelGrace()
            foregroundCoordinator.stopWatchdog()
            stopStatePersistenceTicker()
            cancelScheduledPersistSessionState()
            NativePlaybackStateStore.clearSessions(this)
            NativePlaybackStateStore.clearPausedSessionIds(this)
            NativePlaybackStateStore.clearTimerCandidateSessionIds(this)
            NativePlaybackStateStore.clearTimerRuntimeState(this)
            mediaSessionHost.release("remove_session_empty")
            focusRecovery.abandon(reason = "remove_session_empty")
            PlaybackKeepAliveAlarmScheduler.cancel(this)
            foregroundCoordinator.stop(reason = "remove_session_empty", removeNotification = true)
            stopSelf()
        } else {
            persistSessionStateNow()
            syncForegroundState()
        }
        return okResult(null)
    }

    fun pauseAll(): Map<String, Any?> {
        notificationsDismissed = true
        focusRecovery.clearInterruptionState()
        playbackRecovery.clearAll()
        sessions.values.forEach { it.playerOrNull()?.pause() }
        evictPlayersIfNeeded()
        publishAllSessionStates()
        persistSessionStateNow()
        foregroundCoordinator.cancelGrace()
        foregroundCoordinator.stopWatchdog()
        playbackSuspended = true
        focusRecovery.abandon(reason = "pause_all")
        releaseWakeLock()
        PlaybackKeepAliveAlarmScheduler.cancel(this)
        foregroundCoordinator.stop(reason = "pause_all", removeNotification = sessions.isEmpty())
        return okResult(null)
    }

    fun clearAll(): Map<String, Any?> {
        notificationsDismissed = true
        focusRecovery.clearInterruptionState()
        playbackRecovery.clearAll()
        sessions.values.forEach { it.release() }
        sessions.clear()
        focusedSessionId = null
        mediaSessionHost.release("clear_all")
        foregroundCoordinator.cancelGrace()
        foregroundCoordinator.stopWatchdog()
        stopStatePersistenceTicker()
        cancelScheduledPersistSessionState()
        NativePlaybackStateStore.clearSessions(this)
        NativePlaybackStateStore.clearPausedSessionIds(this)
        NativePlaybackStateStore.clearTimerCandidateSessionIds(this)
        NativePlaybackStateStore.clearTimerRuntimeState(this)
        focusRecovery.abandon(reason = "clear_all")
        PlaybackKeepAliveAlarmScheduler.cancel(this)
        foregroundCoordinator.stop(reason = "clear_all", removeNotification = true)
        stopSelf()
        return okResult(null)
    }

    fun snapshot(): Map<String, Any?> {
        val response = okResult(
            mapOf(
                "sessions" to sessions.values.map {
                    it.snapshot(includeRetainedUris = true)
                },
                "focusedSessionId" to focusedSessionId
            )
        )
        syncForegroundState()
        return response
    }

    fun setPlaybackBehavior(
        pauseOnAudioDeviceDisconnect: Boolean,
        requestAudioFocus: Boolean,
        pauseOnTransientAudioFocusLoss: Boolean,
        resumeAfterTransientAudioFocusGain: Boolean,
        resumePlaybackOnStartupRestore: Boolean
    ): Map<String, Any?> {
        val previouslyRequestedAudioFocus = playbackBehavior.requestAudioFocus
        playbackBehavior = StoredPlaybackBehavior(
            pauseOnAudioDeviceDisconnect = pauseOnAudioDeviceDisconnect,
            requestAudioFocus = requestAudioFocus,
            pauseOnTransientAudioFocusLoss = pauseOnTransientAudioFocusLoss,
            resumeAfterTransientAudioFocusGain = resumeAfterTransientAudioFocusGain,
            resumePlaybackOnStartupRestore = resumePlaybackOnStartupRestore
        )
        NativePlaybackStateStore.savePlaybackBehavior(this, playbackBehavior)
        if (!requestAudioFocus) {
            focusRecovery.abandon(reason = "mix_with_others_enabled")
            publishAllSessionStates()
            schedulePersistSessionState()
        } else if (!previouslyRequestedAudioFocus && hasActivePlayback()) {
            if (!focusRecovery.requestIfNeeded()) {
                logInfo("audio_focus_policy_restore_denied")
                focusRecovery.onFocusChange(AudioManager.AUDIOFOCUS_LOSS)
            }
        }
        return okResult(null)
    }

    fun setForegroundEnabled(enabled: Boolean): Map<String, Any?> {
        foregroundSuppressed = !enabled
        if (!enabled) {
            notificationsDismissed = true
            if (hasPlaybackToKeepAlive()) {
                acquireWakeLock()
                updateMediaSessionPlayer()
                focusRecovery.requestIfNeeded()
                foregroundCoordinator.startOrUpdate(forceRefresh = true)
                foregroundCoordinator.ensureWatchdog()
            } else {
                foregroundCoordinator.stopWatchdog()
                foregroundCoordinator.stop(
                    reason = "foreground_disabled_no_active_playback",
                    removeNotification = true
                )
            }
        } else {
            notificationsDismissed = false
            updateMediaSessionPlayer()
            if (hasPlaybackToKeepAlive()) {
                acquireWakeLock()
                focusRecovery.requestIfNeeded()
                foregroundCoordinator.startOrUpdate(forceRefresh = true)
                foregroundCoordinator.ensureWatchdog()
            }
        }
        return okResult(null)
    }

    fun dismissNotifications(): Map<String, Any?> {
        notificationsDismissed = true
        if (hasPlaybackToKeepAlive()) {
            foregroundCoordinator.startOrUpdate(forceRefresh = true)
            foregroundCoordinator.ensureWatchdog()
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
        focusRecovery.clearTransientLoss()
        pausedSessionIds.forEach { sessionId ->
            focusRecovery.removePending(sessionId)
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

    internal fun resumeSessionsForTimer(sessionIds: List<String>): NativeTimerResumeResult {
        if (sessionIds.isEmpty()) {
            return NativeTimerResumeResult(emptyList(), audioFocusDenied = false)
        }
        if (!focusRecovery.requestIfNeeded()) {
            return NativeTimerResumeResult(emptyList(), audioFocusDenied = true)
        }
        restoreCoordinator.restoreSessionsForTimer(sessionIds, sessions.keys)
        notificationsDismissed = false
        playbackSuspended = false
        val resumedSessionIds = mutableListOf<String>()
        sessionIds.forEach { sessionId ->
            focusRecovery.removePending(sessionId)
            val session = sessions[sessionId] ?: return@forEach
            markPlaybackIntended(sessionId)
            session.applyFadeMultiplier(1f)
            focusSession(sessionId)
            ensureFocusedPlayer(session).play()
            resumedSessionIds += sessionId
        }
        if (resumedSessionIds.isNotEmpty()) {
            progressHeartbeat.ensure()
            ensureStatePersistenceTicker()
            publishAllSessionStates()
            persistSessionStateNow()
        }
        syncForegroundState()
        return NativeTimerResumeResult(resumedSessionIds, audioFocusDenied = false)
    }

    private fun evictPlayersIfNeeded() {
        val idleSessions = sessions.values
            .filter { session ->
                val player = session.playerOrNull() ?: return@filter false
                !player.isPlaying &&
                    !player.playWhenReady &&
                    !playbackRecovery.isIntended(session.sessionId) &&
                    !focusRecovery.isPending(session.sessionId) &&
                    !playbackRecovery.isPending(session.sessionId)
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
        playbackRecovery.resetHealth(sessionId, "media_item_transition")
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
        if (shouldClearPlaybackIntentForPlayWhenReadyChange(playWhenReady, reason)) {
            focusRecovery.removePending(sessionId)
            clearPlaybackIntent(sessionId)
        }
        focusRecovery.onPlayWhenReadyChanged(sessionId, playWhenReady, reason)
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
        if (isPlaying) {
            playbackRecovery.onPlaying(sessionId)
            PlaybackTimerAlarmScheduler.onPlaybackStarted(this, sessionId)
        }
        publishSessionState(sessionId)
        schedulePersistSessionState()
        syncForegroundState()
    }

    private fun handlePlayerError(sessionId: String, error: PlaybackException) {
        focusRecovery.removePending(sessionId)
        playbackRecovery.onPlayerError(
            sessionId = sessionId,
            recoverable = isRecoverablePlaybackErrorCode(error.errorCode),
            candidateFallbackEligible = isCandidateFallbackPlaybackErrorCode(error.errorCode),
            errorCodeName = error.errorCodeName,
            errorMessage = error.message,
            causeDescription = "${error.cause?.javaClass?.simpleName}:${error.cause?.message}",
            technicalError = error
        )
    }

    private fun focusSession(sessionId: String) {
        val session = sessions[sessionId] ?: return
        session.lastUsedMs = System.currentTimeMillis()
        if (focusedSessionId == sessionId) return
        focusedSessionId = sessionId
        updateMediaSessionPlayer()
    }

    private fun ensureMediaSession(): MediaSession? = mediaSessionHost.ensure()

    private fun updateMediaSessionPlayer() = mediaSessionHost.update(sessions.isNotEmpty())

    private fun ensureFocusedPlayer(session: NativePlaybackSession): ExoPlayer =
        mediaSessionHost.ensurePlayer(session, sessions.isNotEmpty())

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

    private fun handleMediaSessionPlayerCommandRequest(
        command: Int,
        playWhenReady: Boolean
    ): Int {
        val session = mediaSessionCandidate()
        return com.doujin.audio.player.session.handleMediaSessionPlayerCommandRequest(
            command = command,
            playWhenReady = playWhenReady,
            requestAudioFocus = {
                session != null && focusRecovery.requestIfNeeded()
            },
            markPlaybackIntended = {
                if (session != null) {
                    focusRecovery.removePending(session.sessionId)
                    notificationsDismissed = false
                    playbackSuspended = false
                    focusSession(session.sessionId)
                    markPlaybackIntended(session.sessionId)
                }
            },
            clearPlaybackIntent = {
                if (session != null) {
                    focusRecovery.removePending(session.sessionId)
                    clearPlaybackIntent(session.sessionId)
                }
            }
        )
    }

    private fun hasActivePlayback(): Boolean {
        return sessions.values.any { 
            val p = it.playerOrNull()
            p != null && (p.isPlaying || p.playWhenReady)
        }
    }

    private fun markPlaybackIntended(sessionId: String) {
        playbackRecovery.markIntended(sessionId)
    }

    private fun clearPlaybackIntent(sessionId: String) {
        playbackRecovery.clear(sessionId)
    }
    private fun hasPlaybackToKeepAlive(): Boolean {
        return hasActivePlayback() ||
            focusRecovery.hasPendingResume() ||
            playbackRecovery.shouldKeepAlive()
    }
    private fun foregroundSession(): NativePlaybackSession? =
        sessions[focusedSessionId]
            ?: sessions.values.firstOrNull { session ->
                val player = session.playerOrNull()
                player != null && (player.isPlaying || player.playWhenReady)
            }
            ?: sessions.values.firstOrNull()

    private fun usesUnifiedForegroundNotification(): Boolean =
        !notificationsDismissed &&
            !foregroundSuppressed &&
            UnifiedPlaybackNotificationController.hasUnifiedNotifications()

    private fun syncForegroundState() {
        if (shouldClearAudioFocusInterruptionState(hasPlaybackToKeepAlive())) {
            focusRecovery.clearInterruptionState()
        }
        syncStatePersistenceTicker()
        foregroundCoordinator.sync()
    }

    private fun stopForegroundCompat(removeNotification: Boolean) {
        val behavior = if (removeNotification) {
            STOP_FOREGROUND_REMOVE
        } else {
            STOP_FOREGROUND_DETACH
        }
        stopForeground(behavior)
    }

    private fun ensureStatePersistenceTicker() = statePersistence.ensureTicker()

    private fun syncStatePersistenceTicker() = statePersistence.onPlaybackActivityChanged()

    private fun stopStatePersistenceTicker() = statePersistence.stopTicker()

    private fun schedulePersistSessionState() = statePersistence.schedulePersist()

    private fun cancelScheduledPersistSessionState() = statePersistence.cancelScheduledPersist()

    private fun persistSessionStateNow() = statePersistence.persistNow()

    private fun stopIdleServiceAfterRestore(startId: Int, reason: String) {
        progressHeartbeat.stop()
        foregroundCoordinator.cancelGrace()
        foregroundCoordinator.stopWatchdog()
        stopStatePersistenceTicker()
        cancelScheduledPersistSessionState()
        playbackRecovery.clearAll()
        mediaSessionHost.release(reason)
        focusRecovery.abandon(reason = reason)
        releaseWakeLock()
        PlaybackKeepAliveAlarmScheduler.cancel(this)
        foregroundCoordinator.stop(reason = reason, removeNotification = true)
        logInfo("idle_exit_stop_self reason=$reason startId=$startId")
        stoppingForIdleExit = true
        publishController(null)
        if (!stopSelfResult(startId)) {
            stoppingForIdleExit = false
            publishController(this)
        }
    }

    internal fun onKeepAliveHeartbeat() {
        progressHeartbeat.onKeepAliveHeartbeat()
    }

    private fun isPlaybackNotificationPosted(): Boolean? {
        if (notificationsDismissed) return null
        return try {
            val manager =
                getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                    ?: return null
            manager.activeNotifications.any { it.id == FOREGROUND_NOTIFICATION_ID }
        } catch (_: Exception) {
            null
        }
    }

    private fun acquireWakeLock() = playbackWakeLock.acquire()

    private fun releaseWakeLock() = playbackWakeLock.release()

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
            "foregroundStarted=${foregroundCoordinator.isStarted} " +
            "notificationPosted=${isPlaybackNotificationPosted()} " +
            "wakeLockHeld=${playbackWakeLock.isHeld()} " +
            "audioFocusHeld=${audioFocusController.isHeld} " +
            "screenInteractive=${progressHeartbeat.isScreenInteractive()} " +
            "activePlayback=${hasActivePlayback()} " +
            "keepAlivePlayback=${hasPlaybackToKeepAlive()}"
    }

    private fun logSecurityEvent(message: String, error: Throwable?) {
        if (error == null) {
            AppFileLogger.warn(applicationContext, LOG_TAG, message)
        } else {
            AppFileLogger.warn(applicationContext, LOG_TAG, message, error)
        }
    }

    private fun publishSessionState(sessionId: String): Map<String, Any?>? {
        val session = sessions[sessionId] ?: return null
        return publishNativePlaybackSessionState(session, stateListeners.values)
    }

    private fun publishAllSessionStates() {
        sessions.keys.toList().forEach { publishSessionState(it) }
    }

    private fun okResult(value: Any?): Map<String, Any?> = channelSuccess(value)

    private fun errorResult(message: String): Map<String, Any?> {
        return channelFailure(
            code = ChannelErrorCodes.PLAYER_ERROR,
            message = message
        )
    }


}
