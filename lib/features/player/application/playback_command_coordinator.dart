import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart'
    show compute, defaultTargetPlatform, TargetPlatform;
import 'package:path/path.dart' as path;

import '../../../core/immutable_collections.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/cache/app_cache_service.dart';
import '../../asmr/domain/asmr_media_sources.dart';
import '../domain/audio_effects.dart';
import '../domain/playback_mode.dart';
import '../domain/playback_library_catalog.dart';
import '../domain/playback_track_cache.dart';
import 'native_playback_bridge.dart';
import 'native_playback_repository.dart';
import 'notification_facade.dart';
import 'playback_command_port.dart';
import 'playback_command_runner.dart';
import 'playback_facade.dart';
import 'playback_queue_resolver.dart';
import 'playback_session.dart';
import 'playback_subtitle_service.dart' show PlaybackSubtitleService;
import 'playback_track_resolver.dart';
import 'timer_facade.dart';

part 'playback_command_scope.dart';
part 'playback_command_transport.dart';
part 'playback_command_preparation.dart';
part 'playback_command_queue_sync.dart';
part 'playback_command_native_mapper.dart';
part 'playback_command_restore.dart';

typedef PlaybackNotificationSynchronizer =
    void Function({bool immediateUnifiedSync});

/// Owns playback command serialization and native preparation coordination.
///
/// Mutable playback state remains owned by [PlaybackFacade].
final class PlaybackCommandCoordinator
    implements NotificationPlaybackCommands, PlaybackCommandPort {
  PlaybackCommandCoordinator({
    required PlaybackLibraryCatalog library,
    required PlaybackFacade playback,
    required TimerFacade timer,
    required NotificationFacade notifications,
    required bool Function() asmrPlaybackCacheEnabled,
    required PlaybackTrackResolver audioPaths,
    required PlaybackSubtitleService subtitles,
    required Future<bool> Function() activateAudioSession,
    required PlaybackTrackCache asmrPlaybackCacheService,
    required void Function() notifyPlaybackChanged,
    required PlaybackNotificationSynchronizer syncNotificationState,
    Random? random,
  }) : _libraryFacade = library,
       _playbackFacade = playback,
       _timerFacade = timer,
       _notificationFacade = notifications,
       _asmrPlaybackCacheEnabled = asmrPlaybackCacheEnabled,
       _audioPathCoordinator = audioPaths,
       _subtitleService = subtitles,
       _activateAudioSession = activateAudioSession,
       _asmrPlaybackCacheService = asmrPlaybackCacheService,
       _notifyPlaybackChangedCallback = notifyPlaybackChanged,
       _syncNotificationStateCallback = syncNotificationState,
       _random = random ?? Random();

  final PlaybackLibraryCatalog _libraryFacade;
  final PlaybackFacade _playbackFacade;
  final TimerFacade _timerFacade;
  final NotificationFacade _notificationFacade;
  final bool Function() _asmrPlaybackCacheEnabled;
  final PlaybackTrackResolver _audioPathCoordinator;
  final PlaybackSubtitleService _subtitleService;
  final Future<bool> Function() _activateAudioSession;
  final PlaybackTrackCache _asmrPlaybackCacheService;
  final void Function() _notifyPlaybackChangedCallback;
  final PlaybackNotificationSynchronizer _syncNotificationStateCallback;
  final Random _random;

  Map<String, PlaybackSession> get _sessions => _playbackFacade.sessions;
  NativePlaybackRepository get _nativePlaybackRepository =>
      _playbackFacade.nativeRepository;
  PlaybackCommandRunner get _playbackCommandRunner =>
      _playbackFacade.commandRunner;
  bool _isRegisteredSession(PlaybackSession session) =>
      _playbackFacade.isRegisteredSession(session);
  List<PlaybackSession> get activeSessions => _playbackFacade.activeSessions;

  Future<bool> _activateAudioSessionForPlayback() => _activateAudioSession();
  void _notifyPlaybackChanged([String? sessionId]) {
    final session = sessionId == null ? null : _sessions[sessionId];
    if (session != null) _syncActivePlaybackCacheLease(session);
    _playbackFacade.publishSessionState(sessionId);
    _notifyPlaybackChangedCallback();
  }

  void _syncNotificationState({bool immediateUnifiedSync = false}) =>
      _syncNotificationStateCallback(
        immediateUnifiedSync: immediateUnifiedSync,
      );

  final Map<String, CachePathLease> _activePlaybackCacheLeases = {};
  final Map<String, String> _activePlaybackCachePaths = {};

  void releaseSessionResources(String sessionId) {
    _activePlaybackCacheLeases.remove(sessionId)?.release();
    _activePlaybackCachePaths.remove(sessionId);
  }

  Future<void> dispose() async {
    for (final lease in _activePlaybackCacheLeases.values) {
      lease.release();
    }
    _activePlaybackCacheLeases.clear();
    _activePlaybackCachePaths.clear();
    await _asmrPlaybackCacheService.dispose();
  }

  void _syncActivePlaybackCacheLease(PlaybackSession session) {
    final candidate = session.currentTrackPath;
    final path =
        session.playbackRequested &&
            candidate.isNotEmpty &&
            !candidate.contains('://')
        ? candidate
        : null;
    if (_activePlaybackCachePaths[session.id] == path) return;
    _activePlaybackCacheLeases.remove(session.id)?.release();
    _activePlaybackCachePaths.remove(session.id);
    if (path != null) {
      _activePlaybackCachePaths[session.id] = path;
      _activePlaybackCacheLeases[session.id] = AppCacheService.protectPaths({
        path,
      });
    }
  }

  String? resolvedPlaybackCoverPathForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => _libraryFacade.resolvedPlaybackCoverPathForTrack(
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
    return _notificationFacade.updateSessionSubtitle(
      sessionId: session.id,
      trackPath: trackPath,
      text: nextText,
      syncNotification: syncNotification,
    );
  }

  @override
  Future<bool> prepareSession(
    PlaybackSession session, {
    required String nextPath,
    bool autoPlay = true,
    bool forceStartAtZero = false,
    bool showLoading = true,
    int? targetQueueIndex,
  }) => prepareAndPlay(
    session,
    nextPath: nextPath,
    autoPlay: autoPlay,
    forceStartAtZero: forceStartAtZero,
    showLoading: showLoading,
    targetQueueIndex: targetQueueIndex,
  );

  @override
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

  @override
  Future<bool> startSession(
    PlaybackSession session, {
    required bool shouldStartTriggerCountdown,
  }) => _startSessionPlayback(
    session,
    shouldStartTriggerCountdown: shouldStartTriggerCountdown,
  );

  @override
  Future<bool> pauseSession(PlaybackSession session) =>
      _pauseSessionPlayback(session);

  String? get preferredSingleSessionId => _preferredSingleSessionId;

  Future<void> handleSessionCompleted(String sessionId) =>
      _handleSessionCompleted(sessionId);

  void handleSessionPositionChanged(
    PlaybackSession session,
    Duration position,
  ) {
    if (_timerFacade.stopAfterCurrentTrack &&
        session.duration != null &&
        session.duration! > Duration.zero) {
      final remaining = session.duration! - position;
      if (remaining <= const Duration(seconds: 15) &&
          remaining > Duration.zero) {
        _timerFacade.applyFadeMultiplier(
          (remaining.inMilliseconds / 15000.0).clamp(0.0, 1.0),
        );
      }
    }
  }

  @override
  PlaybackAdvanceResult? resolveAdvance(
    PlaybackSession session, {
    required bool forward,
    bool manualAdvance = false,
  }) => _nextPathFor(session, forward: forward, manualAdvance: manualAdvance);

  @override
  bool hasAdjacent(PlaybackSession session, {required bool forward}) =>
      _hasAdjacentPathFor(session, forward: forward);

  Future<void> syncPlaybackQueueSession(
    PlaybackSession session, {
    bool selectFirst = false,
  }) => _syncPlaybackQueueSession(session, selectFirst: selectFirst);

  void handleNativeSnapshot(NativePlaybackSnapshot snapshot) =>
      _handleNativePlaybackSnapshot(snapshot);

  Future<List<Map<String, Object?>>> nativePlaybackQueueFor(
    PlaybackSession session, {
    required String currentPath,
  }) => _nativePlaybackQueueFor(session, currentPath: currentPath);

  int? nativePlaybackQueueStartIndexFor(
    PlaybackSession session, {
    required String currentPath,
  }) => _nativePlaybackQueueStartIndexFor(session, currentPath: currentPath);

  MusicTrack? sessionTrackForPath(PlaybackSession session, String trackPath) =>
      _sessionTrackForPath(session, trackPath);

  List<Uri>? candidatePlaybackUrisForTrack(MusicTrack? track) =>
      _candidatePlaybackUrisForTrack(track);

  Future<void> synchronizePausedRecovery(PlaybackSession session) async {
    bool isCold() =>
        _isRegisteredSession(session) &&
        session.loadedPath == null &&
        !session.playbackRequested &&
        !session.effectivePlaying &&
        !session.isLoading;
    if (defaultTargetPlatform != TargetPlatform.android || !isCold()) return;
    final currentPath = _playbackFacade.resolveRetargetedPath(
      session.currentTrackPath,
    );
    final queueVersion = session.queueVersion;
    final generation = session.loadGeneration;
    final emptyQueue =
        session.isPlaybackQueue &&
        session.playbackQueue!.expandedTracks.isEmpty &&
        !session.hasDetachedQueueTrack;
    final queue = currentPath.isEmpty || emptyQueue
        ? const <Map<String, Object?>>[]
        : await nativePlaybackQueueFor(session, currentPath: currentPath);
    if (!isCold() ||
        session.queueVersion != queueVersion ||
        session.loadGeneration != generation ||
        _playbackFacade.resolveRetargetedPath(session.currentTrackPath) !=
            currentPath) {
      return;
    }
    if (queue.isEmpty) {
      final removed = await _nativePlaybackRepository.removeSession(session.id);
      if (removed.isFailure) throw StateError(removed.errorOrNull!);
      return;
    }
    final startIndex = nativePlaybackQueueStartIndexFor(
      session,
      currentPath: currentPath,
    );
    final current = queue[(startIndex ?? 0).clamp(0, queue.length - 1)];
    final artUri = current['artUri'] as String?;
    final result = await _nativePlaybackRepository.prepareSession(
      sessionId: session.id,
      isTemporary: session.isTemporary,
      uri: Uri.parse(current['uri'] as String),
      title: current['title'] as String,
      path: currentPath,
      subtitle: current['subtitle'] as String?,
      artUri: artUri == null ? null : Uri.parse(artUri),
      startPosition: session.state.processingState == ProcessingState.completed
          ? Duration.zero
          : session.lastKnownPosition,
      volume: session.volume,
      speed: session.speed,
      audioEffects: NativeAudioEffects(
        state: session.audioEffects,
        channelSwapEnabled: session.channelSwapEnabled,
      ),
      repeatOne: session.loopMode == SessionLoopMode.single,
      queue: queue,
      queueStartIndex: startIndex,
      repeatAll:
          !_hasDetachedPlaybackQueueCurrent(session) &&
          session.loopMode != SessionLoopMode.single &&
          !session.loopMode.isOneShot,
      shuffle: session.loopMode.isShuffle,
      candidateUris: candidatePlaybackUrisForTrack(
        sessionTrackForPath(session, currentPath),
      ),
      deferPlayerCreation: true,
    );
    if (result.isFailure) throw StateError(result.errorOrNull!);
  }

  Future<void> restorePersistedRuntime(
    List<PlaybackSession> restoredSessions, {
    required String? focusedSessionId,
  }) => _restorePersistedRuntime(
    restoredSessions,
    focusedSessionId: focusedSessionId,
  );

  Future<void> reconcileNativeRuntime() => _reconcileNativeRuntime();
}
