import '../../features/library/application/library_facade.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/domain/playback_mode.dart';
import '../../features/settings/application/settings_repository.dart';
import 'playback_command_coordinator.dart';
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
    playback.attachSessionDefaults(
      autoPlayAddedSessions: () => settings.autoPlayAddedSessions,
      allowDuplicateWorks: () => settings.allowDuplicateWorks,
    );
    playback.attachPersistenceRuntime(
      trackByPath: library.trackByPath,
      recordPlaybackProgress: () => settings.recordPlaybackProgress,
      restoreRuntime: playbackCommands.restorePersistedRuntime,
      updatePlaybackHistory: library.updatePlaybackHistory,
      onFocusChanged: notifications.setFocusedSession,
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
    playback.attachLoopModeSynchronizer((session, mode) async {
      final nativeQueue = playbackCommands.nativePlaybackQueueFor(
        session,
        currentPath: session.currentTrackPath,
      );
      final result = await playback.nativeRepository.setRepeatOne(
        session.id,
        mode == SessionLoopMode.single,
        queue: nativeQueue,
        queueStartIndex: playbackCommands.nativePlaybackQueueStartIndexFor(
          session,
          currentPath: session.currentTrackPath,
        ),
        repeatAll: mode != SessionLoopMode.single && !mode.isOneShot,
        shuffle: mode.isShuffle,
      );
      if (result.isOk) {
        playback.updateNativeSessionRetainedContentUris(
          session.id,
          <Object?>[
            session.currentTrackPath,
            for (final item in nativeQueue) ...<Object?>[
              item['path'],
              item['uri'],
              item['artUri'],
            ],
          ].whereType<String>(),
        );
      }
    });
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
