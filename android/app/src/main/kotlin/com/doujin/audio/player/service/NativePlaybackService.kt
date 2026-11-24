@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.doujin.audio.player.service

import com.doujin.audio.channel.*
import com.doujin.audio.common.*
import com.doujin.audio.common.network.NetworkRouteRuntime
import com.doujin.audio.player.common.*
import com.doujin.audio.player.notification.*
import com.doujin.audio.player.recovery.*
import com.doujin.audio.player.session.*
import com.doujin.audio.player.effects.NativePlaybackResumeFade
import com.doujin.audio.player.effects.StereoSpatialResponses
import com.doujin.audio.player.video.*
import com.doujin.audio.storage.*

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
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
        private const val EXTRA_TRANSPORT_COMMAND = "transport_command"
        private const val FOREGROUND_WATCHDOG_INTERVAL_MS = 4 * 60 * 1000L
        private const val FOREGROUND_IDLE_GRACE_PERIOD_MS = 15_000L
        private const val STATE_PERSISTENCE_INTERVAL_MS = 15 * 1000L
        private const val STATE_PERSISTENCE_SCREEN_OFF_INTERVAL_MS = 60 * 1000L
        private const val STATE_PERSISTENCE_DEBOUNCE_MS = 800L
        private const val PROGRESS_HEARTBEAT_INTERVAL_MS = 500L
        private const val FOREGROUND_PLAYBACK_UNAVAILABLE_ERROR =
            "Foreground playback is unavailable."
        private const val LOG_TAG = "NativePlaybackService"
        private val internalStartToken = UUID.randomUUID().toString()
        private val pendingCommandDeliveries = AtomicInteger(0)
        private val controllerListeners =
            ConcurrentHashMap<String, (NativePlaybackService?) -> Unit>()

        @Volatile
        private var instance: NativePlaybackService? = null

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
                controller()?.let { service ->
                    service.restoreCoordinator.onPendingCommandDeliveriesSettled()
                    service.syncForegroundState()
                }
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

    private val usage by lazy {
        NativePlaybackUsageCheckpoint(
            ledger = NativePlaybackUsageLedger.get(this),
            handler = mainHandler,
            items = { sessionManager.usageItems() },
            isScreenInteractive = { progressHeartbeat.isScreenInteractive() },
            hasPlayback = ::hasPlaybackToKeepAlive
        )
    }
    fun readUsageAsync(complete: (Map<String, Any?>) -> Unit) {
        usage.readAsync { result ->
            complete(
                result.fold(
                    onSuccess = ::okResult,
                    onFailure = { errorResult(it.message ?: "Failed to read playback usage.") }
                )
            )
        }
    }
    fun acknowledgeUsageAsync(ids: Set<String>, complete: (Map<String, Any?>) -> Unit) {
        usage.acknowledgeAsync(ids) { result ->
            complete(
                result.fold(
                    onSuccess = { okResult(null) },
                    onFailure = { errorResult(it.message ?: "Failed to acknowledge playback usage.") }
                )
            )
        }
    }
    fun resetUsage(): Map<String, Any?> {
        usage.reset()
        return okResult(null)
    }

    private val sessionManager by lazy { NativePlaybackSessionManager(::createNativePlaybackSession) }
    private val timerExecution by lazy {
        NativePlaybackTimerExecution(
            setPauseAtEnd = { id, enabled ->
                sessionManager.get(id)?.let {
                    it.timerStopAfterCurrentTrack = enabled
                    it.syncPauseAtTrackEnd()
                }
            },
            restoreFade = { id -> sessionManager.get(id)?.applyFadeMultiplier(1f) },
            onAllTracksFinished = { generation ->
                PlaybackTimerAlarmScheduler.completeTimerStopAfterCurrentTracksAsync(applicationContext, generation)
            }
        )
    }
    private val timerResumeFade by lazy {
        NativePlaybackResumeFade(mainHandler) { id, multiplier ->
            sessionManager.get(id)?.applyFadeMultiplier(multiplier)
        }
    }
    private val documentPathResolver by lazy { DocumentPathResolver(applicationContext) }
    private val videoOutputs = NativeVideoOutputRegistry<Player>(
        playerForSession = { sessionId -> sessionManager.playerForSession(sessionId) },
        shouldKeepScreenOn = { player ->
            player.playWhenReady &&
                player.playbackState != Player.STATE_IDLE &&
                player.playbackState != Player.STATE_ENDED
        }
    )
    private val mainHandler = Handler(Looper.getMainLooper())
    private val queuePreparation by lazy {
        NativePlaybackQueuePreparation(AndroidNativePlaybackQueuePreparationEnvironment(mainHandler))
    }
    @Volatile
    private var stoppingForIdleExit = false
    private var pendingIdleExit: Any? = null
    private val statePublisher by lazy {
        NativePlaybackStatePublisher(
            mainHandler = mainHandler,
            sessions = sessionManager,
            beforeSessionState = { videoOutputs.refreshSession(it) },
            afterSessionState = {
                progressHeartbeat.stopIfUnobserved()
                progressHeartbeat.ensure()
            }
        )
    }
    private val statePersistence: NativePlaybackStatePersistenceCoordinator by lazy {
        NativePlaybackStatePersistenceCoordinator(
            context = applicationContext,
            mainHandler = mainHandler,
            intervalMs = STATE_PERSISTENCE_INTERVAL_MS,
            debounceMs = STATE_PERSISTENCE_DEBOUNCE_MS,
            hasSessions = { sessionManager.isNotEmpty },
            hasActivePlayback = ::hasActivePlayback,
            storedSessions = { sessionManager.storedSnapshots(playbackRecovery.intendedSessionIds) },
            sessionRevisions = { sessionManager.allSessions.associate { it.sessionId to it.definitionRevision } },
            screenOffIntervalMs = STATE_PERSISTENCE_SCREEN_OFF_INTERVAL_MS,
            isScreenInteractive = progressHeartbeat::isScreenInteractive
        )
    }
    private val foregroundNotification by lazy {
        NativeForegroundPlaybackNotification(this) { command ->
            Intent(applicationContext, NativePlaybackService::class.java).apply {
                action = nativePlaybackTransportAction
                putExtra(EXTRA_INTERNAL_START_TOKEN, internalStartToken)
                putExtra(EXTRA_TRANSPORT_COMMAND, command)
            }
        }
    }
    private val playerFactory by lazy {
        NativePlayerFactory(
            context = this,
            resolveUriToPath = documentPathResolver::contentUriToFilePath,
            isCurrentPlayer = { id, player -> sessionManager.get(id)?.playerOrNull() === player },
            callbacks = object : NativePlayerEventCallbacks {
                override fun onPlaybackStateChanged(sessionId: String, playbackState: Int) {
                    usage.update()
                    handlePlaybackStateChanged(sessionId, playbackState)
                }

                override fun onMediaItemTransition(sessionId: String, reason: Int) {
                    usage.update()
                    handleMediaItemTransition(sessionId, reason)
                }

                override fun onPlayerEvents(sessionId: String, positionChanged: Boolean) =
                    statePublisher.scheduleSessionState(sessionId, positionChanged)

                override fun onPlayWhenReadyChanged(
                    sessionId: String,
                    playWhenReady: Boolean,
                    reason: Int
                ) {
                    handlePlayWhenReadyChanged(sessionId, playWhenReady, reason)
                }

                override fun onIsPlayingChanged(sessionId: String, isPlaying: Boolean) {
                    usage.update()
                    handleIsPlayingChanged(sessionId, isPlaying)
                }

                override fun onPlayerError(sessionId: String, error: PlaybackException) {
                    handlePlayerError(sessionId, error)
                }
            }
        )
    }
    private val sessionRestorer by lazy {
        NativePlaybackSessionRestorer(
            getOrCreateSession = { sessionId ->
                sessionManager.getOrCreate(sessionId)
            },
            removeSession = { sessionId -> sessionManager.remove(sessionId) },
            focusSession = ::focusSession,
            playbackCacheDirectory = java.io.File(cacheDir, "asmr_playback_cache"),
            isStoredSessionCurrent = { NativePlaybackStateStore.sessionRevision(it.sessionId) == it.definitionRevision },
            logRestoreFailure = { sessionId, error ->
                logWarn("restore_session_failed sessionId=$sessionId error=${error.javaClass.simpleName}")
            }
        )
    }
    private val mediaSessionHost by lazy {
        NativeMediaSessionHost(
            context = this,
            candidate = ::mediaSessionCandidate,
            onPlayerCommand = ::onMediaSessionPlayerCommand,
            onSetPlayWhenReady = ::onMediaSessionSetPlayWhenReady,
            onPaused = { session ->
                if (sessionManager.get(session.sessionId) === session) {
                    statePublisher.publishSessionState(session.sessionId, includePositionChange = true)
                    statePublisher.publishResumePauseBatch(listOf(session.sessionId))
                    statePersistence.persistNow()
                }
            },
            onSessionCreated = ::addSession,
            onSessionReleased = ::removeSession,
            logSecurityEvent = ::logSecurityEvent,
            logInfo = ::logInfo,
            logWarn = { message, error -> logWarn(message, error = error) }
        )
    }
    private val progressHeartbeat: NativePlaybackProgressHeartbeatCoordinator by lazy {
        NativePlaybackProgressHeartbeatCoordinator(
            host = object : NativePlaybackProgressHeartbeatHost {
                override fun shouldRunProgressHeartbeat(): Boolean =
                    statePublisher.hasListeners && sessionManager.hasProgressSessions

                override fun publishProgress(nowElapsedRealtimeMs: Long) {
                    statePublisher.publishProgress(nowElapsedRealtimeMs)
                }

                override fun onScreenInteractiveChanged(interactive: Boolean) {
                    videoOutputs.setScreenInteractive(interactive)
                    statePersistence.onScreenInteractiveChanged()
                    playbackRecovery.onScreenInteractiveChanged()
                    usage.reschedule()
                    if (interactive) {
                        onPlaybackWake("screen_on")
                    } else if (hasPlaybackToKeepAlive()) {
                        statePersistence.persistNow()
                    }
                }

                override fun onDeviceIdleModeChanged(deviceIdle: Boolean) {
                    if (!deviceIdle) onPlaybackWake("device_idle_exited")
                }
            },
            environment = AndroidNativePlaybackProgressHeartbeatEnvironment(this, mainHandler),
            screenOnIntervalMs = PROGRESS_HEARTBEAT_INTERVAL_MS
        )
    }
    private val restoreCoordinator: NativePlaybackRestoreCoordinator by lazy {
        NativePlaybackRestoreCoordinator(
            environment = AndroidNativePlaybackRestoreEnvironment(
                context = applicationContext,
                mainHandler = mainHandler
            ),
            prepareSessionsOnBackground = sessionRestorer::prepareQueues,
            discardPreparedSessions = sessionRestorer::discardPreparedQueues,
            restoreSessions = sessionRestorer::restore,
            startBootstrap = foregroundCoordinator::startBootstrap,
            resetRestoreState = { playbackSuspended = false },
            completeRestore = { restoredSessionIds ->
                evictPlayersIfNeeded()
                restoredSessionIds.forEach { statePublisher.publishSessionState(it, includePositionChange = true) }
                progressHeartbeat.ensure()
                statePersistence.ensureTicker()
                statePersistence.persistNow()
                syncForegroundState()
            },
            sessionExists = sessionManager::contains,
            hasSessions = { sessionManager.isNotEmpty },
            hasPlaybackToKeepAlive = ::hasPlaybackToKeepAlive,
            hasPendingCommandDelivery = ::hasPendingCommandDelivery,
            stopIdleService = { startId, reason -> stopIdleServiceAfterRestore(startId, reason) },
            onMissingSessionsRestored = { restoredSessionIds ->
                restoredSessionIds.forEach { statePublisher.publishSessionState(it, includePositionChange = true) }
                evictPlayersIfNeeded()
                statePersistence.persistNow()
            },
            resumeRestartSession = ::resumeAfterServiceRestart,
            logInfo = ::logInfo,
            logWarn = { message, error -> logWarn("$message error=${error.javaClass.simpleName}") }
        )
    }

    var focusedSessionId: String?
        get() = sessionManager.focusedSessionId
        internal set(value) { sessionManager.focusedSessionId = value }
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
                override fun activePlaybackSessionIds(): List<String> =
                    sessionManager.activePlaybackSessionIds()
                override fun sessionExists(sessionId: String): Boolean =
                    sessionManager.contains(sessionId)
                override fun pause(sessionId: String) {
                    sessionManager.get(sessionId)?.playerOrNull()?.pause()
                }
                override fun play(sessionId: String) {
                    sessionManager.get(sessionId)?.let { ensureFocusedPlayer(it).play() }
                }
                override fun focus(sessionId: String) = focusSession(sessionId)
                override fun clearPlaybackIntent(sessionId: String) =
                    this@NativePlaybackService.clearPlaybackIntent(sessionId)
                override fun clearAllPlaybackRecovery() = playbackRecovery.clearAll()
                override fun applyFocusDuckMultiplier(multiplier: Float) {
                    sessionManager.applyFocusDuckMultiplier(multiplier)
                }
                override fun publishDevicePauseBatch(sessionIds: List<String>) =
                    statePublisher.publishResumePauseBatch(sessionIds)
                override fun publishAllSessions() = statePublisher.publishAllSessionStates()
                override fun persistNow() = statePersistence.persistNow()
                override fun schedulePersist() = statePersistence.schedulePersist()
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
                override val interruptionActive: Boolean
                    get() = focusRecovery.interruptionActive
                override fun session(sessionId: String) = sessionManager.get(sessionId)
                override fun requestAudioFocus() = focusRecovery.requestIfNeeded()
                override fun establishForegroundPlayback(sessionId: String): Boolean =
                    foregroundCoordinator.startOrUpdate().playbackAllowed
                override fun ensurePlayer(session: NativePlaybackSession) = ensureFocusedPlayer(session)
                override fun onBeforeReleasePlayer(session: NativePlaybackSession) {
                    detachPlayerAttachments(session, "playback_recovery_rebuild", keepSessionAlive = true)
                }
                override fun prepareRecoveryQueue(
                    sessionId: String,
                    queue: List<NativeMediaItemDescriptor>,
                    isCurrent: () -> Boolean,
                    complete: (Result<NativePlaybackQueue>) -> Unit
                ) = queuePreparation.prepare(sessionId, queue, {
                    controller() === this@NativePlaybackService && isCurrent()
                }, complete)
                override fun onRecoveryTimedOut(sessionId: String) {
                    val session = sessionManager.get(sessionId) ?: return
                    session.playerOrNull()?.pause()
                    detachPlayerAttachments(session, "playback_recovery_timed_out")
                    session.releasePlayer()
                    updateMediaSessionPlayer()
                    statePublisher.publishSessionState(sessionId)
                    if (hasPlaybackToKeepAlive()) {
                        statePersistence.persistNow()
                    } else {
                        stopIdleServiceAfterRestore(
                            restoreCoordinator.latestStartId, "playback_recovery_timed_out", preserveVideo = false
                        )
                    }
                }
                override fun publishSession(sessionId: String) {
                    statePublisher.publishSessionState(sessionId)
                }
                override fun persistNow() = statePersistence.persistNow()
                override fun schedulePersist() = statePersistence.schedulePersist()
                override fun syncForeground() = syncForegroundState()
                override fun onNetworkRecoveryTriggered() {
                    NetworkRouteRuntime.get(applicationContext).evictIdleConnections()
                }
                override fun logInfo(message: String, session: NativePlaybackSession?) =
                    this@NativePlaybackService.logInfo(message, session)

                override fun logWarn(
                    message: String,
                    session: NativePlaybackSession?
                ) = this@NativePlaybackService.logWarn(message, session)
            },
            environment = AndroidNativePlaybackRecoveryEnvironment(
                context = this,
                handler = mainHandler,
                logWarn = { message, error -> logWarn(message, error = error) }
            ),
            isScreenInteractive = progressHeartbeat::isScreenInteractive
        )
    }
    private val wakeLocks by lazy {
        NativePlaybackWakeLockController(
            context = applicationContext ?: this,
            logInfo = ::logInfo,
            logWarn = { message, error -> logWarn(message, error = error) }
        )
    }
    private val foregroundCoordinator: NativePlaybackForegroundCoordinator by lazy {
        NativePlaybackForegroundCoordinator(
            host = object : NativePlaybackForegroundHost {
                override val hasPlaybackToKeepAlive: Boolean
                    get() = this@NativePlaybackService.hasPlaybackToKeepAlive()
                override val playbackSuspended: Boolean
                    get() = this@NativePlaybackService.playbackSuspended
                override val hasActiveUiListeners: Boolean
                    get() = statePublisher.hasListeners
                override fun playbackSignature(): String? {
                    if (!foregroundCoordinator.isStarted &&
                        !hasActivePlayback() &&
                        !playbackRecovery.shouldKeepAlive() &&
                        !focusRecovery.hasPendingResume()
                    ) {
                        return null
                    }
                    val session = foregroundSession() ?: return null
                    return foregroundNotification.signature(
                        session = session,
                        mediaSession = mediaSessionHost.current(),
                        attachedToPlayer = mediaSessionHost.isAttachedTo(session.playerOrNull()),
                        playbackIntended = playbackRecovery.isIntended(session.sessionId)
                    )
                }

                override fun onSyncStateChanged() = syncWakeLocks()

                override fun onActiveSync() {
                    usage.ensureScheduled()
                    if (!focusRecovery.interruptionActive) {
                        focusRecovery.requestIfNeeded()
                        if (focusRecovery.resumePendingIfPossible("foreground_sync_focus_available")) {
                            statePersistence.schedulePersist()
                        }
                    }
                    statePersistence.ensureTicker()
                }

                override fun isForegroundNotificationPosted(): Boolean? {
                    if (!hasActivePlayback() && !playbackRecovery.shouldKeepAlive() && !focusRecovery.hasPendingResume()) {
                        return null
                    }
                    return foregroundNotification.isPosted()
                }

                override fun onIdleStop() {
                    stopIdleServiceAfterRestore(restoreCoordinator.latestStartId, "idle_no_playback")
                }

                override fun startPlaybackForeground() {
                    val session = foregroundSession()
                    foregroundNotification.startPlayback(
                        session = session,
                        mediaSession = ensureMediaSession(),
                        playbackIntended = session?.let { playbackRecovery.isIntended(it.sessionId) } == true
                    )
                }

                override fun startBootstrapForeground() {
                    mediaSessionHost.ensureBootstrap()
                    foregroundNotification.startBootstrap(mediaSessionHost.current())
                }

                override fun stopForeground(wasStarted: Boolean) = foregroundNotification.stop(wasStarted)

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
            },
            watchdogIntervalMs = FOREGROUND_WATCHDOG_INTERVAL_MS,
            idleGracePeriodMs = FOREGROUND_IDLE_GRACE_PERIOD_MS
        )
    }
    private var attemptedStickyPlaybackRestore = false
    private var playbackBehavior = StoredPlaybackBehavior()
    override fun onCreate() {
        super.onCreate()
        NativePlaybackUsageLedger.get(this).preloadAsync()
        playbackBehavior = NativePlaybackStateStore.loadPlaybackBehavior(applicationContext)
        audioDeviceDisconnectMonitor.start()
        progressHeartbeat.start()
        videoOutputs.setScreenInteractive(progressHeartbeat.isScreenInteractive())
        foregroundNotification.ensureChannel()
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
            transportCommandExtra = EXTRA_TRANSPORT_COMMAND,
            onUnreadableExtras = {
                logSecurityEvent("playback_service_start_extras_unreadable", null)
            }
        )
        if (!startDecision.accepted) {
            logSecurityEvent(
                "playback_service_start_rejected reason=${startDecision.rejectionReason}",
                null
            )
            return finishStartWithoutRestore(startId)
        }
        restoreCoordinator.acceptStart(startId)
        pendingIdleExit = null
        if (stoppingForIdleExit) {
            stoppingForIdleExit = false
            publishController(this)
        }
        if (startDecision.source == NativePlaybackStartSource.TRANSPORT) {
            super.onStartCommand(intent, flags, startId)
            handleNotificationTransportCommand(startDecision.transportCommand.orEmpty())
            return finishStartWithoutRestore(startId)
        }
        super.onStartCommand(intent, flags, startId)
        if (startDecision.requireForegroundBootstrap) {
            logInfo("on_start_command foreground_bootstrap_requested")
            foregroundCoordinator.startBootstrap()
        }
        if (startDecision.shouldAttemptRestore &&
            shouldAttemptStickyPlaybackRestore(sessionManager.isNotEmpty, attemptedStickyPlaybackRestore)
        ) {
            attemptedStickyPlaybackRestore = true
            restoreCoordinator.restoreAfterServiceRestart(startId)
        }
        return START_STICKY
    }

    private fun handleNotificationTransportCommand(command: String) {
        val target = mediaSessionCandidate() ?: foregroundSession() ?: return
        val player = target.playerOrNull()
        when (command) {
            NATIVE_PLAYBACK_TRANSPORT_PREVIOUS -> {
                clearTrackStopForManualCommand(target.sessionId)
                if (player != null && player.hasPreviousMediaItem()) player.seekToPreviousMediaItem()
            }
            NATIVE_PLAYBACK_TRANSPORT_NEXT -> {
                clearTrackStopForManualCommand(target.sessionId)
                if (player != null && player.hasNextMediaItem()) player.seekToNextMediaItem()
            }
            NATIVE_PLAYBACK_TRANSPORT_PLAY_PAUSE -> {
                val isActive = playbackRecovery.isIntended(target.sessionId) ||
                    player?.let { it.isPlaying || it.playWhenReady } == true
                if (isActive) {
                    @Suppress("UNCHECKED_CAST")
                    val pausedSnapshot = pause(target.sessionId)["value"] as? Map<String, Any?>
                    if (pausedSnapshot != null) {
                        statePublisher.publishResumePauseBatchSnapshots(listOf(pausedSnapshot))
                    } else {
                        statePublisher.publishResumePauseBatch(listOf(target.sessionId))
                    }
                } else {
                    play(target.sessionId)
                }
            }
        }
    }

    private fun finishStartWithoutRestore(startId: Int): Int {
        if (sessionManager.isNotEmpty || hasPlaybackToKeepAlive() || foregroundCoordinator.isStarted) {
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
        if (hasPlaybackToKeepAlive()) {
            foregroundCoordinator.sync()
            foregroundCoordinator.repairNotificationIfMissing()
        } else {
            stopIdleServiceAfterRestore(restoreCoordinator.latestStartId, "task_removed_no_playback", preserveVideo = false)
        }
    }

    override fun onDestroy() {
        pendingIdleExit = null
        usage.finish()
        logInfo(
            "on_destroy_begin sessions=${sessionManager.size} " +
                "foregroundStarted=${foregroundCoordinator.isStarted}"
        )
        var firstFailure = runPlaybackShutdownActions(
            listOf(
                statePublisher::shutdown,
                videoOutputs::clear,
                restoreCoordinator::shutdown,
                audioDeviceDisconnectMonitor::shutdown,
                progressHeartbeat::shutdown,
                queuePreparation::shutdown,
                statePersistence::shutdown,
                playbackRecovery::clearAll,
                { mediaSessionHost.release("on_destroy") },
                {
                    runPlaybackShutdownActions(sessionManager.releaseAll())
                        ?.let { throw it }
                },
                sessionManager::clear,
                foregroundCoordinator::shutdown,
                { wakeLocks.releaseAll("on_destroy") },
                { focusRecovery.abandon(reason = "on_destroy") },
                timerResumeFade::cancel,
                timerExecution::cancel,
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
        firstFailure?.let { error ->
            logWarn("on_destroy_failed error=${error.javaClass.simpleName}", error = error)
        }
        logInfo("on_destroy_end")
    }

    internal fun hasSession(sessionId: String): Boolean = sessionManager.contains(sessionId)

    fun addStateListener(ownerId: String, listener: (Map<String, Any?>) -> Unit) {
        statePublisher.addListener(ownerId, listener)
        progressHeartbeat.ensure()
    }

    fun removeStateListener(ownerId: String) {
        statePublisher.removeListener(ownerId)
        progressHeartbeat.stopIfUnobserved()
        if (!statePublisher.hasListeners) syncForegroundState()
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
        ownerId: String
    ): Boolean {
        return videoOutputs.refresh(sessionId, ownerId)
    }

    internal fun unregisterVideoOutput(sessionId: String, ownerId: String) {
        videoOutputs.unregister(sessionId, ownerId)
    }

    internal fun settleForegroundAfterBridgeAttach() {
        syncForegroundState()
        foregroundCoordinator.repairNotificationIfMissing()
    }

    internal fun prepareSession(args: NativePrepareSessionArguments): Map<String, Any?> {
        val sessionId = args.sessionId
        val nativeSession = if (args.reuseExistingQueue) {
            sessionManager.reusableSessionFor(sessionId, args.queueStartIndex, args.uri, args.explicitPath)
                ?: return channelFailure(
                    code = ChannelErrorCodes.QUEUE_RESYNC_REQUIRED,
                    message = "Existing playback queue cannot be reused."
                )
        } else {
            sessionManager.getOrCreate(sessionId)
        }
        if (args.reuseExistingQueue) {
            playbackRecovery.resetHealth(sessionId, "prepare_session", cancelRecovery = true)
            queuePreparation.cancel(sessionId)
        }
        if (nativeSession.path != null && (nativeSession.path != args.path || nativeSession.queueIndex != args.queueStartIndex)) {
            clearTrackStopForManualCommand(sessionId)
        }
        focusRecovery.removePending(sessionId)
        return try {
            if (args.reuseExistingQueue) {
                nativeSession.jumpInExistingQueue(args)
            } else {
                nativeSession.configure(args.copy(deferPlayerCreation = !args.autoPlay))
            }
            if (args.autoPlay) {
                removeTimerTargetForManualCommand(sessionId)
                playbackSuspended = false
                focusSession(sessionId)
                markPlaybackIntended(sessionId)
                val player = ensureFocusedPlayer(nativeSession)
                if (!establishForegroundPlaybackOrRollback(listOf(sessionId))) {
                    return errorResult(FOREGROUND_PLAYBACK_UNAVAILABLE_ERROR)
                }
                if (!focusRecovery.requestForExplicitPlayback()) {
                    rollbackPlaybackStart(listOf(sessionId), "audio_focus_denied")
                    return errorResult("Audio focus was denied.")
                }
                player.play()
            } else {
                clearPlaybackIntent(sessionId)
                if (!args.deferPlayerCreation) foregroundCoordinator.holdPlaybackStart(sessionId)
            }
            evictPlayersIfNeeded()
            val snapshot = statePublisher.publishSessionState(sessionId, includePositionChange = true)
                ?: nativeSession.snapshot()
            progressHeartbeat.ensure()
            statePersistence.persistNow()
            statePersistence.ensureTicker()
            syncForegroundState()
            okResult(snapshot)
        } catch (e: Exception) {
            if (args.reuseExistingQueue) {
                return errorResult("Failed to reuse session queue: ${e.message}")
            }
            val wasFocused = focusedSessionId == sessionId
            sessionManager.remove(sessionId)
            nativeSession.release()
            usage.update()
            clearPlaybackIntent(sessionId)
            if (wasFocused) updateMediaSessionPlayer()
            syncForegroundState()
            errorResult("Failed to prepare session: ${e.message}")
        }
    }

    internal fun prepareSessionAsync(
        args: NativePrepareSessionArguments,
        complete: (Map<String, Any?>) -> Unit
    ) {
        playbackRecovery.resetHealth(args.sessionId, "prepare_session", cancelRecovery = true)
        queuePreparation.prepareSession(args, sessionManager, {
            controller() === this && NativePlaybackStateStore.sessionRevision(args.sessionId) == args.definitionRevision
        }) { prepared ->
            complete(prepared.fold(::prepareSession,
                { errorResult(it.message ?: "Playback preparation failed.") }))
        }
    }

    internal fun playAsync(
        sessionId: String, transportCommandId: Long, exclusive: Boolean,
        complete: (Map<String, Any?>) -> Unit
    ) {
        restoreCoordinator.restoreMissingSessions(listOf(sessionId), sessionManager.sessionIds) { valid ->
            complete(if (valid && controller() === this) play(sessionId, transportCommandId, exclusive)
                else errorResult("Playback service is no longer available."))
        }
    }

    internal fun setRepeatOneAsync(
        args: NativeRepeatOneArguments,
        complete: (Map<String, Any?>) -> Unit
    ) {
        if (args.queue.isNotEmpty()) {
            playbackRecovery.resetHealth(args.sessionId, "replace_queue", cancelRecovery = true)
        }
        queuePreparation.prepareRepeatOne(args, sessionManager, { controller() === this }) { prepared ->
            complete(prepared.fold(::setRepeatOne,
                { errorResult(it.message ?: "Playback queue preparation failed.") }))
        }
    }

    internal fun updateQueueAsync(
        args: NativeUpdateQueueArguments,
        complete: (Map<String, Any?>) -> Unit
    ) {
        sessionManager.get(args.sessionId)?.let { session ->
            if (args.queueRevision >= session.queueRevision) {
                playbackRecovery.resetHealth(args.sessionId, "update_queue", cancelRecovery = true)
            }
        }
        queuePreparation.prepareUpdate(args, sessionManager, { controller() === this }) { prepared ->
            complete(prepared.fold({ updateQueue(args, it) },
                { errorResult(it.message ?: "Playback queue preparation failed.") }))
        }
    }

    internal fun updateQueue(
        args: NativeUpdateQueueArguments,
        prepared: NativePlaybackQueue? = null
    ): Map<String, Any?> {
        val session = sessionManager.get(args.sessionId) ?: return errorResult("Unknown session.")
        if (args.queueRevision < session.queueRevision) return okResult(session.snapshot())
        session.queueRevision = args.queueRevision
        if (args.queue.isEmpty()) {
            queuePreparation.cancel(args.sessionId)
            clearPlaybackIntent(args.sessionId)
            detachPlayerAttachments(session, "clear_queue")
            session.clearQueue()
            updateMediaSessionPlayer()
        } else {
            session.updateQueue(args.queue, args.queueStartIndex, args.repeatOne,
                args.repeatAll, args.shuffle, prepared)
        }
        val snapshot = statePublisher.publishSessionState(args.sessionId, includePositionChange = true)
        statePersistence.persistNow()
        syncForegroundState()
        return okResult(snapshot)
    }

    fun play(
        sessionId: String,
        transportCommandId: Long = 0L,
        exclusive: Boolean = false
    ): Map<String, Any?> {
        val session = sessionManager.get(sessionId) ?: run {
            syncForegroundState()
            return errorResult("Unknown session.")
        }
        if (session.stoppedAtTrackBoundary) {
            clearTrackStopForManualCommand(sessionId)
        } else {
            removeTimerTargetForManualCommand(sessionId)
        }
        val pausedSessionIds = if (exclusive) {
            exclusivePlaybackSessionIdsToPause(
                targetSessionId = sessionId,
                sessionPlaybackIntent = sessionManager.playbackIntentBySessionId(playbackRecovery::isIntended)
            )
        } else emptyList()
        if (transportCommandId > 0L) {
            session.transportCommandId = transportCommandId
        }
        focusRecovery.removePending(sessionId)
        playbackSuspended = false
        val playerBeforePlay = session.playerOrNull()
        val needsImmediateRecovery = playerBeforePlay != null &&
            playerBeforePlay.playerError != null
        markPlaybackIntended(sessionId)
        timerResumeFade.cancel()
        session.applyFadeMultiplier(1f)
        focusSession(sessionId)
        val readyPlayer = if (needsImmediateRecovery) null else ensureFocusedPlayer(session)
        if (!establishForegroundPlaybackOrRollback(listOf(sessionId))) {
            return errorResult(FOREGROUND_PLAYBACK_UNAVAILABLE_ERROR)
        }
        if (!focusRecovery.requestForExplicitPlayback()) {
            rollbackPlaybackStart(listOf(sessionId), "audio_focus_denied")
            return errorResult("Audio focus was denied.")
        }
        pausedSessionIds.forEach { pausedSessionId ->
            clearTrackStopForManualCommand(pausedSessionId)
            val pausedSession = sessionManager.get(pausedSessionId) ?: return@forEach
            if (transportCommandId > 0L) {
                pausedSession.transportCommandId = transportCommandId
            }
            focusRecovery.removePending(pausedSessionId)
            clearPlaybackIntent(pausedSessionId)
            pausedSession.playerOrNull()?.pause()
        }
        if (needsImmediateRecovery) {
            playbackRecovery.retryNow(sessionId, "user_retry")
        } else {
            (readyPlayer ?: ensureFocusedPlayer(session)).play()
        }
        evictPlayersIfNeeded()
        pausedSessionIds.forEach { statePublisher.publishSessionState(it, includePositionChange = true) }
        val snapshot = statePublisher.publishSessionState(sessionId, includePositionChange = true)
        progressHeartbeat.ensure()
        statePersistence.schedulePersist()
        statePersistence.ensureTicker()
        syncForegroundState()
        return okResult(snapshot)
    }

    fun pause(
        sessionId: String,
        transportCommandId: Long = 0L
    ): Map<String, Any?> = pauseInternal(
        sessionId = sessionId,
        transportCommandId = transportCommandId,
        clearManualTimerTargets = true
    )

    private fun pauseInternal(
        sessionId: String,
        transportCommandId: Long = 0L,
        clearManualTimerTargets: Boolean = true
    ): Map<String, Any?> {
        if (clearManualTimerTargets) {
            clearTrackStopForManualCommand(sessionId)
        }
        queuePreparation.cancel(sessionId)
        restoreCoordinator.excludeSessionFromRestartRestore(sessionId)
        timerResumeFade.cancel()
        val session = sessionManager.get(sessionId) ?: return okResult(null)
        if (transportCommandId > 0L) session.transportCommandId = transportCommandId
        focusRecovery.removePending(sessionId)
        clearPlaybackIntent(sessionId)
        session.playerOrNull()?.pause()
        val snapshot = retirePausedSession(session, allowWarmAudioRetention = true)
        evictPlayersIfNeeded()
        statePersistence.persistNow()
        syncForegroundState()
        return okResult(snapshot)
    }

    fun stop(sessionId: String): Map<String, Any?> {
        clearTrackStopForManualCommand(sessionId)
        queuePreparation.cancel(sessionId)
        restoreCoordinator.excludeSessionFromRestartRestore(sessionId)
        timerResumeFade.cancel()
        val session = sessionManager.get(sessionId) ?: return errorResult("Unknown session.")
        focusRecovery.removePending(sessionId)
        clearPlaybackIntent(sessionId)
        val player = session.playerOrNull()
        player?.stop()
        player?.clearMediaItems()
        val snapshot = retireSession(session, "idle")
        evictPlayersIfNeeded()
        statePersistence.persistNow()
        syncForegroundState()
        return okResult(snapshot)
    }

    fun seek(sessionId: String, positionMs: Long): Map<String, Any?> {
        val session = sessionManager.get(sessionId) ?: return errorResult("Unknown session.")
        playbackRecovery.resetHealth(sessionId, "seek", cancelRecovery = true)
        session.seekTo(positionMs)
        val snapshot = statePublisher.publishSessionState(sessionId, includePositionChange = true)
        statePersistence.schedulePersist()
        return okResult(snapshot)
    }

    internal fun restoreSessionsForTimer(sessionIds: List<String>, complete: (Result<Boolean>) -> Unit) {
        restoreCoordinator.restoreMissingSessions(sessionIds, sessionManager.sessionIds,
            onFailure = { complete(Result.failure(it)) }) { valid ->
            complete(Result.success(valid && controller() === this))
        }
    }

    fun setVolume(sessionId: String, volume: Float): Map<String, Any?> {
        val session = sessionManager.get(sessionId) ?: return errorResult("Unknown session.")
        session.applyVolume(volume)
        val snapshot = statePublisher.publishSessionState(sessionId)
        statePersistence.schedulePersist()
        return okResult(snapshot)
    }

    fun setFadeMultiplier(sessionId: String, multiplier: Float): Map<String, Any?> {
        timerResumeFade.cancel()
        val session = sessionManager.get(sessionId) ?: return errorResult("Unknown session.")
        session.applyFadeMultiplier(multiplier)
        return okResult(session.snapshot())
    }

    fun setStopAfterCurrentTrack(sessionId: String, enabled: Boolean): Map<String, Any?> {
        val session = sessionManager.get(sessionId) ?: return errorResult("Unknown session.")
        session.stopAfterCurrentTrack = enabled
        session.stoppedAtTrackBoundary = false
        session.syncPauseAtTrackEnd()
        return okResult(statePublisher.publishSessionState(sessionId))
    }

    private fun removeTimerTargetForManualCommand(sessionId: String) {
        val armedGeneration = timerExecution.generationFor(sessionId)
        val finishedAllTargets = timerExecution.removeTargetWithoutCallback(sessionId)
        PlaybackTimerAlarmScheduler.onManualPlaybackStoppedAsync(
            context = this,
            sessionId = sessionId,
            completeTrackStopGeneration = armedGeneration.takeIf { finishedAllTargets }
        )
    }

    private fun clearTrackStopForManualCommand(sessionId: String) {
        // Update recovery IDs before settling the last target, which may schedule resume.
        sessionManager.get(sessionId)?.let {
            it.stopAfterCurrentTrack = false
            it.stoppedAtTrackBoundary = false
            it.syncPauseAtTrackEnd()
        }
        removeTimerTargetForManualCommand(sessionId)
    }

    fun setSpeed(sessionId: String, speed: Float): Map<String, Any?> {
        val session = sessionManager.get(sessionId) ?: return errorResult("Unknown session.")
        session.applySpeed(speed)
        val snapshot = statePublisher.publishSessionState(sessionId)
        statePersistence.schedulePersist()
        return okResult(snapshot)
    }

    fun setTemporarySpeed(sessionId: String, speed: Float?): Map<String, Any?> {
        val session = sessionManager.get(sessionId) ?: return errorResult("Unknown session.")
        session.applyTemporarySpeed(speed)
        return okResult(statePublisher.publishSessionState(sessionId))
    }

    fun clearTemporarySpeeds() {
        sessionManager.forEach { session ->
            session.applyTemporarySpeed(null)
            session.refreshProgressAnchor()
        }
    }

    internal fun setAudioEffects(sessionId: String, effects: NativeAudioEffects): Map<String, Any?> {
        val session = sessionManager.get(sessionId) ?: return errorResult("Unknown session.")
        session.applyAudioEffects(effects)
        val snapshot = statePublisher.publishSessionState(sessionId)
        statePersistence.schedulePersist()
        syncForegroundState()
        return okResult(snapshot)
    }

    internal fun setRepeatOne(args: NativeRepeatOneArguments): Map<String, Any?> {
        val session = sessionManager.get(args.sessionId) ?: return errorResult("Unknown session.")
        session.setRepeatOne(args)
        statePersistence.schedulePersist()
        return okResult(session.snapshot())
    }

    fun removeSession(sessionId: String): Map<String, Any?> {
        clearTrackStopForManualCommand(sessionId)
        queuePreparation.cancel(sessionId)
        restoreCoordinator.excludeSessionFromRestartRestore(sessionId)
        focusRecovery.removePending(sessionId)
        clearPlaybackIntent(sessionId)
        val wasFocused = focusedSessionId == sessionId
        videoOutputs.detachPlayer(sessionId)
        usage.update()
        sessionManager.remove(sessionId)?.release()
        usage.update()
        statePersistence.removeSession(sessionId)
        if (wasFocused) {
            updateMediaSessionPlayer()
        }
        if (sessionManager.isEmpty) {
            usage.stop()
            statePersistence.stopTicker()
            statePersistence.cancelScheduledPersist()
            mediaSessionHost.release("remove_session_empty")
            focusRecovery.abandon(reason = "remove_session_empty")
            foregroundCoordinator.stop(reason = "remove_session_empty")
            stopServiceForIdleExit("remove_session_empty")
        } else {
            statePersistence.persistNow()
            syncForegroundState()
        }
        return okResult(null)
    }

    fun pauseAll(): Map<String, Any?> {
        queuePreparation.cancelAll()
        restoreCoordinator.cancelRestartRestore()
        focusRecovery.clearInterruptionState()
        playbackRecovery.clearAll()
        playbackSuspended = true
        sessionManager.allSessions.forEach {
            clearTrackStopForManualCommand(it.sessionId)
            foregroundCoordinator.settlePlaybackStart(it.sessionId)
            it.playerOrNull()?.pause()
            retirePausedSession(it)
        }
        evictPlayersIfNeeded()
        statePublisher.publishAllSessionStates()
        statePersistence.persistNow()
        usage.stop()
        focusRecovery.abandon(reason = "pause_all")
        foregroundCoordinator.stop(reason = "pause_all")
        return okResult(null)
    }

    fun clearAll(): Map<String, Any?> {
        queuePreparation.cancelAll()
        restoreCoordinator.cancelRestartRestore()
        focusRecovery.clearInterruptionState()
        playbackRecovery.clearAll()
        videoOutputs.clear()
        sessionManager.forEach { it.release() }
        sessionManager.clear()
        usage.update()
        usage.stop()
        mediaSessionHost.release("clear_all")
        statePersistence.stopTicker()
        statePersistence.cancelScheduledPersist()
        statePersistence.clearSessions()
        PlaybackTimerAlarmScheduler.clearAllAsync(applicationContext)
        focusRecovery.abandon(reason = "clear_all")
        foregroundCoordinator.stop(reason = "clear_all")
        stopServiceForIdleExit("clear_all")
        return okResult(null)
    }

    fun snapshot(): Map<String, Any?> {
        val response = okResult(sessionManager.snapshot())
        syncForegroundState()
        return response
    }

    fun setPlaybackBehavior(
        pauseOnAudioDeviceDisconnect: Boolean,
        requestAudioFocus: Boolean,
        pauseOnTransientAudioFocusLoss: Boolean,
        resumeAfterTransientAudioFocusGain: Boolean
    ): Map<String, Any?> {
        val previouslyRequestedAudioFocus = playbackBehavior.requestAudioFocus
        val nextBehavior = StoredPlaybackBehavior(
            pauseOnAudioDeviceDisconnect = pauseOnAudioDeviceDisconnect,
            requestAudioFocus = requestAudioFocus,
            pauseOnTransientAudioFocusLoss = pauseOnTransientAudioFocusLoss,
            resumeAfterTransientAudioFocusGain = resumeAfterTransientAudioFocusGain
        )
        playbackBehavior = nextBehavior
        NativePlaybackStateStore.savePlaybackBehavior(applicationContext, nextBehavior)
        if (!requestAudioFocus) {
            focusRecovery.abandon(reason = "mix_with_others_enabled")
            statePublisher.publishAllSessionStates()
            statePersistence.schedulePersist()
        } else if (!previouslyRequestedAudioFocus && hasActivePlayback()) {
            if (!focusRecovery.requestIfNeeded()) {
                logInfo("audio_focus_policy_restore_denied")
                focusRecovery.onFocusChange(AudioManager.AUDIOFOCUS_LOSS)
            }
        }
        return okResult(null)
    }

    internal fun pausePlayingSessionsForTimer(generation: Int, stopAfterCurrentTrack: Boolean): NativeTimerPauseResult {
        val activeSessionIds = sessionManager.activePlaybackSessionIds()
        val interruptedSessionIds = focusRecovery.takePendingResumeSessions()
        val sessionIds = (activeSessionIds + interruptedSessionIds + playbackRecovery.intendedSessionIds).distinct()
        val trackEndTargets = if (stopAfterCurrentTrack) {
            activeSessionIds - interruptedSessionIds.toSet()
        } else {
            emptyList()
        }
        val immediatePauseTargets = if (stopAfterCurrentTrack) {
            sessionIds - trackEndTargets.toSet()
        } else {
            sessionIds
        }
        sessionIds.forEach(::clearPlaybackIntent)
        immediatePauseTargets.forEach { pauseInternal(it, clearManualTimerTargets = false) }
        if (trackEndTargets.isNotEmpty()) timerExecution.arm(trackEndTargets, generation)
        if (sessionIds.isNotEmpty()) {
            statePublisher.publishAllSessionStates()
            statePersistence.persistNow()
        }
        syncForegroundState()
        return NativeTimerPauseResult(sessionIds, waitingForTrackEnd = trackEndTargets.isNotEmpty())
    }

    private fun resumeAfterServiceRestart(sessionId: String) {
        val session = sessionManager.get(sessionId) ?: return
        if (sessionId in NativePlaybackStateStore.loadPausedSessionIds(this)) return
        val timer = NativePlaybackStateStore.loadTimerRuntimeState(this)
        val timerDue = timer?.timerEndsElapsedRealtimeMs?.let { it <= SystemClock.elapsedRealtime() }
            ?: (timer?.timerEndsAtWallClockMs?.let { it <= System.currentTimeMillis() } == true)
        if (timerDue) return

        focusSession(sessionId)
        markPlaybackIntended(sessionId)
        val player = try {
            ensureFocusedPlayer(session)
        } catch (error: Exception) {
            logWarn("sticky_restore_play_failed error=${error.javaClass.simpleName}", session)
            rollbackPlaybackStart(listOf(sessionId), "sticky_restore_play_failed")
            return
        }
        if (!establishForegroundPlaybackOrRollback(listOf(sessionId))) return
        if (!focusRecovery.requestIfNeeded()) {
            rollbackPlaybackStart(listOf(sessionId), "sticky_restore_audio_focus_denied")
            return
        }
        try {
            player.play()
        } catch (error: Exception) {
            logWarn("sticky_restore_play_failed error=${error.javaClass.simpleName}", session)
            rollbackPlaybackStart(listOf(sessionId), "sticky_restore_play_failed")
        }
    }

    fun cancelTimerStopAfterCurrentTrack() = timerExecution.cancel()

    internal fun resumeSessionsForTimer(sessionIds: List<String>): NativeTimerResumeResult {
        if (sessionIds.isEmpty()) {
            return NativeTimerResumeResult(emptyList(), audioFocusDenied = false)
        }
        playbackSuspended = false
        val resumableSessions = sessionIds.mapNotNull { sessionId ->
            focusRecovery.removePending(sessionId)
            sessionManager.get(sessionId)?.also { session ->
                markPlaybackIntended(sessionId)
                session.applyFadeMultiplier(0f)
                focusSession(sessionId)
                ensureFocusedPlayer(session)
            }
        }
        val resumableSessionIds = resumableSessions.map(NativePlaybackSession::sessionId)
        if (resumableSessions.isNotEmpty() && !establishForegroundPlaybackOrRollback(resumableSessionIds)) {
            return NativeTimerResumeResult(emptyList(), audioFocusDenied = true)
        }
        if (resumableSessions.isNotEmpty() && !focusRecovery.requestIfNeeded()) {
            rollbackPlaybackStart(resumableSessionIds, "timer_audio_focus_denied")
            return NativeTimerResumeResult(emptyList(), audioFocusDenied = true)
        }
        val resumedSessionIds = resumableSessions.map { session ->
            session.stoppedAtTrackBoundary = false
            ensureFocusedPlayer(session).apply {
                session.syncPauseAtTrackEnd()
                play()
            }
            session.sessionId
        }
        if (resumedSessionIds.isNotEmpty()) {
            progressHeartbeat.ensure()
            statePersistence.ensureTicker()
            statePublisher.publishAllSessionStates()
            statePersistence.persistNow()
            timerResumeFade.start(resumedSessionIds)
        }
        syncForegroundState()
        return NativeTimerResumeResult(resumedSessionIds, audioFocusDenied = false)
    }

    private fun evictPlayersIfNeeded() {
        sessionManager.evictIdlePlayers(
            isIntended = playbackRecovery::isIntended,
            isFocusPending = focusRecovery::isPending,
            isRecoveryPending = playbackRecovery::isPending,
            shouldRetainPlayer = { session ->
                shouldRetainVideoPlayer(session) ||
                    shouldRetainPausedAudioPlayer(session) ||
                    foregroundCoordinator.isHoldingPlaybackStart(session.sessionId)
            },
            beforeRelease = { session ->
                detachPlayerAttachments(session, "idle_session")
            }
        ).forEach { retirePausedSession(it) }
        updateMediaSessionPlayer()
    }

    private fun detachPlayerAttachments(
        session: NativePlaybackSession,
        reason: String,
        keepSessionAlive: Boolean = false
    ) {
        videoOutputs.detachPlayer(session.sessionId)
        val player = session.playerOrNull()
        if (keepSessionAlive) {
            mediaSessionHost.parkIfAttached(player, reason)
        } else if (mediaSessionHost.isAttachedTo(player)) {
            mediaSessionHost.release(reason)
        }
    }

    private fun shouldRetainVideoPlayer(session: NativePlaybackSession): Boolean =
        shouldRetainPausedVideoPlayer(
            session.playerOrNull(), videoOutputs.hasOutput(session.sessionId), session.path
        )

    private fun shouldRetainPausedAudioPlayer(session: NativePlaybackSession): Boolean {
        val player = session.playerOrNull()
        return !playbackSuspended &&
            statePublisher.hasListeners &&
            !hasActivePlayback() &&
            focusedSessionId == session.sessionId &&
            player != null &&
            player.playerError == null &&
            player.playbackState != Player.STATE_ENDED
    }

    private fun retirePausedSession(
        session: NativePlaybackSession,
        allowWarmAudioRetention: Boolean = false
    ): Map<String, Any?> {
        // Keep the loaded decoder across pause and inline/fullscreen output handoff,
        // or keep the focused audio player warm during the idle grace window.
        if (shouldRetainVideoPlayer(session) ||
            (allowWarmAudioRetention && shouldRetainPausedAudioPlayer(session))
        ) {
            session.applyTemporarySpeed(null)
            return checkNotNull(statePublisher.publishSessionState(session.sessionId, includePositionChange = true))
        }
        return retireSession(session, "idle")
    }

    private fun retireSession(session: NativePlaybackSession, processingState: String): Map<String, Any?> {
        detachPlayerAttachments(session, "idle_session")
        statePublisher.cancelScheduledSessionState(session.sessionId)
        val snapshot = sessionManager.releaseIdleSession(
            session, statePersistence, processingState, statePublisher::publishTerminalSessionState
        )
        usage.update()
        progressHeartbeat.stopIfUnobserved()
        return snapshot
    }

    private val spatialResponses by lazy { StereoSpatialResponses.load(assets) }

    private fun createNativePlaybackSession(sessionId: String): NativePlaybackSession =
        NativePlaybackSession(
            sessionId = sessionId,
            createPlayer = playerFactory::create,
            logWarn = { message, session, error -> logWarn(message, session, error) },
            loadSpatialResponses = { spatialResponses }
        ).apply { applyFocusDuckMultiplier(focusRecovery.duckMultiplier) }

    private fun handlePlaybackStateChanged(sessionId: String, playbackState: Int) {
        if (playbackState == Player.STATE_ENDED) {
            sessionManager.get(sessionId)?.markTrackStopBoundary()
            timerExecution.onTrackEnded(sessionId, timerExecution.generationFor(sessionId))
            clearPlaybackIntent(sessionId)
            focusRecovery.removePending(sessionId)
            sessionManager.get(sessionId)?.let { retireSession(it, "completed") }
            updateMediaSessionPlayer()
        } else if (!progressHeartbeat.isScreenInteractive()) {
            playbackRecovery.rescheduleHealthCheckIfNeeded()
        }
        logInfo(
            "player_state_changed state=${playbackStateName(playbackState)}",
            sessionManager.get(sessionId)
        )
        statePersistence.schedulePersist()
        syncForegroundState()
    }

    private fun handleMediaItemTransition(sessionId: String, reason: Int) {
        sessionManager.get(sessionId)?.onMediaItemTransition()
        playbackRecovery.onMediaItemTransition(sessionId, reason)
        logInfo(
            "player_media_item_transition reason=$reason",
            sessionManager.get(sessionId)
        )
        statePersistence.persistNow()
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
        if (!playWhenReady && reason == Player.PLAY_WHEN_READY_CHANGE_REASON_END_OF_MEDIA_ITEM) {
            sessionManager.get(sessionId)?.markTrackStopBoundary()
            timerExecution.onTrackEnded(sessionId, timerExecution.generationFor(sessionId))
        }
        focusRecovery.onPlayWhenReadyChanged(sessionId, playWhenReady, reason)
        if (!progressHeartbeat.isScreenInteractive()) {
            playbackRecovery.rescheduleHealthCheckIfNeeded()
        }
        logInfo(
            "player_play_when_ready_changed playWhenReady=$playWhenReady " +
                "reason=${playWhenReadyReasonName(reason)}",
            sessionManager.get(sessionId)
        )
        statePersistence.schedulePersist()
        syncForegroundState()
    }

    private fun handleIsPlayingChanged(sessionId: String, isPlaying: Boolean) {
        if (!progressHeartbeat.isScreenInteractive()) {
            playbackRecovery.rescheduleHealthCheckIfNeeded()
        }
        logInfo("player_is_playing_changed isPlaying=$isPlaying", sessionManager.get(sessionId))
        statePersistence.schedulePersist()
        syncForegroundState()
    }

    private fun handlePlayerError(sessionId: String, error: PlaybackException) {
        focusRecovery.removePending(sessionId)
        playbackRecovery.onPlayerError(
            sessionId = sessionId,
            recoverable = isRecoverablePlaybackErrorCode(error.errorCode),
            candidateFallbackEligible = isCandidateFallbackPlaybackErrorCode(error.errorCode),
            rebuildPlayer = isPlayerRebuildRequiredForErrorCode(error.errorCode),
            errorCodeName = error.errorCodeName
        )
    }

    private fun focusSession(sessionId: String) {
        if (!sessionManager.contains(sessionId)) return
        if (focusedSessionId == sessionId) return
        focusedSessionId = sessionId
        updateMediaSessionPlayer()
    }

    private fun ensureMediaSession(): MediaSession? = mediaSessionHost.ensure()

    private fun updateMediaSessionPlayer() = mediaSessionHost.update()

    private fun ensureFocusedPlayer(session: NativePlaybackSession): ExoPlayer {
        val player = mediaSessionHost.ensurePlayer(session)
        videoOutputs.refreshSession(session.sessionId)
        return player
    }

    private fun mediaSessionCandidate(): NativePlaybackSession? = sessionManager.mediaSessionCandidate()

    private fun onMediaSessionPlayerCommand(command: Int) {
        val session = mediaSessionCandidate() ?: return
        when (command) {
            Player.COMMAND_STOP -> {
                clearTrackStopForManualCommand(session.sessionId)
                focusRecovery.removePending(session.sessionId)
                clearPlaybackIntent(session.sessionId)
            }
            Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
            Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
            Player.COMMAND_SEEK_TO_MEDIA_ITEM -> clearTrackStopForManualCommand(session.sessionId)
        }
    }

    private fun onMediaSessionSetPlayWhenReady(
        session: NativePlaybackSession,
        playWhenReady: Boolean
    ): Boolean {
        val sessionId = session.sessionId
        if (sessionManager.get(sessionId) !== session) return false
        clearTrackStopForManualCommand(sessionId)
        if (!playWhenReady) {
            focusRecovery.removePending(sessionId)
            clearPlaybackIntent(sessionId)
            if (session.playerOrNull()?.playWhenReady != true) syncForegroundState()
            return true
        }
        if (session.playerOrNull()?.playWhenReady == true) return true

        session.applyFadeMultiplier(1f)
        focusRecovery.removePending(sessionId)
        playbackSuspended = false
        focusSession(sessionId)
        markPlaybackIntended(sessionId)
        if (!establishForegroundPlaybackOrRollback(listOf(sessionId))) return false
        if (!focusRecovery.requestForExplicitPlayback()) {
            rollbackPlaybackStart(listOf(sessionId), "media_session_audio_focus_denied")
            return false
        }
        return true
    }

    private fun hasActivePlayback(): Boolean = sessionManager.hasActivePlayback()

    private fun markPlaybackIntended(sessionId: String) {
        foregroundCoordinator.settlePlaybackStart(sessionId)
        playbackRecovery.markIntended(sessionId)
    }

    private fun clearPlaybackIntent(sessionId: String) {
        foregroundCoordinator.settlePlaybackStart(sessionId)
        playbackRecovery.clear(sessionId)
    }
    private fun hasPlaybackToKeepAlive(): Boolean {
        return hasActivePlayback() ||
            hasPendingCommandDelivery() || restoreCoordinator.isRestoring ||
            foregroundCoordinator.hasPendingPlaybackStarts ||
            focusRecovery.hasPendingResume() ||
            playbackRecovery.shouldKeepAlive()
    }
    private fun onPlaybackWake(reason: String) {
        if (!hasPlaybackToKeepAlive()) return
        foregroundCoordinator.repairNotificationIfMissing()
        playbackRecovery.trigger(reason)
    }

    private fun foregroundSession(): NativePlaybackSession? = sessionManager.foregroundSessionCandidate()

    private fun shouldHoldCpuWakeLock(): Boolean =
        !playbackSuspended &&
            !focusRecovery.interruptionActive &&
            (hasActivePlayback() ||
                playbackRecovery.shouldKeepAlive() ||
                restoreCoordinator.isRestoring ||
                hasPendingCommandDelivery() ||
                foregroundCoordinator.hasPendingPlaybackStarts)

    private fun syncWakeLocks() {
        val keepCpu = shouldHoldCpuWakeLock()
        val keepWifi = keepCpu &&
            sessionManager.hasNetworkPlaybackToKeepAlive(playbackRecovery::isIntended)
        wakeLocks.sync(keepCpuAwake = keepCpu, keepWifiAwake = keepWifi)
    }

    private fun syncForegroundState() {
        val keepAlive = hasPlaybackToKeepAlive()
        if (keepAlive) pendingIdleExit = null
        if (shouldClearAudioFocusInterruptionState(keepAlive)) {
            focusRecovery.clearInterruptionState()
        }
        statePersistence.onPlaybackActivityChanged()
        foregroundCoordinator.sync()
    }

    private fun establishForegroundPlaybackOrRollback(sessionIds: Collection<String>): Boolean {
        syncWakeLocks()
        if (foregroundCoordinator.startOrUpdate().playbackAllowed) return true
        rollbackPlaybackStart(sessionIds, "foreground_start_failed")
        return false
    }

    private fun rollbackPlaybackStart(sessionIds: Collection<String>, reason: String) {
        sessionIds.forEach { sessionId ->
            focusRecovery.removePending(sessionId)
            clearPlaybackIntent(sessionId)
            sessionManager.get(sessionId)?.apply {
                applyFadeMultiplier(1f)
                playerOrNull()?.pause()
            }
            statePublisher.publishSessionState(sessionId)
        }
        if (!hasPlaybackToKeepAlive()) {
            focusRecovery.abandon(reason = reason)
        }
        statePersistence.persistNow()
        syncForegroundState()
    }

    private fun stopServiceForIdleExit(reason: String, startId: Int = restoreCoordinator.latestStartId) {
        val request = Any()
        pendingIdleExit = request
        // Flush on the process-scoped writer while the service is still alive.
        // New playback or a newer idle request invalidates this stop callback.
        statePersistence.flush {
            if (pendingIdleExit !== request) return@flush
            pendingIdleExit = null
            if (hasPlaybackToKeepAlive()) return@flush
            logInfo("idle_exit_stop_self reason=$reason startId=$startId")
            stoppingForIdleExit = true
            publishController(null)
            if (startId > 0) {
                if (!stopSelfResult(startId)) {
                    stoppingForIdleExit = false
                    publishController(this)
                }
            } else {
                stopSelf()
            }
        }
    }

    private fun releaseIdlePlaybackResources(reason: String) {
        progressHeartbeat.stop()
        statePersistence.stopTicker()
        statePersistence.cancelScheduledPersist()
        playbackRecovery.clearAll()
        videoOutputs.clear()
        sessionManager.allSessions.forEach { retireSession(it, "idle") }
        mediaSessionHost.release(reason)
    }

    private fun stopIdleServiceAfterRestore(startId: Int, reason: String, preserveVideo: Boolean = true) {
        usage.stop()
        val retainVideo = preserveVideo && statePublisher.hasListeners &&
            sessionManager.allSessions.any(::shouldRetainVideoPlayer)
        if (retainVideo) {
            // A paused video still belongs to the attached UI, even without a surface.
            // Retire any warm paused audio sessions once the idle grace expires.
            sessionManager.allSessions
                .filterNot(::shouldRetainVideoPlayer)
                .forEach { retireSession(it, "idle") }
            progressHeartbeat.stop()
            statePersistence.stopTicker()
            statePersistence.persistNow()
        } else {
            releaseIdlePlaybackResources(reason)
        }
        focusRecovery.abandon(reason = reason)
        foregroundCoordinator.stop(reason = reason)
        if (!retainVideo) stopServiceForIdleExit(reason, startId)
    }

    private fun logInfo(message: String, session: NativePlaybackSession? = null) {
        AppFileLogger.info(applicationContext, LOG_TAG, "$message ${playbackLogState(session)}")
    }

    private fun logWarn(
        message: String,
        session: NativePlaybackSession? = null,
        error: Throwable? = null
    ) = AppFileLogger.warn(applicationContext, LOG_TAG, "$message ${playbackLogState(session)}", error)

    private fun playbackLogState(session: NativePlaybackSession? = null): String =
        "${sessionManager.playbackLogState(session)}foregroundStarted=${foregroundCoordinator.isStarted} " +
            "cpuWakeHeld=${wakeLocks.isCpuWakeHeld} " +
            "wifiWakeHeld=${wakeLocks.isWifiWakeHeld} " +
            "audioFocusHeld=${audioFocusController.isHeld} " +
            "screenInteractive=${progressHeartbeat.isScreenInteractive()} " +
            "activePlayback=${hasActivePlayback()} " +
            "keepAlivePlayback=${hasPlaybackToKeepAlive()}"

    private fun logSecurityEvent(message: String, error: Throwable?) =
        AppFileLogger.warn(applicationContext, LOG_TAG, message, error)

    private fun okResult(value: Any?): Map<String, Any?> = channelSuccess(value)

    private fun errorResult(message: String): Map<String, Any?> {
        return channelFailure(
            code = ChannelErrorCodes.PLAYER_ERROR,
            message = message
        )
    }


}
