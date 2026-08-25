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

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
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
        // Grace period before releasing the wake lock / stopping foreground after
        // playback appears to have stopped. Android's background-audio guidance
        // recommends keeping a mediaPlayback foreground service alive through
        // transient buffering/focus failures under 10 minutes; a short grace
        // window lets screen-off playback get killed during those gaps.
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
                controller()?.onPendingCommandDeliveriesSettled()
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
    private val restoreCoordinator by lazy {
        NativePlaybackRestoreCoordinator(
            context = applicationContext,
            mainHandler = mainHandler,
            sessionRestorer = sessionRestorer,
            resumePlaybackOnStartupRestore = {
                playbackBehavior.resumePlaybackOnStartupRestore
            },
            requestAudioFocus = ::requestAudioFocusIfNeeded,
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
                ensureTicker()
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

    private fun ensureMediaSessionForBootstrap() = mediaSessionHost.ensureBootstrap()

    var focusedSessionId: String? = null
        private set
    private var tickerScheduled = false
    private var playbackSuspended = false
    private val audioFocusController by lazy {
        NativeAudioFocusController(
            context = applicationContext,
            handler = mainHandler,
            logInfo = ::logInfo,
            logWarn = { message, error -> logWarn(message, error = error) },
            onFocusChange = ::handleAudioFocusChange
        )
    }
    private val playbackRecovery by lazy {
        NativePlaybackRecoveryController(
            host = object : NativePlaybackRecoveryHost {
                override fun session(sessionId: String) = sessions[sessionId]
                override fun requestAudioFocus() = requestAudioFocusIfNeeded()
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
                    // Armed as soon as playback is active, not at the first
                    // watchdog tick 4 minutes later: if an OEM power manager
                    // revokes the wake lock before then, every handler timer
                    // stalls and nothing would be left to arm the backstop.
                    // Re-arming is throttled inside the scheduler.
                    PlaybackKeepAliveAlarmScheduler.ensureScheduled(
                        this@NativePlaybackService
                    )
                    if (!shouldDeferPlaybackRecoveryForTransientAudioFocusLoss(
                            transientAudioFocusLossActive || focusDuckActive
                        )
                    ) {
                        requestAudioFocusIfNeeded()
                        if (resumePendingAudioFocusSessionsIfPossible("foreground_sync_focus_available")) {
                            schedulePersistSessionState()
                        }
                    }
                    ensureStatePersistenceTicker()
                }

                override fun onIdleGraceBegan() {
                    // Keep the foreground service and audio focus (playback may
                    // resume within the grace window) but stop burning battery
                    // on a wake lock that no audio pipeline needs right now.
                    releaseWakeLock()
                    // The grace timer runs on uptimeMillis and the wake lock is
                    // now gone, so it can stall in deep sleep. The alarm is what
                    // guarantees the window eventually closes.
                    PlaybackKeepAliveAlarmScheduler.ensureScheduled(
                        this@NativePlaybackService
                    )
                    persistSessionStateNow()
                }

                override fun isForegroundNotificationPosted(): Boolean? =
                    isPlaybackNotificationPosted()

                override fun onSuppressedIdle() {
                    abandonAudioFocus(reason = "suppressed_no_active_playback")
                    releaseWakeLock()
                    PlaybackKeepAliveAlarmScheduler.cancel(this@NativePlaybackService)
                    persistSessionStateNow()
                }

                override fun onGraceExpired() {
                    abandonAudioFocus(reason = "grace_expired_no_active_playback")
                    releaseWakeLock()
                    PlaybackKeepAliveAlarmScheduler.cancel(this@NativePlaybackService)
                    persistSessionStateNow()
                }

                override fun onWatchdog() {
                    playbackWakeLock.refresh()
                    PlaybackKeepAliveAlarmScheduler.ensureScheduled(
                        this@NativePlaybackService
                    )
                    if (!shouldDeferPlaybackRecoveryForTransientAudioFocusLoss(
                            transientAudioFocusLossActive || focusDuckActive
                        )
                    ) {
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
                    ensureMediaSessionForBootstrap()
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
    private var transientAudioFocusLossActive = false
    private var focusDuckActive = false
    private val pendingAudioFocusResumeSessionIds = linkedSetOf<String>()
    private var attemptedStickyPlaybackRestore = false
    private var playbackBehavior = StoredPlaybackBehavior()
    private var audioDeviceDisconnectReceiverRegistered = false
    private val audioDeviceDisconnectReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != AudioManager.ACTION_AUDIO_BECOMING_NOISY) return
            handleAudioDeviceDisconnected()
        }
    }
    private fun handleAudioFocusChange(change: Int) {
        if (!playbackBehavior.requestAudioFocus) {
            logInfo("audio_focus_change_ignored mixing_enabled")
            return
        }
        val action = nativeAudioFocusAction(
            change,
            pauseOnDuck = playbackBehavior.pauseOnTransientAudioFocusLoss
        )
        when (action) {
            NativeAudioFocusAction.PAUSE_AND_CLEAR_INTENT -> {
                transientAudioFocusLossActive = false
                focusDuckActive = false
                pendingAudioFocusResumeSessionIds.clear()
                playbackRecovery.clearAll()
                applyFocusDuckAction(action)
                sessions.values.forEach { session ->
                    val player = session.playerOrNull()
                    if (player != null && (player.isPlaying || player.playWhenReady)) {
                        player.pause()
                    }
                }
                publishAllSessionStates()
                persistSessionStateNow()
                syncForegroundState()
            }
            NativeAudioFocusAction.PAUSE_AND_RESUME_ON_GAIN -> {
                transientAudioFocusLossActive = true
                if (focusDuckActive) {
                    applyFocusDuckAction(action)
                }
                focusDuckActive = false
                val sessionsToPause = sessions.values.filter { session ->
                    val player = session.playerOrNull()
                    player != null && (player.isPlaying || player.playWhenReady)
                }
                pendingAudioFocusResumeSessionIds.addAll(
                    sessionsToPause.map(NativePlaybackSession::sessionId)
                )
                sessionsToPause.forEach { session ->
                    session.playerOrNull()?.pause()
                }
                publishAllSessionStates()
                schedulePersistSessionState()
                syncForegroundState()
            }
            NativeAudioFocusAction.DUCK -> {
                transientAudioFocusLossActive = false
                focusDuckActive = true
                applyFocusDuckAction(action)
                logInfo("audio_focus_duck")
                publishAllSessionStates()
                schedulePersistSessionState()
                syncForegroundState()
            }
            NativeAudioFocusAction.RESTORE -> {
                transientAudioFocusLossActive = false
                val restoredDuckVolume = focusDuckActive
                focusDuckActive = false
                if (restoredDuckVolume) {
                    applyFocusDuckAction(action)
                    publishAllSessionStates()
                }
                val resumed = if (playbackBehavior.resumeAfterTransientAudioFocusGain) {
                    resumePendingAudioFocusSessionsIfPossible("audio_focus_gain")
                } else {
                    val pausedSessionIds = pendingAudioFocusResumeSessionIds.toList()
                    pendingAudioFocusResumeSessionIds.clear()
                    pausedSessionIds.forEach(::clearPlaybackIntent)
                    pausedSessionIds.isNotEmpty()
                }
                if (resumed || restoredDuckVolume) {
                    schedulePersistSessionState()
                    syncForegroundState()
                }
            }
            NativeAudioFocusAction.NONE -> Unit
        }
    }

    private fun applyFocusDuckAction(action: NativeAudioFocusAction) {
        sessions.values.forEach { session ->
            session.applyFocusDuckMultiplier(
                nativeFocusDuckMultiplierAfterAction(
                    session.focusDuckMultiplier,
                    action
                )
            )
        }
    }
    private var lastProgressHeartbeatElapsedRealtimeMs = 0L
    private val powerManager by lazy {
        getSystemService(Context.POWER_SERVICE) as? PowerManager
    }
    private var screenStateReceiverRegistered = false
    private val screenStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != Intent.ACTION_SCREEN_ON) return
            // The heartbeat is parked on the screen-off interval; pull it
            // forward so progress is live again immediately after unlock.
            restartProgressHeartbeat()
        }
    }

    private fun isScreenInteractive(): Boolean = powerManager?.isInteractive ?: true

    private fun restartProgressHeartbeat() {
        if (!tickerScheduled) return
        mainHandler.removeCallbacks(positionTicker)
        mainHandler.post(positionTicker)
    }

    private val positionTicker = object : Runnable {
        override fun run() {
            if (stateListeners.isEmpty() || sessions.isEmpty()) {
                tickerScheduled = false
                return
            }
            
            val nowElapsedRealtimeMs = SystemClock.elapsedRealtime()
            val isScreenOn = isScreenInteractive()

            if (shouldPublishProgressHeartbeat(
                isScreenOn = isScreenOn,
                nowElapsedRealtimeMs = nowElapsedRealtimeMs,
                lastPublishedElapsedRealtimeMs = lastProgressHeartbeatElapsedRealtimeMs,
                screenOffIntervalMs = SCREEN_OFF_PROGRESS_HEARTBEAT_INTERVAL_MS
            )) {
                publishProgressSessionStatesAsync(nowElapsedRealtimeMs)
                lastProgressHeartbeatElapsedRealtimeMs = nowElapsedRealtimeMs
            }

            mainHandler.postDelayed(
                this,
                progressHeartbeatDelayMs(
                    isScreenOn = isScreenOn,
                    screenOnIntervalMs = PROGRESS_HEARTBEAT_INTERVAL_MS,
                    screenOffIntervalMs = SCREEN_OFF_PROGRESS_HEARTBEAT_INTERVAL_MS
                )
            )
        }
    }
    override fun onCreate() {
        super.onCreate()
        playbackBehavior = NativePlaybackStateStore.loadPlaybackBehavior(this)
        ContextCompat.registerReceiver(
            this,
            audioDeviceDisconnectReceiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        audioDeviceDisconnectReceiverRegistered = true
        ContextCompat.registerReceiver(
            this,
            screenStateReceiver,
            IntentFilter(Intent.ACTION_SCREEN_ON),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        screenStateReceiverRegistered = true
        ensurePlaybackChannel()
        instance = this
        publishController(this)
        logInfo("on_create")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val startDecision = playbackStartDecision(intent)
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
        // A startForegroundService call has a short deadline. Publish the
        // minimal media notification before doing restore I/O or creating
        // players so a cold process is foreground before any heavy work.
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

    private fun playbackStartDecision(intent: Intent?): NativePlaybackStartDecision {
        if (intent == null) {
            return evaluateNativePlaybackStart(
                intentPresent = false,
                action = null,
                presentedToken = null,
                expectedToken = internalStartToken,
                bootstrapExtraPresent = false,
                bootstrapExtra = null
            )
        }
        return try {
            val extras = intent.extras
            evaluateNativePlaybackStart(
                intentPresent = true,
                action = intent.action,
                presentedToken = extras?.rawExtra(EXTRA_INTERNAL_START_TOKEN) as? String,
                expectedToken = internalStartToken,
                bootstrapExtraPresent = extras?.containsKey(EXTRA_REQUIRE_FOREGROUND_BOOTSTRAP) == true,
                bootstrapExtra = extras?.rawExtra(EXTRA_REQUIRE_FOREGROUND_BOOTSTRAP)
            )
        } catch (_: RuntimeException) {
            logSecurityEvent("playback_service_start_extras_unreadable", null)
            NativePlaybackStartDecision(
                source = NativePlaybackStartSource.REJECTED,
                rejectionReason = "unreadable_extras"
            )
        }
    }

    private fun rejectedStartResult(startId: Int): Int {
        if (sessions.isNotEmpty() || hasPlaybackToKeepAlive() || foregroundCoordinator.isStarted) {
            return START_STICKY
        }
        stopSelfResult(startId)
        return START_NOT_STICKY
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        return ensureMediaSession()
    }

    override fun onUpdateNotification(session: MediaSession, startInForeground: Boolean) {
        // We manage the foreground service and notification manually using
        // UnifiedPlaybackNotificationController and foregroundCoordinator.
        // Doing nothing here prevents Media3 from automatically posting notifications
        // and accidentally calling stopForeground(), which drops the foreground
        // status and causes Doze mode to suspend the app during screen-off.
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
        stateListeners.clear()
        videoOutputs.clear()
        restoreCoordinator.shutdown()
        if (audioDeviceDisconnectReceiverRegistered) {
            unregisterReceiver(audioDeviceDisconnectReceiver)
            audioDeviceDisconnectReceiverRegistered = false
        }
        if (screenStateReceiverRegistered) {
            unregisterReceiver(screenStateReceiver)
            screenStateReceiverRegistered = false
        }
        mainHandler.removeCallbacks(positionTicker)
        progressPublisher.shutdown()
        statePersistence.shutdown()
        playbackRecovery.dispose()
        tickerScheduled = false
        releaseMediaSession("on_destroy")
        sessions.values.forEach { it.release() }
        sessions.clear()
        foregroundCoordinator.shutdown()
        abandonAudioFocus(reason = "on_destroy")
        releaseWakeLock()
        PlaybackKeepAliveAlarmScheduler.cancel(this)
        if (instance === this) {
            instance = null
            publishController(null)
        }
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
            requestAudioFocusIfNeeded()
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
        pendingAudioFocusResumeSessionIds.remove(sessionId)
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
            ensureTicker()
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
        if (!requestAudioFocusIfNeeded()) {
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
        pendingAudioFocusResumeSessionIds.remove(sessionId)
        notificationsDismissed = false
        playbackSuspended = false
        focusSession(sessionId)
        val player = ensureFocusedPlayer(session)
        if (player.playWhenReady) {
            clearPlaybackIntent(sessionId)
            player.pause()
        } else {
            if (!requestAudioFocusIfNeeded()) {
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
        pendingAudioFocusResumeSessionIds.remove(sessionId)
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
            releaseMediaSession("remove_session_empty")
            abandonAudioFocus(reason = "remove_session_empty")
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
        transientAudioFocusLossActive = false
        focusDuckActive = false
        pendingAudioFocusResumeSessionIds.clear()
        playbackRecovery.clearAll()
        sessions.values.forEach { it.playerOrNull()?.pause() }
        evictPlayersIfNeeded()
        publishAllSessionStates()
        persistSessionStateNow()
        foregroundCoordinator.cancelGrace()
        foregroundCoordinator.stopWatchdog()
        playbackSuspended = true
        abandonAudioFocus(reason = "pause_all")
        releaseWakeLock()
        PlaybackKeepAliveAlarmScheduler.cancel(this)
        foregroundCoordinator.stop(reason = "pause_all", removeNotification = sessions.isEmpty())
        return okResult(null)
    }

    fun clearAll(): Map<String, Any?> {
        notificationsDismissed = true
        transientAudioFocusLossActive = false
        focusDuckActive = false
        pendingAudioFocusResumeSessionIds.clear()
        playbackRecovery.clearAll()
        sessions.values.forEach { it.release() }
        sessions.clear()
        focusedSessionId = null
        releaseMediaSession("clear_all")
        foregroundCoordinator.cancelGrace()
        foregroundCoordinator.stopWatchdog()
        stopStatePersistenceTicker()
        cancelScheduledPersistSessionState()
        NativePlaybackStateStore.clearSessions(this)
        NativePlaybackStateStore.clearPausedSessionIds(this)
        NativePlaybackStateStore.clearTimerCandidateSessionIds(this)
        NativePlaybackStateStore.clearTimerRuntimeState(this)
        abandonAudioFocus(reason = "clear_all")
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

    internal fun refreshForegroundNotificationForTheme() {
        if (foregroundCoordinator.isStarted) {
            foregroundCoordinator.startOrUpdate(forceRefresh = true)
        }
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
            abandonAudioFocus(reason = "mix_with_others_enabled")
            publishAllSessionStates()
            schedulePersistSessionState()
        } else if (!previouslyRequestedAudioFocus && hasActivePlayback()) {
            if (!requestAudioFocusIfNeeded()) {
                logInfo("audio_focus_policy_restore_denied")
                handleAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS)
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
                requestAudioFocusIfNeeded()
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
                requestAudioFocusIfNeeded()
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

    internal fun resumeSessionsForTimer(sessionIds: List<String>): NativeTimerResumeResult {
        if (sessionIds.isEmpty()) {
            return NativeTimerResumeResult(emptyList(), audioFocusDenied = false)
        }
        if (!requestAudioFocusIfNeeded()) {
            return NativeTimerResumeResult(emptyList(), audioFocusDenied = true)
        }
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
        return NativeTimerResumeResult(resumedSessionIds, audioFocusDenied = false)
    }

    private fun evictPlayersIfNeeded() {
        val idleSessions = sessions.values
            .filter { session ->
                val player = session.playerOrNull() ?: return@filter false
                !player.isPlaying &&
                    !player.playWhenReady &&
                    !playbackRecovery.isIntended(session.sessionId) &&
                    session.sessionId !in pendingAudioFocusResumeSessionIds &&
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
            pendingAudioFocusResumeSessionIds.remove(sessionId)
            clearPlaybackIntent(sessionId)
        }
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
        if (isPlaying) {
            playbackRecovery.onPlaying(sessionId)
            PlaybackTimerAlarmScheduler.onPlaybackStarted(this, sessionId)
        }
        publishSessionState(sessionId)
        schedulePersistSessionState()
        syncForegroundState()
    }

    private fun handlePlayerError(sessionId: String, error: PlaybackException) {
        pendingAudioFocusResumeSessionIds.remove(sessionId)
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
                session != null && requestAudioFocusIfNeeded()
            },
            markPlaybackIntended = {
                if (session != null) {
                    pendingAudioFocusResumeSessionIds.remove(session.sessionId)
                    notificationsDismissed = false
                    playbackSuspended = false
                    focusSession(session.sessionId)
                    markPlaybackIntended(session.sessionId)
                }
            },
            clearPlaybackIntent = {
                if (session != null) {
                    pendingAudioFocusResumeSessionIds.remove(session.sessionId)
                    clearPlaybackIntent(session.sessionId)
                }
            }
        )
    }

    private fun releaseMediaSession(reason: String) {
        mediaSessionHost.release(reason)
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
    private fun hasPendingAudioFocusResume(): Boolean {
        return pendingAudioFocusResumeSessionIds.any(sessions::containsKey)
    }

    private fun hasPlaybackToKeepAlive(): Boolean {
        return hasActivePlayback() ||
            hasPendingAudioFocusResume() ||
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
            clearAudioFocusInterruptionState()
        }
        syncStatePersistenceTicker()
        foregroundCoordinator.sync()
    }

    private fun handleAudioDeviceDisconnected() {
        if (!playbackBehavior.pauseOnAudioDeviceDisconnect) {
            logInfo("audio_device_disconnect_continue")
            return
        }
        transientAudioFocusLossActive = false
        focusDuckActive = false
        pendingAudioFocusResumeSessionIds.clear()
        playbackRecovery.clearAll()
        sessions.values.forEach { session ->
            val player = session.playerOrNull()
            if (player != null && (player.isPlaying || player.playWhenReady)) {
                clearPlaybackIntent(session.sessionId)
                session.applyFocusDuckMultiplier(1f)
                player.pause()
            }
        }
        publishAllSessionStates()
        persistSessionStateNow()
        syncForegroundState()
    }
    private fun stopForegroundCompat(removeNotification: Boolean) {
        val behavior = if (removeNotification) {
            STOP_FOREGROUND_REMOVE
        } else {
            STOP_FOREGROUND_DETACH
        }
        stopForeground(behavior)
    }

    private fun ensureStatePersistenceTicker() {
        statePersistence.ensureTicker()
    }

    private fun syncStatePersistenceTicker() {
        statePersistence.onPlaybackActivityChanged()
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

    private fun stopIdleServiceAfterRestore(startId: Int, reason: String) {
        mainHandler.removeCallbacks(positionTicker)
        tickerScheduled = false
        foregroundCoordinator.cancelGrace()
        foregroundCoordinator.stopWatchdog()
        stopStatePersistenceTicker()
        cancelScheduledPersistSessionState()
        playbackRecovery.clearAll()
        releaseMediaSession(reason)
        abandonAudioFocus(reason = reason)
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

    private fun onPendingCommandDeliveriesSettled() {
        restoreCoordinator.onPendingCommandDeliveriesSettled()
    }

    private fun restorePersistedSessionsForTimer(sessionIds: List<String>) {
        restoreCoordinator.restoreSessionsForTimer(sessionIds, sessions.keys)
    }

    private fun restorePersistedSessionForNotification(
        sessionId: String,
        loadedSessions: List<StoredNativePlaybackSession>
    ) {
        restoreCoordinator.restoreSessionForNotification(
            sessionId = sessionId,
            loadedSessions = loadedSessions,
            sessionExists = sessions.containsKey(sessionId)
        )
    }

    private fun requestAudioFocusIfNeeded(): Boolean {
        if (playbackBehavior.requestAudioFocus &&
            shouldDeferPlaybackRecoveryForTransientAudioFocusLoss(
                transientAudioFocusLossActive || focusDuckActive
            )
        ) {
            return false
        }
        return requestAudioFocusForPlayback(playbackBehavior.requestAudioFocus) {
            audioFocusController.requestIfNeeded()
        }
    }

    private fun resumePendingAudioFocusSessionsIfPossible(trigger: String): Boolean {
        if (!shouldResumePendingAudioFocusPause(
                audioFocusHeld = audioFocusController.isHeld,
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
        clearAudioFocusInterruptionState()
        audioFocusController.abandon(reason)
    }

    private fun clearAudioFocusInterruptionState() {
        transientAudioFocusLossActive = false
        focusDuckActive = false
        pendingAudioFocusResumeSessionIds.clear()
        sessions.values.forEach { it.applyFocusDuckMultiplier(1f) }
    }

    /**
     * Doze-proof backstop driven by [PlaybackKeepAliveAlarmScheduler].
     *
     * Deliberately does no work of its own beyond re-asserting invariants the
     * handler-based timers may have missed while the CPU was asleep.
     */
    internal fun onKeepAliveHeartbeat() {
        if (!hasPlaybackToKeepAlive() && !foregroundCoordinator.isStarted) {
            PlaybackKeepAliveAlarmScheduler.cancel(this)
            return
        }
        logInfo(
            "keep_alive_heartbeat wakeLockHeld=${playbackWakeLock.isHeld()} " +
                "playback=${hasPlaybackToKeepAlive()} " +
                "foregroundStarted=${foregroundCoordinator.isStarted}"
        )
        if (hasPlaybackToKeepAlive()) {
            // Re-acquire if an OEM power manager took the lock from us, then let
            // the ordinary sync path restore timers and notification state.
            playbackWakeLock.refresh()
            restartProgressHeartbeat()
            if (
                shouldTriggerPlaybackRecoveryOnKeepAlive(
                    hasPlaybackToKeepAlive = true,
                    transientAudioFocusLossActive = transientAudioFocusLossActive,
                    focusDuckActive = focusDuckActive
                )
            ) {
                playbackRecovery.trigger("keep_alive_heartbeat")
            }
        }
        // A grace window whose uptimeMillis timer slept through its deadline has
        // to be closed explicitly; sync() alone cannot, since scheduleGrace()
        // short-circuits while the window is still marked as scheduled.
        //
        // Closing the window does not necessarily mean the service stopped: the
        // grace runnable skips its stop when playback resumed inside the window.
        // Cancelling the alarm in that case would strip the Doze backstop from
        // live playback, and no handler timer would be left to re-arm it if the
        // wake lock was the thing that got revoked.
        if (foregroundCoordinator.expireGraceIfOverdue() && !hasPlaybackToKeepAlive()) {
            PlaybackKeepAliveAlarmScheduler.cancel(this)
            return
        }
        syncForegroundState()
        PlaybackKeepAliveAlarmScheduler.ensureScheduled(this)
    }

    /**
     * Whether our foreground notification id is currently visible. Returns null
     * when the platform cannot answer, in which case callers should assume the
     * worst and refresh.
     */
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
            "foregroundStarted=${foregroundCoordinator.isStarted} " +
            "notificationPosted=${isPlaybackNotificationPosted()} " +
            "wakeLockHeld=${playbackWakeLock.isHeld()} " +
            "audioFocusHeld=${audioFocusController.isHeld} " +
            "screenInteractive=${isScreenInteractive()} " +
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
        return channelSuccess(value)
    }

    private fun errorResult(message: String): Map<String, Any?> {
        return channelFailure(
            code = ChannelErrorCodes.PLAYER_ERROR,
            message = message
        )
    }


}
