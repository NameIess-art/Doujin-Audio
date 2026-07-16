import 'dart:async';
import 'dart:math';

import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path;

import '../../core/logging/app_log_service.dart';
import '../../core/media/music_track.dart';
import '../../core/media/path_matcher.dart';
import '../../core/platform/app_platform.dart';
import '../../core/persistence/audio_database_repository.dart';
import '../../features/asmr/application/asmr_api_service.dart';
import '../../features/asmr/application/asmr_playback_cache_service.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/player/application/native_playback_bridge.dart';
import '../../features/player/application/native_playback_repository.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_command_runner.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/playback_queue_resolver.dart';
import '../../features/player/application/playback_session.dart';
import '../../features/player/application/playback_subtitle_service.dart';
import '../../features/player/application/timer_facade.dart';
import '../../features/player/application/audio_state_services.dart';
import '../../features/player/domain/audio_effects.dart';
import '../../features/player/domain/playback_mode.dart';
import '../../features/settings/application/settings_repository.dart';
import 'audio_path_coordinator.dart';
import 'playback_keep_alive_coordinator.dart';

part 'playback_command_scope.dart';
part 'playback_command_transport.dart';
part 'playback_command_preparation.dart';
part 'playback_command_queue_sync.dart';
part 'playback_command_native_mapper.dart';

typedef PlaybackNotificationSynchronizer =
    void Function({bool immediateUnifiedSync});

/// Owns playback command serialization and native preparation coordination.
///
/// Mutable playback state remains owned by [PlaybackFacade].
final class PlaybackCommandCoordinator {
  PlaybackCommandCoordinator({
    required LibraryFacade library,
    required PlaybackFacade playback,
    required TimerFacade timer,
    required NotificationFacade notifications,
    required SettingsRepository settings,
    required AudioPathCoordinator audioPaths,
    required PlaybackSubtitleService subtitles,
    required PlaybackKeepAliveCoordinator keepAlive,
    required void Function() notifyPlaybackChanged,
    required PlaybackNotificationSynchronizer syncNotificationState,
    Random? random,
  }) : _libraryFacade = library,
       _playbackFacade = playback,
       _timerFacade = timer,
       _notificationFacade = notifications,
       _settingsRepository = settings,
       _audioPathCoordinator = audioPaths,
       _subtitleService = subtitles,
       _keepAliveCoordinator = keepAlive,
       _notifyPlaybackChangedCallback = notifyPlaybackChanged,
       _syncNotificationStateCallback = syncNotificationState,
       _random = random ?? Random();

  final LibraryFacade _libraryFacade;
  final PlaybackFacade _playbackFacade;
  final TimerFacade _timerFacade;
  final NotificationFacade _notificationFacade;
  final SettingsRepository _settingsRepository;
  final AudioPathCoordinator _audioPathCoordinator;
  final PlaybackSubtitleService _subtitleService;
  final PlaybackKeepAliveCoordinator _keepAliveCoordinator;
  final void Function() _notifyPlaybackChangedCallback;
  final PlaybackNotificationSynchronizer _syncNotificationStateCallback;
  final Random _random;

  Map<String, PlaybackSession> get _sessions =>
      _playbackFacade.service.sessions;
  PlaybackSessionService get _playbackService => _playbackFacade.service;
  AudioDatabaseRepository get _audioDatabaseRepository =>
      _libraryFacade.databaseRepository;
  NativePlaybackRepository get _nativePlaybackRepository =>
      _playbackFacade.nativeRepository;
  PlaybackCommandRunner get _playbackCommandRunner =>
      _playbackFacade.commandRunner;
  bool get _multiThreadPlaybackEnabled =>
      _settingsRepository.multiThreadPlaybackEnabled;
  List<String> get _sortedLibraryTrackPaths =>
      _libraryFacade.service.sortedLibraryTrackPaths;
  Map<String, List<MusicTrack>> get _tracksByGroup =>
      _libraryFacade.service.tracksByGroup;
  List<MusicTrack> get _library => _libraryFacade.service.library;
  Map<String, MusicTrack> get _libraryByPath =>
      _libraryFacade.service.libraryByPath;
  AsmrPlaybackCacheService get _asmrPlaybackCacheService =>
      _playbackFacade.playbackCacheService;

  List<PlaybackSession> get activeSessions =>
      _playbackFacade.service.activeSessions;

  void _syncKeepCpuAwake() => _keepAliveCoordinator.sync();
  Future<bool> _activateAudioSessionForPlayback() =>
      _keepAliveCoordinator.activateAudioSession();
  void _notifyPlaybackChanged() => _notifyPlaybackChangedCallback();
  void _syncNotificationState({bool immediateUnifiedSync = false}) =>
      _syncNotificationStateCallback(
        immediateUnifiedSync: immediateUnifiedSync,
      );

