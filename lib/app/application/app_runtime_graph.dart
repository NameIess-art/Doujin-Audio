import 'dart:async';

import '../../core/widgets/app_feedback.dart';
import '../../features/library/application/cover_artwork_cache_service.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/playback_subtitle_service.dart';
import '../../features/player/application/timer_facade.dart';
import '../../features/player/domain/playback_mode.dart';
import '../../features/settings/application/settings_repository.dart';
import 'app_persistence_coordinator.dart';
import 'audio_path_coordinator.dart';
import 'audio_runtime_coordinator.dart';
import 'audio_ui_warmup_coordinator.dart';
import 'playback_command_coordinator.dart';
import 'playback_keep_alive_coordinator.dart';

typedef AppRuntimeGraph = ({
  AudioPathCoordinator audioPaths,
  AudioRuntimeCoordinator runtime,
  AudioUiWarmupCoordinator warmup,
  AppPersistenceCoordinator persistence,
  LibraryFacade library,
  NotificationFacade notifications,
  PlaybackFacade playback,
  PlaybackCommandCoordinator playbackCommands,
  PlaybackKeepAliveCoordinator keepAlive,
  PlaybackSubtitleService subtitles,
  SettingsRepository settings,
  TimerFacade timer,
});

/// Wires existing feature owners without introducing another mutable state owner.
AppRuntimeGraph createAppRuntimeGraph({
  required LibraryFacade library,
  required PlaybackFacade playback,
  required TimerFacade timer,
  required NotificationFacade notifications,
  required SettingsRepository settings,
  bool persistenceEnabled = true,
}) {
  final audioPaths = AudioPathCoordinator(library: library, playback: playback);
  final subtitles = PlaybackSubtitleService(
    trackResolver: audioPaths.trackByPath,
    onTrackLoaded: notifications.handleSubtitleTrackLoaded,
  );
  final warmup = AudioUiWarmupCoordinator(
    library: library,
    playback: playback,
    notifications: notifications,
    subtitles: subtitles,
  );
  final keepAlive = PlaybackKeepAliveCoordinator(
    playback: playback,
    settings: settings,
    enterBackgroundWarmup: warmup.enterBackground,
    resumeForegroundWarmup: warmup.resumeForeground,
  );

  void syncLibraryState() {
    library.service.syncSlice(
      isInitialized: library.service.slice.state.isInitialized,
      detailRevision: library.detailCacheService.revision,
      treeSnapshotRevision: library.snapshotCacheService.cardSnapshotRevision,
      categorySnapshotRevision:
          library.snapshotCacheService.categorySnapshotRevision,
    );
    unawaited(library.ensureCardSnapshot());
  }

  void syncPlaybackState() {
    playback.service
      ..markSessionStateDirty()
      ..syncSlice(
        activeSessions: playback.service.activeSessions,
        playingSessionCount: playback.service.playingSessionCount,
        focusedSessionId: notifications.stateService.notificationFocusSessionId,
        multiThreadPlaybackEnabled: settings.multiThreadPlaybackEnabled,
        coverGeneration: library.coverArtworkCacheService.generation,
        isInitialized: playback.service.slice.state.isInitialized,
      );
    notifications.stateService.syncSlice(
      activeQueueLength: playback.service.activeSessions.length,
    );
  }

  void syncTimerState() {
    timer.service.syncSlice(
      isInitialized: timer.service.slice.state.isInitialized,
    );
  }

  void syncSettingsState() {
    settings.syncSlice(isInitialized: settings.slice.state.isInitialized);
    AppInteractionFeedback.hapticFeedbackEnabled =
        settings.hapticFeedbackEnabled;
  }

  void syncAllState() {
    syncLibraryState();
    syncPlaybackState();
    syncTimerState();
    syncSettingsState();
  }

  final playbackCommands = PlaybackCommandCoordinator(
    library: library,
    playback: playback,
    timer: timer,
    notifications: notifications,
    settings: settings,
    audioPaths: audioPaths,
    subtitles: subtitles,
    keepAlive: keepAlive,
    notifyPlaybackChanged: syncPlaybackState,
    syncNotificationState: notifications.syncPlaybackState,
  );

  library.configurePersistence(enabled: persistenceEnabled);
  playback.configurePersistence(enabled: persistenceEnabled);
  library.attachTrackRemovalHandler((removedPaths) {
    final removedSet = removedPaths.toSet();
    final sessionIds = playback.service.sessions.values
        .where((session) => removedSet.contains(session.currentTrackPath))
        .map((session) => session.id)
        .toList(growable: false);
    if (sessionIds.isEmpty) return;
    unawaited(
      playback.removeSessions(sessionIds, persist: false, notify: false),
    );
  });
  library.attachCoverChangeHandler(() {
    playback.service.markActiveSessionsDirty();
    notifications.syncPlaybackState();
    syncLibraryState();
    syncPlaybackState();
  });
  playback.attachSessionDefaults(
    autoPlayAddedSessions: () => settings.autoPlayAddedSessions,
    allowDuplicateWorks: () => settings.allowDuplicateWorks,
  );
  playback.attachPersistenceRuntime(
    trackByPath: library.trackByPath,
    recordPlaybackProgress: () => settings.recordPlaybackProgress,
    restoreRuntime: playbackCommands.restorePersistedRuntime,
    updatePlaybackHistory: library.updatePlaybackHistory,
    onFocusChanged: (sessionId) {
      notifications.stateService.notificationFocusSessionId = sessionId;
    },
  );
  playback.attachSessionRuntime(
    onSessionRegistered: (session) {
      notifications.stateService
        ..notificationsDismissedWhilePaused = false
        ..notificationFocusSessionId = session.id;
      keepAlive.sync();
      notifications.syncPlaybackState();
      syncPlaybackState();
    },
    onSessionsRemoved: (sessions) {
      for (final session in sessions) {
        notifications.clearSessionSubtitle(session.id);
        if (notifications.stateService.notificationFocusSessionId ==
            session.id) {
          notifications.stateService.notificationFocusSessionId = null;
        }
      }
    },
    onSessionsReordered: () {
      notifications.syncPlaybackState();
      syncPlaybackState();
      playback.scheduleSessionOrderPersistence();
    },
    onSessionStateChanged: syncPlaybackState,
    onRuntimeStateChanged: () {
      keepAlive.sync();
      notifications.syncPlaybackState();
    },
    onSessionPositionChanged: (session, position) {
      if (!notifications.isFocusedSessionId(session.id)) return;
      final changed = notifications.refreshSessionSubtitle(
        session,
        position: position,
        syncNotification: false,
      );
      if (changed) {
        notifications.scheduleFocusedRefresh(session.id, immediate: true);
      }
    },
    onSessionCompleted: playbackCommands.handleSessionCompleted,
    onSessionDurationChanged: notifications.scheduleFocusedRefresh,
    onSessionSettingsChanged: () {
      syncPlaybackState();
      notifications.syncPlaybackState();
    },
  );
  playback.attachPlaybackQueueSynchronizer(
    playbackCommands.syncPlaybackQueueSession,
  );
  playback.attachPlaybackCommands(
    prepareSession: playbackCommands.prepareAndPlay,
    pauseSession: playbackCommands.pauseSession,
    startSession: playbackCommands.startSession,
    resolveAdvance: (session, {required forward}) =>
        playbackCommands.resolveAdvance(session, forward: forward),
    hasAdjacent: (session, {required forward}) =>
        playbackCommands.hasAdjacent(session, forward: forward),
  );
  playback.attachLoopModeSynchronizer((session, mode) {
    return playback.nativeRepository.setRepeatOne(
      session.id,
      mode == SessionLoopMode.single,
      queue: playbackCommands.nativePlaybackQueueFor(
        session,
        currentPath: session.currentTrackPath,
      ),
      queueStartIndex: playbackCommands.nativePlaybackQueueStartIndexFor(
        session,
        currentPath: session.currentTrackPath,
      ),
      repeatAll: mode != SessionLoopMode.single,
      shuffle: mode.isShuffle,
    );
  });
  timer.attachRuntime(
    hasPlayingSession: () => keepAlive.hasPlayingSession,
    sessions: () => playback.service.sessions.values,
    pauseSession: playbackCommands.pauseSession,
    activateAudioSession: keepAlive.activateAudioSession,
    resumeSession: (session) => playbackCommands.startSession(
      session,
      shouldStartTriggerCountdown: false,
    ),
    onStateChanged: () {
      keepAlive.sync();
      syncTimerState();
    },
    onRuntimeRestored: () {
      notifications.syncPlaybackState();
      keepAlive.sync();
      syncTimerState();
    },
    applyFadeMultiplier: (multiplier) {
      for (final session in playback.service.sessions.values) {
        if (!session.state.playing) continue;
        unawaited(
          playback.nativeRepository.setFadeMultiplier(session.id, multiplier),
        );
      }
    },
  );
  notifications.attachRuntime(
    undismissNotifications: playback.nativeRepository.undismissNotifications,
    onNotificationsRestored: () {
      notifications.syncPlaybackState(immediateUnifiedSync: true);
      syncPlaybackState();
    },
  );
  notifications.attachActions(
    playback: playback,
    resolveSession: notifications.resolveNotificationSession,
    resolveActionSession: () => notifications.notificationActionSession,
    resumeSession: (session) => playbackCommands.startSession(
      session,
      shouldStartTriggerCountdown: false,
    ),
    multiThreadPlaybackEnabled: () => settings.multiThreadPlaybackEnabled,
    setFocusSessionId: (sessionId) {
      notifications.stateService.notificationFocusSessionId = sessionId;
    },
    notify: syncAllState,
    syncKeepAlive: keepAlive.sync,
    hasPlaybackToKeepAlive: () => keepAlive.hasPlaybackToKeepAlive,
    clearUnifiedNotifications:
        notifications.clearUnifiedNotificationsOnPlatform,
    preferredSessionId: () => playbackCommands.preferredSingleSessionId,
    notifyNotificationChanged: syncPlaybackState,
  );
  library.attachCoverArtworkCacheService(
    () => CoverArtworkCacheService(
      libraryService: library.service,
      databaseRepository: library.databaseRepository,
      audioDetailCacheService: library.detailCacheService,
      isActiveCoverKey: notifications.isActiveCoverKey,
      onActiveCoverChanged: () {
        notifications.syncPlaybackState();
        syncPlaybackState();
      },
    ),
  );
  notifications.attachSynchronization(
    playbackCommands: playbackCommands,
    subtitles: subtitles,
    trackByPath: playbackCommands.trackByPath,
    coverArtworkCacheService: library.coverArtworkCacheService,
    notificationsEnabled: () => settings.notificationsEnabled,
  );

  final persistence = AppPersistenceCoordinator(
    library: library,
    playback: playback,
    settings: settings,
    timer: timer,
    notifications: notifications,
    playbackCommands: playbackCommands,
    keepAlive: keepAlive,
    uiWarmup: warmup,
    subtitles: subtitles,
  );
  final runtime = AudioRuntimeCoordinator(
    snapshots: playback.nativeRepository.snapshots,
    progressUpdates: playback.nativeRepository.progressUpdates,
    startListening: playback.nativeRepository.startListening,
    stopListening: playback.nativeRepository.stopListening,
    onSnapshot: playbackCommands.handleNativeSnapshot,
    onProgress: playback.applyNativeProgress,
    onStart: persistence.loadPersistedState,
    onEnterBackground: keepAlive.enterBackground,
    onResumeForeground: () async {
      keepAlive.resumeForeground();
      await playbackCommands.reconcileNativeRuntime();
      notifications.resyncAfterForegroundResume();
      await timer.syncRuntimeFromNative();
      timer.retryOverdueAutoResume();
    },
    onDispose: () async {
      persistence.dispose();
      timer.service.countdownTimer?.cancel();
      timer.service.autoResumeTimer?.cancel();
      playback.cancelScheduledPersistence();
      library.service.scanProgressNotifyTimer?.cancel();
      await warmup.shutdown();
      await keepAlive.shutdown();
      for (final session in playback.service.sessions.values) {
        session.dispose();
      }
      playback.service.sessions.clear();
      await library.dispose();
      await playback.dispose();
      await timer.dispose();
      await notifications.dispose();
      await settings.dispose();
    },
  );
  syncAllState();
  return (
    audioPaths: audioPaths,
    runtime: runtime,
    warmup: warmup,
    persistence: persistence,
    library: library,
    notifications: notifications,
    playback: playback,
    playbackCommands: playbackCommands,
    keepAlive: keepAlive,
    subtitles: subtitles,
    settings: settings,
    timer: timer,
  );
}
