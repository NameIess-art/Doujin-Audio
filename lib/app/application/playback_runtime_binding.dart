import 'package:flutter/foundation.dart';

import '../../features/library/application/library_facade.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/settings/application/settings_repository.dart';
import '../../features/player/application/playback_command_coordinator.dart';
import 'playback_keep_alive_coordinator.dart';
import 'runtime_binding.dart';

final class PlaybackRuntimeBinding implements RuntimeBinding {
  PlaybackRuntimeBinding._(this._playback);

  static final Expando<PlaybackRuntimeBinding> _attached =
      Expando<PlaybackRuntimeBinding>();

  static PlaybackRuntimeBinding attach({
    required LibraryFacade library,
    required PlaybackFacade playback,
    required NotificationFacade notifications,
    required SettingsRepository settings,
    required PlaybackCommandCoordinator playbackCommands,
    required PlaybackKeepAliveCoordinator keepAlive,
    required void Function() syncPlaybackState,
  }) {
    final existing = _attached[playback];
    if (existing != null && !existing._disposed) return existing;
    playback.attachPersistenceRuntime(
      trackByPath: library.trackByPath,
      recordPlaybackProgress: () => settings.recordPlaybackProgress,
      restoreRuntime: playbackCommands.restorePersistedRuntime,
      updatePlaybackHistory: library.updatePlaybackHistory,
      onFocusChanged: notifications.setFocusedSession,
      synchronizePausedRecovery: defaultTargetPlatform == TargetPlatform.android
          ? playbackCommands.synchronizePausedRecovery
          : null,
    );
    playback.attachSessionRuntime(
      onSessionRegistered: (session) {
        notifications.registerSessionFocus(session.id);
        keepAlive.sync();
        notifications.syncPlaybackState();
        syncPlaybackState();
      },
      onSessionsRemoved: (sessions) {
        for (final session in sessions) {
          playbackCommands.releaseSessionResources(session.id);
          notifications.clearSessionSubtitle(session.id);
          notifications.clearFocusIfMatches(session.id);
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
        playbackCommands.handleSessionPositionChanged(session, position);
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
    playback.attachCommandPort(playbackCommands);
    playback.attachLoopModeSynchronizer(playbackCommands.synchronizeLoopMode);
    final binding = PlaybackRuntimeBinding._(playback);
    _attached[playback] = binding;
    return binding;
  }

  final PlaybackFacade _playback;
  bool _disposed = false;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _playback.detachRuntime();
    _attached[_playback] = null;
  }
}