  MusicTrack? trackByPath(String trackPath) {
    final resolvedPath = _playbackFacade.resolveRetargetedPath(trackPath);
    final libraryTrack = _libraryFacade.trackByPath(resolvedPath);
    if (libraryTrack != null) return libraryTrack;
    for (final session in _sessions.values) {
      for (final track in session.customQueueTracks ?? const <MusicTrack>[]) {
        if (PathMatcher.equalsNormalized(track.path, trackPath) ||
            PathMatcher.equalsNormalized(track.path, resolvedPath) ||
            PathMatcher.equalsNormalized(
              _playbackFacade.resolveRetargetedPath(track.path),
              resolvedPath,
            )) {
          return track;
        }
      }
    }
    return null;
  }

  String? resolvedPlaybackCoverPathForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => _libraryFacade.coverArtworkCacheService.resolvedForPlaybackTrack(
    track,
    trackPath: trackPath,
  );

  Future<String?> _resolveNotificationCoverPathForTrack(MusicTrack? track) =>
      _libraryFacade.playbackCoverPathFutureForTrack(track);

  void _ensureSubtitleTrackLoaded(String trackPath) {
    if (_subtitleService.hasResult(trackPath) ||
        _subtitleService.isLoading(trackPath)) {
      return;
    }
    unawaited(_subtitleService.load(trackPath));
  }

  bool _refreshNotificationSubtitleForSession(
    PlaybackSession session, {
    Duration? position,
    bool syncNotification = true,
  }) {
    final trackPath = session.currentTrackPath;
    _ensureSubtitleTrackLoaded(trackPath);
    final nextText = _subtitleService.textAt(
      trackPath,
      position ?? session.position,
      subtitleTrack: _subtitleService.trackSync(trackPath),
    );
    final state = _notificationFacade.stateService;
    final previousText = state.notificationSubtitleTexts[session.id];
    final previousTrackPath = state.notificationSubtitleTrackPaths[session.id];
    if (previousTrackPath == trackPath && previousText == nextText) {
      return false;
    }
    state.notificationSubtitleTexts[session.id] = nextText;
    state.notificationSubtitleTrackPaths[session.id] = trackPath;
    if (syncNotification && state.notificationFocusSessionId == session.id) {
      _syncNotificationState();
    }
    return true;
  }

  Future<bool> prepareAndPlay(
    PlaybackSession session, {
    required String nextPath,
    bool autoPlay = true,
    bool forceStartAtZero = false,
    bool showLoading = true,
    int? targetQueueIndex,
  }) => _prepareAndPlay(
    session,
    nextPath: nextPath,
    autoPlay: autoPlay,
    forceStartAtZero: forceStartAtZero,
    showLoading: showLoading,
    targetQueueIndex: targetQueueIndex,
  );

  Future<bool> startSession(
    PlaybackSession session, {
    required bool shouldStartTriggerCountdown,
  }) => _startSessionPlayback(
    session,
    shouldStartTriggerCountdown: shouldStartTriggerCountdown,
  );

  Future<bool> pauseSession(PlaybackSession session) =>
      _pauseSessionPlayback(session);

  Future<void> enforceSingleThreadPlayback({String? preferredSessionId}) =>
      _enforceSingleThreadPlayback(preferredSessionId: preferredSessionId);

  String? get preferredSingleSessionId => _preferredSingleSessionId;

  Future<void> handleSessionCompleted(String sessionId) =>
      _handleSessionCompleted(sessionId);

  PlaybackAdvanceResult? resolveAdvance(
    PlaybackSession session, {
    required bool forward,
  }) => _nextPathFor(session, forward: forward);

  bool hasAdjacent(PlaybackSession session, {required bool forward}) =>
      _hasAdjacentPathFor(session, forward: forward);

  Future<void> syncPlaybackQueueSession(
    PlaybackSession session, {
    bool selectFirst = false,
  }) => _syncPlaybackQueueSession(session, selectFirst: selectFirst);

  void handleNativeSnapshot(NativePlaybackSnapshot snapshot) =>
      _handleNativePlaybackSnapshot(snapshot);

  List<Map<String, Object?>> nativePlaybackQueueFor(
    PlaybackSession session, {
    required String currentPath,
  }) => _nativePlaybackQueueFor(session, currentPath: currentPath);

  int? nativePlaybackQueueStartIndexFor(
    PlaybackSession session, {
    required String currentPath,
  }) => _nativePlaybackQueueStartIndexFor(session, currentPath: currentPath);

  MusicTrack? sessionTrackForPath(
    PlaybackSession session,
    String trackPath,
  ) => _sessionTrackForPath(session, trackPath);

  List<Uri>? candidatePlaybackUrisForTrack(MusicTrack? track) =>
      _candidatePlaybackUrisForTrack(track);
}
