@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.doujin.audio.player.service

import com.doujin.audio.channel.*
import com.doujin.audio.common.*
import com.doujin.audio.player.common.*
import com.doujin.audio.player.notification.*
import com.doujin.audio.player.recovery.*
import com.doujin.audio.player.session.*
import com.doujin.audio.player.effects.NativePlaybackResumeFade
import com.doujin.audio.player.video.*
import com.doujin.audio.storage.*

import android.app.NotificationManager
import android.content.Context
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
        private const val FOREGROUND_NOTIFICATION_ID = 1107
        private const val FOREGROUND_WATCHDOG_INTERVAL_MS = 4 * 60 * 1000L
        private const val STATE_PERSISTENCE_INTERVAL_MS = 15 * 1000L
        private const val STATE_PERSISTENCE_DEBOUNCE_MS = 800L
        private const val PLAYBACK_STOP_GRACE_MS = 0L
        private const val PROGRESS_HEARTBEAT_INTERVAL_MS = 500L
        private const val SCREEN_OFF_PROGRESS_HEARTBEAT_INTERVAL_MS = 5000L
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
                PlaybackTimerAlarmScheduler.completeTimerStopAfterCurrentTracks(applicationContext, generation)
            }
        )
    }
    private val timerResumeFade by lazy {
        NativePlaybackResumeFade(mainHandler) { id, multiplier ->
            sessionManager.get(id)?.applyFadeMultiplier(multiplier)
        }
    }
    private val fileCacheOperations by lazy { FileCacheOperations(applicationContext) }
    private val stateListeners = ConcurrentHashMap<String, (Map<String, Any?>) -> Unit>()
    private val pendingStateSessions = linkedSetOf<String>()
    private val publishPendingStates = Runnable {
        val pending = pendingStateSessions.toList()
        pendingStateSessions.clear()
        pending.forEach(::publishSessionState)
    }
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
    private val progressPublisher by lazy {
        NativePlaybackProgressPublisher(
            mainHandler = mainHandler,
            anchors = { sessionManager.progressAnchors() },
            currentAnchors = { sessionManager.progressAnchorsMap() },
            listeners = { stateListeners.values }
        )
    }
    private val statePersistence by lazy {
        NativePlaybackStatePersistenceCoordinator(
            context = applicationContext,
            mainHandler = mainHandler,
            intervalMs = STATE_PERSISTENCE_INTERVAL_MS,
            debounceMs = STATE_PERSISTENCE_DEBOUNCE_MS,
            hasSessions = { sessionManager.isNotEmpty },
            hasActivePlayback = ::hasActivePlayback,
            storedSessions = { sessionManager.storedSnapshots(playbackRecovery.intendedSessionIds) },
            sessionRevisions = { sessionManager.allSessions.associate { it.sessionId to it.definitionRevision } }
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
            resolveUriToPath = { uri -> fileCacheOperations.contentUriToFilePath(uri) },
            isCurrentPlayer = { id, player -> sessionManager.get(id)?.playerOrNull() === player },
            callbacks = object : NativePlayerEventCallbacks {
                override fun onPlaybackStateChanged(sessionId: String, playbackState: Int) {
                    handlePlaybackStateChanged(sessionId, playbackState)
                }

                override fun onMediaItemTransition(sessionId: String, reason: Int) {
                    handleMediaItemTransition(sessionId, reason)
                }

                override fun onPlayerEvents(sessionId: String) {
                    pendingStateSessions.add(sessionId)
                    mainHandler.removeCallbacks(publishPendingStates)
                    mainHandler.post(publishPendingStates)
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
            isStoredSessionCurrent = { NativePlaybackStateStore.sessionRevision(it.sessionId) == it.definitionRevision },
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
                    stateListeners.isNotEmpty() && sessionManager.hasProgressSessions

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
                override fun refreshWakeLock() = this@NativePlaybackService.refreshWakeLock()
                override fun triggerRecovery(reason: String) = playbackRecovery.trigger(reason)
                override fun expireGraceIfOverdue(): Boolean =
                    foregroundCoordinator.expireGraceIfOverdue()
                override fun syncForeground() {
                    syncForegroundState()
                    foregroundCoordinator.triggerWatchdog()
                }
                override fun cancelAlarm() =
                    PlaybackKeepAliveAlarmScheduler.cancel(this@NativePlaybackService)
                override fun ensureAlarm() =
                    PlaybackKeepAliveAlarmScheduler.ensureScheduled(
                        this@NativePlaybackService,
                        activePlayback = hasPlaybackToKeepAlive()
                    )
                override fun logHeartbeat() {
                    logInfo(
                        "keep_alive_heartbeat wakeLockHeld=${playbackWakeLock.isHeld()} " +
                            "wifiLockHeld=${playbackWakeLock.isWifiLockHeld()} " +
                            "playback=${hasPlaybackToKeepAlive()} " +
                            "foregroundStarted=${foregroundCoordinator.isStarted}"
                    )
                }
            }
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
            resetRestoreState = {

                playbackSuspended = false
            },
            completeRestore = { restoredSessionIds ->
                evictPlayersIfNeeded()
                restoredSessionIds.forEach(::publishSessionState)
                progressHeartbeat.ensure()
                statePersistence.ensureTicker()
                statePersistence.persistNow()
                syncForegroundState()
            },
            sessionExists = sessionManager::contains,
            hasSessions = { sessionManager.isNotEmpty },
            hasPlaybackToKeepAlive = ::hasPlaybackToKeepAlive,
            hasPendingCommandDelivery = ::hasPendingCommandDelivery,
            stopIdleService = ::stopIdleServiceAfterRestore,
            onMissingSessionsRestored = { restoredSessionIds ->
                restoredSessionIds.forEach(::publishSessionState)
                evictPlayersIfNeeded()
                statePersistence.persistNow()
            },
            logInfo = ::logInfo,
            logWarn = { message, error -> logWarn(message, error = error) }
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
                override fun publishAllSessions() = publishAllSessionStates()
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
                override fun focusSession(sessionId: String) = this@NativePlaybackService.focusSession(sessionId)
                override fun ensurePlayer(session: NativePlaybackSession) = ensureFocusedPlayer(session)
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
                    session.releasePlayer()
                    if (focusedSessionId == sessionId) updateMediaSessionPlayer()
                    publishSessionState(sessionId)
                    statePersistence.persistNow()
                    if (!hasPlaybackToKeepAlive()) {
                        focusRecovery.abandon(reason = "playback_recovery_timed_out")
                        releaseWakeLock()
                        PlaybackKeepAliveAlarmScheduler.cancel(this@NativePlaybackService)
                        releaseIdlePlaybackResources("playback_recovery_timed_out")
                        foregroundCoordinator.cancelGrace()
                        foregroundCoordinator.stopWatchdog()
                        foregroundCoordinator.stop(reason = "playback_recovery_timed_out")
                        stopSelf()
                    }
                }
                override fun publishSession(sessionId: String) {
                    publishSessionState(sessionId)
                }
                override fun publishAllSessions() = publishAllSessionStates()
                override fun persistNow() = statePersistence.persistNow()
                override fun schedulePersist() = statePersistence.schedulePersist()
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
    private val foregroundCoordinator: NativePlaybackForegroundCoordinator by lazy {
        NativePlaybackForegroundCoordinator(
            host = object : NativePlaybackForegroundHost {
                override val hasPlaybackToKeepAlive: Boolean
                    get() = this@NativePlaybackService.hasPlaybackToKeepAlive()
                override val hasSessions: Boolean
                    get() = sessionManager.isNotEmpty
                override val playbackSuspended: Boolean
                    get() = this@NativePlaybackService.playbackSuspended
                override fun playbackSignature(): String? =
                    if (foregroundSession() != null) "playback" else null

                override fun onActiveSync() {
                    acquireWakeLock()
                    PlaybackKeepAliveAlarmScheduler.ensureScheduled(
                        this@NativePlaybackService,
                        activePlayback = true
                    )
                    if (!focusRecovery.interruptionActive) {
                        focusRecovery.requestIfNeeded()
                        if (focusRecovery.resumePendingIfPossible("foreground_sync_focus_available")) {
                            statePersistence.schedulePersist()
                        }
                    }
                    statePersistence.ensureTicker()
                }

                override fun onIdleGraceBegan() {
                    releaseWakeLock()
                    PlaybackKeepAliveAlarmScheduler.ensureScheduled(
                        this@NativePlaybackService,
                        activePlayback = false
                    )
                    statePersistence.persistNow()
                }

                override fun isForegroundNotificationPosted(): Boolean? =
                    isPlaybackNotificationPosted()

                override fun onGraceExpired() {
                    stopIdleServiceAfterRestore(restoreCoordinator.latestStartId, "idle_no_playback")
                }

                override fun onWatchdog() {
                    refreshWakeLock()
                    PlaybackKeepAliveAlarmScheduler.ensureScheduled(
                        this@NativePlaybackService,
                        activePlayback = hasPlaybackToKeepAlive()
                    )
                    if (!focusRecovery.interruptionActive) {
                        playbackRecovery.trigger("foreground_watchdog")
                    }
                }

                override fun startPlaybackForeground() {
                    ServiceCompat.startForeground(
                        this@NativePlaybackService,
                        FOREGROUND_NOTIFICATION_ID,
                        foregroundNotificationFactory.buildNotification(),
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                    )
                }

                override fun startBootstrapForeground() {
                    mediaSessionHost.ensureBootstrap()
                    ServiceCompat.startForeground(
                        this@NativePlaybackService,
                        FOREGROUND_NOTIFICATION_ID,
                        foregroundNotificationFactory.buildNotification(),
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                    )
                    acquireWakeLock()
                }

                override fun stopForeground(wasStarted: Boolean) {
                    if (wasStarted) {
                        this@NativePlaybackService.stopForeground(STOP_FOREGROUND_REMOVE)
                    }
                    val manager =
                        getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                    manager?.cancel(FOREGROUND_NOTIFICATION_ID)
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
        foregroundNotificationFactory.ensureChannel()
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
            shouldAttemptStickyPlaybackRestore(sessionManager.isNotEmpty, attemptedStickyPlaybackRestore)
        ) {
            attemptedStickyPlaybackRestore = true
            restoreCoordinator.restoreAfterServiceRestart(startId)
        }
        return START_STICKY
    }

    private fun rejectedStartResult(startId: Int): Int {
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
        logInfo("on_task_removed hasActivePlayback=${hasPlaybackToKeepAlive()}")
        if (foregroundCoordinator.onTaskRemoved()) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        logInfo(
            "on_destroy_begin sessions=${sessionManager.size} " +
                "foregroundStarted=${foregroundCoordinator.isStarted} " +
                "wakeLockHeld=${playbackWakeLock.isHeld()}"
        )
        var firstFailure = runPlaybackShutdownActions(
            listOf(
                stateListeners::clear,
                { mainHandler.removeCallbacks(publishPendingStates); pendingStateSessions.clear() },
                videoOutputs::clear,
                restoreCoordinator::shutdown,
                audioDeviceDisconnectMonitor::shutdown,
                progressHeartbeat::shutdown,
                progressPublisher::shutdown,
                queuePreparation::shutdown,
                statePersistence::shutdown,
                playbackRecovery::dispose,
                { mediaSessionHost.release("on_destroy") },
                {
                    runPlaybackShutdownActions(sessionManager.releaseAll())
                        ?.let { throw it }
                },
                sessionManager::clear,
                foregroundCoordinator::shutdown,
                { focusRecovery.abandon(reason = "on_destroy") },
                ::releaseWakeLock,
                { PlaybackKeepAliveAlarmScheduler.cancel(this) },
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
        logInfo("on_destroy_end")
        firstFailure?.let { throw it }
    }

    fun addStateListener(ownerId: String, listener: (Map<String, Any?>) -> Unit) {
        stateListeners[ownerId] = listener
        sessionManager.forEach {
            listener(it.snapshot())
            sessionManager.updateProgressSession(it.sessionId)
        }
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
        val nativeSession = sessionManager.getOrCreate(sessionId)
        if (nativeSession.path != null && (nativeSession.path != args.path || nativeSession.queueIndex != args.queueStartIndex)) {
            clearTrackStopForManualCommand(sessionId)
        }
        focusRecovery.removePending(sessionId)
        return try {
            nativeSession.configure(args.copy(deferPlayerCreation = !args.autoPlay))
            if (args.autoPlay) {
                playbackSuspended = false
                focusSession(sessionId)
                markPlaybackIntended(sessionId)
                if (!establishForegroundPlaybackOrRollback(listOf(sessionId))) {
                    return errorResult(FOREGROUND_PLAYBACK_UNAVAILABLE_ERROR)
                }
                if (!focusRecovery.requestIfNeeded()) {
                    rollbackPlaybackStart(listOf(sessionId), "audio_focus_denied")
                    return errorResult("Audio focus was denied.")
                }
                ensureFocusedPlayer(nativeSession).play()
            } else {
                clearPlaybackIntent(sessionId)
                if (!args.deferPlayerCreation) foregroundCoordinator.holdPlaybackStart(sessionId)
            }
            evictPlayersIfNeeded()
            publishSessionState(sessionId)
            progressHeartbeat.ensure()
            statePersistence.persistNow()
            statePersistence.ensureTicker()
            syncForegroundState()
            okResult(nativeSession.snapshot())
        } catch (e: Exception) {
            val wasFocused = focusedSessionId == sessionId
            sessionManager.remove(sessionId)
            nativeSession.release()
            clearPlaybackIntent(sessionId)
            if (wasFocused) {
                updateMediaSessionPlayer()
            }
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
            session.clearQueue()
            updateMediaSessionPlayer()
        } else {
            session.updateQueue(args.queue, args.queueStartIndex, args.repeatOne,
                args.repeatAll, args.shuffle, prepared)
        }
        val snapshot = publishSessionState(args.sessionId)
        statePersistence.schedulePersist()
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
        if (session.stoppedAtTrackBoundary) clearTrackStopForManualCommand(sessionId)
        val pausedSessionIds = if (exclusive) {
            exclusivePlaybackSessionIdsToPause(
                targetSessionId = sessionId,
                sessionPlaybackIntent = sessionManager.allSessions.associate { candidate ->
                    val player = candidate.playerOrNull()
                    candidate.sessionId to (
                        playbackRecovery.isIntended(candidate.sessionId) ||
                            player?.isPlaying == true ||
                            player?.playWhenReady == true
                    )
                }
            )
        } else {
            emptyList()
        }
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
        session.applyFocusDuckMultiplier(1f)
        focusSession(sessionId)
        if (!establishForegroundPlaybackOrRollback(listOf(sessionId))) {
            return errorResult(FOREGROUND_PLAYBACK_UNAVAILABLE_ERROR)
        }
        if (!focusRecovery.requestIfNeeded()) {
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
        }
        if (!playbackRecovery.isRecovering(sessionId)) ensureFocusedPlayer(session).play()
        evictPlayersIfNeeded()
        pausedSessionIds.forEach(::publishSessionState)
        val snapshot = publishSessionState(sessionId)
        progressHeartbeat.ensure()
        statePersistence.schedulePersist()
        statePersistence.ensureTicker()
        syncForegroundState()
        return okResult(snapshot)
    }

    fun pause(
        sessionId: String,
        transportCommandId: Long = 0L
    ): Map<String, Any?> {
        clearTrackStopForManualCommand(sessionId)
        queuePreparation.cancel(sessionId)
        restoreCoordinator.excludeSessionFromRestartRestore(sessionId)
        timerResumeFade.cancel()
        val session = sessionManager.get(sessionId) ?: return okResult(null)
        if (transportCommandId > 0L) session.transportCommandId = transportCommandId
        focusRecovery.removePending(sessionId)
        clearPlaybackIntent(sessionId)
        session.playerOrNull()?.pause()
        val snapshot = retirePausedSession(session)
        evictPlayersIfNeeded()
        statePersistence.schedulePersist()
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
        val snapshot = retirePausedSession(session)
        evictPlayersIfNeeded()
        statePersistence.persistNow()
        syncForegroundState()
        return okResult(snapshot)
    }

    fun skipToNext(sessionId: String): Map<String, Any?> {
        clearTrackStopForManualCommand(sessionId)
        val session = sessionManager.get(sessionId) ?: return errorResult("Session not found")
        focusSession(sessionId)
        playbackRecovery.resetHealth(sessionId, "skip_next", cancelRecovery = true)
        session.skipQueue(forward = true)
        evictPlayersIfNeeded()
        publishSessionState(sessionId)
        statePersistence.persistNow()
        syncForegroundState()
        return okResult(session.snapshot())
    }

    fun skipToPrevious(sessionId: String): Map<String, Any?> {
        clearTrackStopForManualCommand(sessionId)
        val session = sessionManager.get(sessionId) ?: return errorResult("Session not found")
        focusSession(sessionId)
        playbackRecovery.resetHealth(sessionId, "skip_previous", cancelRecovery = true)
        session.skipQueue(forward = false)
        evictPlayersIfNeeded()
        publishSessionState(sessionId)
        statePersistence.persistNow()
        syncForegroundState()
        return okResult(session.snapshot())
    }

    fun togglePlayPause(sessionId: String): Map<String, Any?> {
        val session = sessionManager.get(sessionId) ?: return errorResult("Session not found")
        focusRecovery.removePending(sessionId)
        playbackSuspended = false
        focusSession(sessionId)
        val player = ensureFocusedPlayer(session)
        clearTrackStopForManualCommand(sessionId)
        if (player.playWhenReady) {
            clearPlaybackIntent(sessionId)
            player.pause()
        } else {
            markPlaybackIntended(sessionId)
            session.applyFadeMultiplier(1f)
            session.applyFocusDuckMultiplier(1f)
            if (!establishForegroundPlaybackOrRollback(listOf(sessionId))) {
                return errorResult(FOREGROUND_PLAYBACK_UNAVAILABLE_ERROR)
            }
            if (!focusRecovery.requestIfNeeded()) {
                rollbackPlaybackStart(listOf(sessionId), "audio_focus_denied")
                return errorResult("Audio focus was denied.")
            }
            player.play()
        }
        evictPlayersIfNeeded()
        publishSessionState(sessionId)
        progressHeartbeat.ensure()
        statePersistence.persistNow()
        statePersistence.ensureTicker()
        syncForegroundState()
        return okResult(session.snapshot())
    }

    fun seek(sessionId: String, positionMs: Long): Map<String, Any?> {
        val session = sessionManager.get(sessionId) ?: return errorResult("Unknown session.")
        playbackRecovery.resetHealth(sessionId, "seek", cancelRecovery = true)
        session.seekTo(positionMs)
        publishSessionState(sessionId)
        statePersistence.schedulePersist()
        return okResult(session.snapshot())
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
        publishSessionState(sessionId)
        statePersistence.schedulePersist()
        return okResult(session.snapshot())
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
        return okResult(publishSessionState(sessionId))
    }

    private fun clearTrackStopForManualCommand(sessionId: String) {
        // Update recovery IDs before settling the last target, which may schedule resume.
        PlaybackTimerAlarmScheduler.onManualPlaybackStopped(this, sessionId)
        sessionManager.get(sessionId)?.let {
            it.stopAfterCurrentTrack = false
            it.stoppedAtTrackBoundary = false
            it.syncPauseAtTrackEnd()
        }
        timerExecution.removeTarget(sessionId)
    }

    fun setSpeed(sessionId: String, speed: Float): Map<String, Any?> {
        val session = sessionManager.get(sessionId) ?: return errorResult("Unknown session.")
        session.applySpeed(speed)
        publishSessionState(sessionId)
        statePersistence.schedulePersist()
        return okResult(session.snapshot())
    }

    fun setTemporarySpeed(sessionId: String, speed: Float?): Map<String, Any?> {
        val session = sessionManager.get(sessionId) ?: return errorResult("Unknown session.")
        session.applyTemporarySpeed(speed)
        publishSessionState(sessionId)
        return okResult(session.snapshot())
    }

    fun clearTemporarySpeeds() {
        sessionManager.forEach { session ->
            session.applyTemporarySpeed(null)
            session.snapshot()
        }
    }

    internal fun setAudioEffects(sessionId: String, effects: NativeAudioEffects): Map<String, Any?> {
        val session = sessionManager.get(sessionId) ?: return errorResult("Unknown session.")
        val previousChannelSwap = session.channelSwapEnabled
        session.applyAudioEffects(effects)
        if (session.hasPlayer() && previousChannelSwap != session.channelSwapEnabled) {
            session.reprepareCurrentMediaItem()
        }
        publishSessionState(sessionId)
        statePersistence.schedulePersist()
        syncForegroundState()
        return okResult(session.snapshot())
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
        sessionManager.remove(sessionId)?.release()
        statePersistence.removeSession(sessionId)
        if (wasFocused) {
            updateMediaSessionPlayer()
        }
        if (sessionManager.isEmpty) {
            foregroundCoordinator.cancelGrace()
            foregroundCoordinator.stopWatchdog()
            statePersistence.stopTicker()
            statePersistence.cancelScheduledPersist()
            mediaSessionHost.release("remove_session_empty")
            focusRecovery.abandon(reason = "remove_session_empty")
            PlaybackKeepAliveAlarmScheduler.cancel(this)
            foregroundCoordinator.stop(reason = "remove_session_empty")
            stopSelf()
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
        sessionManager.allSessions.forEach {
            clearTrackStopForManualCommand(it.sessionId)
            foregroundCoordinator.settlePlaybackStart(it.sessionId)
            it.playerOrNull()?.pause()
            retirePausedSession(it)
        }
        evictPlayersIfNeeded()
        publishAllSessionStates()
        statePersistence.persistNow()
        foregroundCoordinator.cancelGrace()
        foregroundCoordinator.stopWatchdog()
        playbackSuspended = true
        focusRecovery.abandon(reason = "pause_all")
        releaseWakeLock()
        PlaybackKeepAliveAlarmScheduler.cancel(this)
        foregroundCoordinator.stop(reason = "pause_all")
        return okResult(null)
    }

    fun clearAll(): Map<String, Any?> {
        queuePreparation.cancelAll()
        restoreCoordinator.cancelRestartRestore()
        focusRecovery.clearInterruptionState()
        playbackRecovery.clearAll()
        sessionManager.forEach { it.release() }
        sessionManager.clear()
        mediaSessionHost.release("clear_all")
        foregroundCoordinator.cancelGrace()
        foregroundCoordinator.stopWatchdog()
        statePersistence.stopTicker()
        statePersistence.cancelScheduledPersist()
        statePersistence.clearSessions()
        NativePlaybackStateStore.clearPausedSessionIds(this)
        NativePlaybackStateStore.clearTimerCandidateSessionIds(this)
        NativePlaybackStateStore.clearTimerRuntimeState(this)
        focusRecovery.abandon(reason = "clear_all")
        PlaybackKeepAliveAlarmScheduler.cancel(this)
        foregroundCoordinator.stop(reason = "clear_all")
        stopSelf()
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
        playbackBehavior = StoredPlaybackBehavior(
            pauseOnAudioDeviceDisconnect = pauseOnAudioDeviceDisconnect,
            requestAudioFocus = requestAudioFocus,
            pauseOnTransientAudioFocusLoss = pauseOnTransientAudioFocusLoss,
            resumeAfterTransientAudioFocusGain = resumeAfterTransientAudioFocusGain
        )
        NativePlaybackStateStore.savePlaybackBehavior(this, playbackBehavior)
        if (!requestAudioFocus) {
            focusRecovery.abandon(reason = "mix_with_others_enabled")
            publishAllSessionStates()
            statePersistence.schedulePersist()
        } else if (!previouslyRequestedAudioFocus && hasActivePlayback()) {
            if (!focusRecovery.requestIfNeeded()) {
                logInfo("audio_focus_policy_restore_denied")
                focusRecovery.onFocusChange(AudioManager.AUDIOFOCUS_LOSS)
            }
        }
        return okResult(null)
    }

    fun stopPlayingSessionsAfterCurrentTrackForTimer(generation: Int): List<String> {
        val sessionIds = sessionManager.activePlaybackSessionIds()
        if (sessionIds.isEmpty()) {
            syncForegroundState()
            return emptyList()
        }
        focusRecovery.clearTransientLoss()
        sessionIds.forEach { sessionId ->
            focusRecovery.removePending(sessionId)
            clearPlaybackIntent(sessionId)
        }
        timerExecution.arm(sessionIds, generation)
        publishAllSessionStates()
        statePersistence.persistNow()
        syncForegroundState()
        return sessionIds
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
            publishAllSessionStates()
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
            beforeRelease = { session ->
                videoOutputs.detachPlayer(session.sessionId)
                if (mediaSessionHost.current()?.player === session.playerOrNull()) {
                    mediaSessionHost.release("idle_session")
                }
            }
        ).forEach(::retirePausedSession)
        updateMediaSessionPlayer()
    }

    private fun retirePausedSession(session: NativePlaybackSession): Map<String, Any?> = retireSession(session, "idle")

    private fun retireSession(session: NativePlaybackSession, processingState: String): Map<String, Any?> {
        videoOutputs.detachPlayer(session.sessionId)
        if (mediaSessionHost.current()?.player === session.playerOrNull()) mediaSessionHost.release("idle_session")
        pendingStateSessions.remove(session.sessionId)
        val snapshot = sessionManager.releaseIdleSession(session, statePersistence, processingState) {
            publishNativePlaybackSessionState(it, stateListeners.values)
        }
        progressHeartbeat.stopIfUnobserved()
        return snapshot
    }

    private fun createNativePlaybackSession(sessionId: String): NativePlaybackSession {
        return NativePlaybackSession(
            sessionId = sessionId,
            createPlayer = playerFactory::create,
            logWarn = { message, session, error -> logWarn(message, session, error) }
        )
    }

    private fun handlePlaybackStateChanged(sessionId: String, playbackState: Int) {
        if (playbackState == Player.STATE_ENDED) {
            markTrackStopBoundary(sessionId)
            timerExecution.onTrackEnded(sessionId, timerExecution.generationFor(sessionId))
            clearPlaybackIntent(sessionId)
            focusRecovery.removePending(sessionId)
            sessionManager.get(sessionId)?.let { retireSession(it, "completed") }
            updateMediaSessionPlayer()
        }
        logInfo(
            "player_state_changed state=${playbackStateName(playbackState)}",
            sessionManager.get(sessionId)
        )
        statePersistence.schedulePersist()
        syncForegroundState()
    }

    private fun handleMediaItemTransition(sessionId: String, reason: Int) {
        sessionManager.get(sessionId)?.syncCurrentMediaItemFromPlayer()
        playbackRecovery.resetHealth(sessionId, "media_item_transition")
        logInfo(
            "player_media_item_transition reason=$reason",
            sessionManager.get(sessionId)
        )
        acquireWakeLock()
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
            markTrackStopBoundary(sessionId)
            timerExecution.onTrackEnded(sessionId, timerExecution.generationFor(sessionId))
        }
        focusRecovery.onPlayWhenReadyChanged(sessionId, playWhenReady, reason)
        logInfo(
            "player_play_when_ready_changed playWhenReady=$playWhenReady " +
                "reason=${playWhenReadyReasonName(reason)}",
            sessionManager.get(sessionId)
        )
        statePersistence.schedulePersist()
        syncForegroundState()
    }

    private fun handleIsPlayingChanged(sessionId: String, isPlaying: Boolean) {
        logInfo("player_is_playing_changed isPlaying=$isPlaying", sessionManager.get(sessionId))
        if (isPlaying) {
            playbackRecovery.onPlaying(sessionId)
            PlaybackTimerAlarmScheduler.onPlaybackStarted(this, sessionId)
        }
        statePersistence.schedulePersist()
        syncForegroundState()
    }

    private fun markTrackStopBoundary(sessionId: String) {
        sessionManager.get(sessionId)?.let {
            it.stoppedAtTrackBoundary = it.stoppedAtTrackBoundary ||
                it.stopAfterCurrentTrack || it.timerStopAfterCurrentTrack
            it.stopAfterCurrentTrack = false
            it.syncPauseAtTrackEnd()
        }
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
        if (!sessionManager.contains(sessionId)) return
        if (focusedSessionId == sessionId) return
        focusedSessionId = sessionId
        updateMediaSessionPlayer()
    }

    private fun ensureMediaSession(): MediaSession? = mediaSessionHost.ensure()

    private fun updateMediaSessionPlayer() = mediaSessionHost.update()

    private fun ensureFocusedPlayer(session: NativePlaybackSession): ExoPlayer =
        mediaSessionHost.ensurePlayer(session)

    private fun mediaSessionCandidate(): NativePlaybackSession? = sessionManager.mediaSessionCandidate()

    private fun handleMediaSessionPlayerCommandRequest(
        command: Int,
        playWhenReady: Boolean
    ): Int {
        val session = mediaSessionCandidate()
        if (session != null && command in setOf(
                Player.COMMAND_PLAY_PAUSE, Player.COMMAND_STOP,
                Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_MEDIA_ITEM
            )) {
            clearTrackStopForManualCommand(session.sessionId)
            if (command == Player.COMMAND_PLAY_PAUSE && !playWhenReady) {
                session.applyFadeMultiplier(1f)
            }
        }
        return com.doujin.audio.player.session.handleMediaSessionPlayerCommandRequest(
            command = command,
            playWhenReady = playWhenReady,
            requestAudioFocus = {
                session != null && focusRecovery.requestIfNeeded()
            },
            establishForegroundPlayback = {
                session != null &&
                    establishForegroundPlaybackOrRollback(listOf(session.sessionId))
            },
            markPlaybackIntended = {
                if (session != null) {
                    focusRecovery.removePending(session.sessionId)
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
    private fun foregroundSession(): NativePlaybackSession? = sessionManager.foregroundSessionCandidate()

    private fun syncForegroundState() {
        if (shouldClearAudioFocusInterruptionState(hasPlaybackToKeepAlive())) {
            focusRecovery.clearInterruptionState()
        }
        statePersistence.onPlaybackActivityChanged()
        foregroundCoordinator.sync()
    }

    private fun establishForegroundPlaybackOrRollback(sessionIds: Collection<String>): Boolean {
        if (foregroundCoordinator.startOrUpdate().playbackAllowed) return true
        rollbackPlaybackStart(sessionIds, "foreground_start_failed")
        return false
    }

    private fun rollbackPlaybackStart(sessionIds: Collection<String>, reason: String) {
        sessionIds.forEach { sessionId ->
            focusRecovery.removePending(sessionId)
            clearPlaybackIntent(sessionId)
            sessionManager.get(sessionId)?.playerOrNull()?.pause()
            publishSessionState(sessionId)
        }
        if (!hasPlaybackToKeepAlive()) {
            focusRecovery.abandon(reason = reason)
            releaseWakeLock()
        }
        statePersistence.persistNow()
        syncForegroundState()
    }

    private fun releaseIdlePlaybackResources(reason: String) {
        progressHeartbeat.stop()
        statePersistence.stopTicker()
        statePersistence.cancelScheduledPersist()
        playbackRecovery.clearAll()
        videoOutputs.clear()
        sessionManager.allSessions.forEach(::retirePausedSession)
        mediaSessionHost.release(reason)
    }

    private fun stopIdleServiceAfterRestore(startId: Int, reason: String) {
        statePersistence.persistNow()
        releaseIdlePlaybackResources(reason)
        foregroundCoordinator.cancelGrace()
        foregroundCoordinator.stopWatchdog()
        focusRecovery.abandon(reason = reason)
        releaseWakeLock()
        PlaybackKeepAliveAlarmScheduler.cancel(this)
        foregroundCoordinator.stop(reason = reason)
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
        return try {
            val manager =
                getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                    ?: return null
            manager.activeNotifications.any { it.id == FOREGROUND_NOTIFICATION_ID }
        } catch (_: Exception) {
            null
        }
    }

    private fun updateWakeLockNetworkState() {
        playbackWakeLock.setNetworkPlaybackActive(sessionManager.hasNetworkPlayback(playbackRecovery::isIntended))
    }

    private fun acquireWakeLock() {
        updateWakeLockNetworkState()
        playbackWakeLock.acquire()
    }

    private fun refreshWakeLock() {
        updateWakeLockNetworkState()
        playbackWakeLock.refresh()
    }

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
        return sessionManager.playbackLogState(session) +
            "foregroundStarted=${foregroundCoordinator.isStarted} " +
            "notificationPosted=${isPlaybackNotificationPosted()} " +
            "wakeLockHeld=${playbackWakeLock.isHeld()} " +
            "wifiLockHeld=${playbackWakeLock.isWifiLockHeld()} " +
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
        pendingStateSessions.remove(sessionId)
        val session = sessionManager.get(sessionId) ?: return null
        val snapshot = publishNativePlaybackSessionState(session, stateListeners.values)
        sessionManager.updateProgressSession(sessionId)
        progressHeartbeat.stopIfUnobserved()
        progressHeartbeat.ensure()
        return snapshot
    }

    private fun publishAllSessionStates() {
        sessionManager.sessionIds.toList().forEach { publishSessionState(it) }
    }

    private fun okResult(value: Any?): Map<String, Any?> = channelSuccess(value)

    private fun errorResult(message: String): Map<String, Any?> {
        return channelFailure(
            code = ChannelErrorCodes.PLAYER_ERROR,
            message = message
        )
    }


}
