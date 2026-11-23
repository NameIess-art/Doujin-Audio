import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, mapEquals;
import 'package:path/path.dart' as path;

import '../../../core/errors/native_result.dart';
import '../../../core/immutable_collections.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/path_display.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/persistence/app_preferences.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../domain/audio_effects.dart';
import '../domain/playback_mode.dart';
import '../domain/playback_queue.dart';
import '../domain/playback_persistence_repository.dart';
import 'playback_session.dart';
import 'playback_session_snapshot.dart';
import 'audio_state_services.dart';
import 'native_playback_repository.dart';
import 'native_playback_bridge.dart';
import 'playback_command_port.dart';
import 'playback_command_runner.dart';
import 'playback_seek_dispatcher.dart';

part 'playback_native_state_coordinator.dart';
part 'playback_session_persistence_coordinator.dart';
part 'playback_effects_coordinator.dart';
part 'playback_queue_path_coordinator.dart';

typedef PlaybackQueueSessionSynchronizer =
    Future<void> Function(PlaybackSession session, {bool selectFirst});
typedef PlaybackLoopModeSynchronizer =
    Future<void> Function(PlaybackSession session, SessionLoopMode mode);
typedef RestoredPlaybackRuntime =
    Future<void> Function(
      List<PlaybackSession> sessions, {
      required String? focusedSessionId,
    });
typedef PlaybackHistoryUpdater =
    MusicTrack? Function({
      required String trackPath,
      required Duration position,
      required DateTime now,
      required bool updatePlayedAt,
    });

/// Owns playback sessions and the platform playback runtime.
final class PlaybackFacade {
  PlaybackFacade({
    required this.databaseRepository,
    required this.nativeRepository,
    required this.commandRunner,
    required PlaybackSessionService service,
  }) : _service = service,
       _seekDispatcher = PlaybackSeekDispatcher(
         nativeRepository: nativeRepository,
         service: service,
       );

  factory PlaybackFacade.create({
    required PlaybackPersistenceRepository databaseRepository,
    NativePlaybackRepository? nativeRepository,
    PlaybackCommandRunner commandRunner = const PlaybackCommandRunner(),
    PlaybackSessionService? service,
  }) {
    return PlaybackFacade(
      databaseRepository: databaseRepository,
      nativeRepository: nativeRepository ?? NativePlaybackRepository(),
      commandRunner: commandRunner,
      service: service ?? PlaybackSessionService(),
    );
  }

  final PlaybackPersistenceRepository databaseRepository;
  final NativePlaybackRepository nativeRepository;
  final PlaybackCommandRunner commandRunner;
  final PlaybackSessionService _service;
  final StreamController<String> _sessionActivations =
      StreamController<String>.broadcast(sync: true);
  final StreamController<int> _persistedUriReferenceRevisionController =
      StreamController<int>.broadcast(sync: true);
  final Map<String, Set<String>> _nativeRetainedContentUrisBySession =
      <String, Set<String>>{};
  final PlaybackSeekDispatcher _seekDispatcher;
  int _nativePersistedUriReferenceRevision = 0;
  bool _nativeRetainedContentUriInventoryReady = false;
  MusicTrack? Function(String trackPath)? _persistedTrackResolver;
  bool Function()? _recordPlaybackProgress;
  RestoredPlaybackRuntime? _restoreRuntime;
  PlaybackHistoryUpdater? _updatePlaybackHistory;
  void Function(String? sessionId)? _onPersistenceFocusChanged;
  Future<void> Function(PlaybackSession session)? _synchronizePausedRecovery;
  void Function(PlaybackSession session)? _onSessionRegistered;
  void Function(List<PlaybackSession> sessions)? _onSessionsRemoved;
  void Function()? _onSessionsReordered;
  void Function()? _onSessionStateChanged;
  void Function()? _onRuntimeStateChanged;
  void Function(PlaybackSession session, Duration position)?
  _onSessionPositionChanged;
  FutureOr<void> Function(String sessionId)? _onSessionCompleted;
  void Function(String sessionId)? _onSessionDurationChanged;
  void Function()? _onSessionSettingsChanged;
  PlaybackQueueSessionSynchronizer? _synchronizePlaybackQueueSession;
  PlaybackCommandPort? _commandPort;
  Future<void> Function()? _initializeForUserLaunch;
  bool _disposed = false;
  PlaybackLoopModeSynchronizer? _synchronizeLoopMode;
  bool _sessionObserversAttached = false;
  final Map<String, String> _retargetedPathAliases = <String, String>{};
  final Map<String, ({String source, String target})> _retargetedForwardIndex =
      <String, ({String source, String target})>{};
  final Map<String, ({String source, String target})> _retargetedReverseIndex =
      <String, ({String source, String target})>{};
  bool _hasNonRemoteRetargetSources = false;
  int _retargetRevision = 0;
  int get retargetRevision => _retargetRevision;
  bool get hasRetargetedPaths => _retargetedPathAliases.isNotEmpty;
  final Random _random = Random();
  int _transportCommandSequence = 0;
  int _sessionSeed = 0;
  int _directPlayRevision = 0;
  final Set<String> _removingMissingTemporarySessionIds = {};
  PlaybackSession? _directPlaybackSession;
  static const _resumeBatchKey = 'playlist_resume_batch_v1';
  Map<String, String> _resumeBatch = {};
  Map<String, String> _resumeRetryTargets = {};
  Future<bool>? _resumeInFlight;
  Future<({bool succeeded, Iterable<String> confirmedSessionIds})>?
  _pauseAllInFlight;
  int _resumeBatchRevision = 0;
  int _pauseSequence = 0;
  int _recordedPauseSequence = 0;
  final _resumeBatchChanges = StreamController<int>.broadcast();

  Stream<int> get resumeBatchChanges => _resumeBatchChanges.stream;

  bool get hasActivePlayback => _service.sessions.values.any(_isPlaybackActive);

  bool _isPlaybackActive(PlaybackSession session) =>
      session.playbackRequested || session.state.playing;

  bool get canResumeLastPlayback =>
      _resumeInFlight == null &&
      _pauseAllInFlight == null &&
      !hasActivePlayback &&
      _resumeBatch.entries.any(_isResumeTarget);

  void _notifyResumeBatchChanged() {
    if (!_disposed) _resumeBatchChanges.add(++_resumeBatchRevision);
  }

  Future<void> saveResumeBatchForExit() async {
    final targets = _captureActivePlayback();
    if (targets.isNotEmpty) {
      _recordedPauseSequence = ++_pauseSequence;
      await _setResumeBatch({
        ..._resumeRetryTargets,
        if (_resumeInFlight != null) ..._resumeBatch,
        ...targets,
      });
    }
  }

  Future<void> handleAudioDeviceDisconnected() =>
      _reconcileAudioDeviceDisconnection();

  Future<bool> resumeLastPlayback() {
    final pending = _resumeInFlight;
    if (pending != null) return pending;
    final commands = _commandPort;
    if (commands == null || !canResumeLastPlayback) return Future.value(false);
    final resume = _resumePlaybackBatch(commands).whenComplete(() {
      _resumeInFlight = null;
      _notifyResumeBatchChanged();
    });
    _resumeInFlight = resume;
    _notifyResumeBatchChanged();
    return resume;
  }

  Future<bool> pauseSessionForResume(PlaybackSession session) async {
    final wasActive = _isPlaybackActive(session);
    final sequence = ++_pauseSequence;
    final paused = await _commandPort?.pauseSession(session) ?? false;
    if (paused && wasActive && isRegisteredSession(session)) {
      _rememberPausedBatch({
        session.id: session.currentTrackPath,
      }, sequence: sequence);
    }
    return paused;
  }

  bool _persistenceEnabled = true;
  bool _backgroundMode = false;
  Timer? _savePlaybackStateTimer;
  final Set<String> _pendingPlaybackStateSessionIds = <String>{};
  Future<void>? _sessionPersistenceTail;
  bool _pendingSessionOrder = false;
  final Map<String, PersistedPlaybackSession> _persistedSessions = {};
  final Map<String, int> _persistedQueueVersions = {};
  final Map<PlaybackSession, Future<bool>> _deferredQueueLoads = {};
  final Set<String> _pendingSessionDefinitionIds = {};
  final Set<String> _pendingDeletedSessionIds = {};
  final Map<String, MusicTrack> _pendingPlaybackHistoryTracks = {};

  static const int foregroundPositionBucketSeconds = 5;

  static const int backgroundPositionBucketSeconds = 30;

  static const double maxSessionVolume = 3.0;
  static const List<double> playbackSpeedOptions = <double>[
    0.25,
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2.0,
    2.5,
    3.0,
  ];

  Stream<String> get sessionActivations => _sessionActivations.stream;
  PlaybackStateSliceData get state => _service.state;
  PlaybackAggregateState get aggregateState => _service.aggregate.state;
  Stream<PlaybackAggregateState> get states => _service.aggregate.stream;
  PlaybackCatalogState get catalogState => _service.catalog.state;
  Stream<PlaybackCatalogState> get catalogStates => _service.catalog.stream;
  Stream<PlaybackSessionSnapshot?> sessionStates(String sessionId) =>
      _service.sessionStates(sessionId);

  void publishSessionState([String? sessionId]) {
    _pruneResumeBatch();
    if (sessionId != null) {
      final session = _service.sessionById(sessionId);
      if (session != null) _service.publishSession(session);
      return;
    }
    _service.publishSessions(_service.activeSessions);
  }

  void _notifySessionStateChanged([PlaybackSession? session]) {
    publishSessionState(session?.id);
    _onSessionStateChanged?.call();
  }

  void _notifySessionSettingsChanged(PlaybackSession session) {
    publishSessionState(session.id);
    _onSessionSettingsChanged?.call();
  }

  Map<String, PlaybackSession> get sessions =>
      UnmodifiableMapView<String, PlaybackSession>(_service.sessions);
  List<PlaybackSession> get activeSessions =>
      List<PlaybackSession>.unmodifiable(_service.activeSessions);
  PlaybackSessionSnapshot? sessionSnapshotById(String sessionId) {
    final runtime = _service.sessionById(sessionId);
    return runtime == null
        ? null
        : PlaybackSessionSnapshot.fromRuntime(runtime);
  }

  bool hasSession(String sessionId) => _service.sessions.containsKey(sessionId);
  bool get hasPlayingSession => _service.playingSessionCount > 0;
  bool get hasPlayingAudioSession => _service.hasPlayingAudioSession;
  bool get hasPlaybackToKeepAlive => _service.hasPlaybackToKeepAlive;
  bool get persistedSessionStateReady => aggregateState.isInitialized;
  bool get nativeRetainedContentUriInventoryReady =>
      _nativeRetainedContentUriInventoryReady;
  bool get persistedUriReferencesReady =>
      persistedSessionStateReady && nativeRetainedContentUriInventoryReady;
  int get persistedUriReferenceRevision => Object.hash(
    _service.sessionStateVersion,
    _nativePersistedUriReferenceRevision,
  );
  Stream<int> get persistedUriReferenceRevisions =>
      _persistedUriReferenceRevisionController.stream;
  Set<String> get persistedContentUris {
    final references = <String>{};
    void retain(String? value) {
      if (value != null && PathMatcher.isContentUri(value)) {
        references.add(value);
      }
    }

    for (final session in _service.sessions.values) {
      retain(session.currentTrackPath);
      retain(session.loadedPath);
      final queueTracks = session.isPlaybackQueue
          ? session.playbackQueue?.expandedTracks
          : session.customQueueTracks;
      for (final track in queueTracks ?? const <MusicTrack>[]) {
        retain(track.path);
      }
    }
    for (final retainedUris in _nativeRetainedContentUrisBySession.values) {
      for (final uri in retainedUris) {
        retain(uri);
      }
    }
    return references;
  }

  Future<Set<String>> collectPersistedContentUris() async {
    final repository = databaseRepository;
    final stored = repository is PlaybackQueueStorage
        ? await (repository as PlaybackQueueStorage).loadQueueContentUris()
        : const <String>{};
    return {...stored, ...persistedContentUris};
  }

  Future<bool> ensureSessionQueueLoaded(String sessionId) =>
      PlaybackSessionPersistenceCoordinator(
        this,
      ).ensureSessionQueueLoaded(sessionId);

  Future<void> addPlaybackQueueEntries(
    String sessionId,
    List<PlaybackQueueEntry> entries,
  ) => PlaybackQueuePathCoordinator(
    this,
  ).addPlaybackQueueEntries(sessionId, entries);

  Future<PlaybackQueueEntry?> loadQueueEntry(
    String sessionId,
    String entryId,
  ) => PlaybackSessionPersistenceCoordinator(
    this,
  ).loadQueueEntry(sessionId, entryId);

  Future<List<MusicTrack>?> resolveQueueEntryTracksForEdit(
    String sessionId,
    PlaybackQueueEntry snapshot,
    List<int> trackIndices,
  ) => PlaybackSessionPersistenceCoordinator(
    this,
  ).resolveQueueEntryTracksForEdit(sessionId, snapshot, trackIndices);

  Future<List<PlaybackQueueEntryPreview>> loadQueueEntryPreviews(
    String sessionId, {
    required int start,
    required int limit,
  }) => PlaybackSessionPersistenceCoordinator(
    this,
  ).loadQueueEntryPreviews(sessionId, start: start, limit: limit);

  void attachSessionRuntime({
    required void Function(PlaybackSession session) onSessionRegistered,
    void Function(List<PlaybackSession> sessions)? onSessionsRemoved,
    required void Function() onSessionsReordered,
    required void Function() onSessionStateChanged,
    void Function()? onRuntimeStateChanged,
    void Function(PlaybackSession session, Duration position)?
    onSessionPositionChanged,
    FutureOr<void> Function(String sessionId)? onSessionCompleted,
    void Function(String sessionId)? onSessionDurationChanged,
    void Function()? onSessionSettingsChanged,
  }) {
    _onSessionRegistered ??= onSessionRegistered;
    _onSessionsRemoved ??= onSessionsRemoved;
    _onSessionsReordered ??= onSessionsReordered;
    _onSessionStateChanged ??= onSessionStateChanged;
    _onRuntimeStateChanged ??= onRuntimeStateChanged;
    _onSessionPositionChanged ??= onSessionPositionChanged;
    _onSessionCompleted ??= onSessionCompleted;
    _onSessionDurationChanged ??= onSessionDurationChanged;
    _sessionObserversAttached =
        _sessionObserversAttached ||
        onSessionCompleted != null ||
        onSessionDurationChanged != null;
    _onSessionSettingsChanged ??= onSessionSettingsChanged;
  }

  void attachPlaybackQueueSynchronizer(
    PlaybackQueueSessionSynchronizer synchronize,
  ) {
    _synchronizePlaybackQueueSession ??= synchronize;
  }

  void attachCommandPort(PlaybackCommandPort port) {
    _commandPort ??= port;
  }

  void configureUserLaunchInitialization(Future<void> Function()? initialize) {
    _initializeForUserLaunch = initialize;
  }

  Future<bool> _ensureUserLaunchReady() async {
    if (_disposed) return false;
    try {
      await _initializeForUserLaunch?.call();
      return !_disposed;
    } catch (error, stackTrace) {
      AppLogService.error(
        'playback_launch_initialization_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  void detachCommandPort() {
    _commandPort = null;
  }

  void attachLoopModeSynchronizer(PlaybackLoopModeSynchronizer synchronize) {
    _synchronizeLoopMode ??= synchronize;
  }

  void detachRuntime() {
    _persistedTrackResolver = null;
    _recordPlaybackProgress = null;
    _restoreRuntime = null;
    _updatePlaybackHistory = null;
    _onPersistenceFocusChanged = null;
    _synchronizePausedRecovery = null;
    _onSessionRegistered = null;
    _onSessionsRemoved = null;
    _onSessionsReordered = null;
    _onSessionStateChanged = null;
    _onRuntimeStateChanged = null;
    _onSessionPositionChanged = null;
    _onSessionCompleted = null;
    _onSessionDurationChanged = null;
    _onSessionSettingsChanged = null;
    _synchronizePlaybackQueueSession = null;
    _initializeForUserLaunch = null;
    detachCommandPort();
    _synchronizeLoopMode = null;
  }

  void registerSession(PlaybackSession session) {
    _pendingDeletedSessionIds.remove(session.id);
    _service.registerSession(session);
    if (_sessionObserversAttached) {
      _bindSessionListeners(session);
    }
    _onSessionRegistered?.call(session);
  }

  void observeSession(PlaybackSession session) {
    _bindSessionListeners(session);
  }

  PlaybackSession createTrackSession(
    MusicTrack track, {
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
    double? volume,
    List<MusicTrack>? customQueueTracks,
    bool isTemporary = false,
  }) {
    final session =
        PlaybackSession(
            id: _nextSessionId(),
            currentTrackPath: track.path,
            loopMode: loopMode,
            nonSingleLoopMode: loopMode == SessionLoopMode.single
                ? SessionLoopMode.folderSequential
                : loopMode,
            volume: (volume ?? 1.0).clamp(0.0, maxSessionVolume).toDouble(),
            createdAt: DateTime.now(),
            state: const PlayerState(false, ProcessingState.idle),
            customQueueTracks: customQueueTracks,
            isTemporary: isTemporary,
          )
          ..speed = 1.0
          ..channelSwapEnabled = false
          ..audioEffects = AudioEffectsState.flat;
    registerSession(session);
    if (!isTemporary) _scheduleNewSessionPersistence(sessionId: session.id);
    return session;
  }

  PlaybackSession createPlaybackQueue(String name) {
    final session = PlaybackSession(
      id: _nextSessionId(),
      currentTrackPath: '',
      loopMode: SessionLoopMode.crossSequential,
      nonSingleLoopMode: SessionLoopMode.crossSequential,
      volume: 1,
      createdAt: DateTime.now(),
      state: const PlayerState(false, ProcessingState.idle),
      customQueueTracks: const <MusicTrack>[],
      playbackQueue: PlaybackQueueDefinition(name: name, entries: const []),
    );
    registerSession(session);
    _scheduleNewSessionPersistence(sessionId: session.id);
    return session;
  }

  String _nextSessionId() {
    _sessionSeed += 1;
    return 'session_${DateTime.now().microsecondsSinceEpoch}_$_sessionSeed';
  }

  void reorderSessions(int oldIndex, int newIndex) {
    final version = _service.sessionStateVersion;
    _service.reorderSessions(oldIndex, newIndex);
    if (_service.sessionStateVersion == version) return;
    _onSessionsReordered?.call();
  }

  /// Reports confirmed pauses even if another session fails to pause.
  Future<bool> pauseAllSessions({
    void Function(Iterable<String>)? onPaused,
  }) async {
    var pause = _pauseAllInFlight;
    if (pause == null) {
      pause = PlaybackNativeStateCoordinator(this)
          ._pauseAllSessions()
          .whenComplete(() {
            _pauseAllInFlight = null;
            _notifyResumeBatchChanged();
          });
      _pauseAllInFlight = pause;
      _notifyResumeBatchChanged();
    }
    final result = await pause;
    onPaused?.call(result.confirmedSessionIds);
    return result.succeeded;
  }

  Future<bool> removeSession(String sessionId) {
    return removeSessions(<String>[sessionId]);
  }

  Future<bool> removeSessions(
    Iterable<String> sessionIds, {
    bool persist = true,
    bool notify = true,
  }) async {
    final candidates = sessionIds
        .toSet()
        .map((sessionId) => _service.sessions[sessionId])
        .whereType<PlaybackSession>()
        .toList(growable: false);
    if (candidates.isEmpty) return true;

    final removedSessionIds = <String>[];
    var allSucceeded = true;
    for (final session in candidates) {
      session.invalidatePreparation();
    }
    await Future.wait(
      candidates.map((session) async {
        final response = await nativeRepository.removeSession(session.id);
        if (response.isOk) {
          removedSessionIds.add(session.id);
        } else {
          allSucceeded = false;
          _logNativeCommandFailure(
            'removeSession',
            response,
            sessionId: session.id,
          );
        }
      }),
    );

    final removedSessions = _service.removeSessions(removedSessionIds);
    _pruneResumeBatch();
    _removeNativeRetainedContentUris(removedSessionIds);
    if (removedSessions.isEmpty) return allSucceeded;
    for (final session in removedSessions) {
      _seekDispatcher.forgetSession(session.id);
    }
    await Future.wait(removedSessions.map((session) => session.shutdown()));
    _onSessionsRemoved?.call(removedSessions);
    if (notify) _onSessionStateChanged?.call();
    _onRuntimeStateChanged?.call();
    if (persist) {
      _pendingDeletedSessionIds.addAll(removedSessionIds);
      _scheduleNewSessionPersistence(
        sessionId: removedSessionIds.first,
        respectConfiguration: false,
      );
    }
    return allSucceeded;
  }

  Future<bool> clearAllSessions() async {
    final requestedSessions = _service.sessions.values.toList(growable: false);
    for (final session in requestedSessions) {
      session.invalidatePreparation();
      session.failTransportCommand(session.transportCommandId);
      _service.publishSession(session);
    }
    final response = await nativeRepository.clearAll();
    if (response.isFailure) {
      _logNativeCommandFailure('clearAllSessions', response);
      return false;
    }
    _clearNativeRetainedContentUris();
    final removedSessions = _service.removeSessions(
      requestedSessions.where(isRegisteredSession).map((session) => session.id),
    );
    _pruneResumeBatch();
    if (removedSessions.isEmpty) return true;
    for (final session in removedSessions) {
      session.cancelPlaybackStart(session.loadGeneration);
      _seekDispatcher.forgetSession(session.id);
    }
    _onSessionsRemoved?.call(removedSessions);
    _onSessionStateChanged?.call();
    await Future.wait(removedSessions.map((session) => session.shutdown()));
    _onRuntimeStateChanged?.call();
    _pendingDeletedSessionIds.addAll(
      removedSessions.map((session) => session.id),
    );
    _scheduleNewSessionPersistence(respectConfiguration: false);
    return true;
  }

  void _logNativeCommandFailure<T>(
    String command,
    NativeResult<T> response, {
    String? sessionId,
  }) {
    AppLogService.warning(
      'PlaybackFacade.$command failed '
      'code=${response.errorCodeOrNull} '
      'sessionId=${sessionId ?? "none"} '
      'error=${response.errorOrNull}',
    );
  }

  Future<void> seekSession(String sessionId, Duration position) async {
    final session = _service.sessions[sessionId];
    if (session == null ||
        session.isDisposed ||
        !identical(_service.sessions[session.id], session)) {
      return;
    }
    final maxDuration = session.duration;
    final clamped = maxDuration != null && maxDuration > Duration.zero
        ? (position < Duration.zero
              ? Duration.zero
              : (position > maxDuration ? maxDuration : position))
        : (position < Duration.zero ? Duration.zero : position);
    session.setOptimisticPosition(clamped);
    if (session.state.processingState == ProcessingState.completed) {
      session.setOptimisticState(
        playing: false,
        processingState: ProcessingState.idle,
      );
      publishSessionState(session.id);
    }
    session.lastPersistedPositionBucket =
        clamped.inSeconds ~/ positionBucketSeconds;
    if (!_sessionObserversAttached) {
      _onSessionPositionChanged?.call(session, clamped);
    }
    if (session.loadedPath == null && !session.playbackRequested) {
      _seekDispatcher.forgetSession(session.id);
      scheduleSessionStatePersistence(sessionId: session.id);
      return;
    }
    await _seekDispatcher.dispatch(
      session,
      clamped,
      session.loadGeneration,
      nativeQueueIndex:
          _commandPort?.nativePlaybackQueueStartIndexFor(
            session,
            currentPath: session.currentTrackPath,
          ) ??
          session.currentQueueIndex,
      correctPosition: (snapshot) {
        final path = snapshot.path ?? _pathFromSnapshotUri(snapshot.uri);
        if (path == null ||
            !PathMatcher.equalsNormalized(
              resolveRetargetedPath(path),
              resolveRetargetedPath(session.currentTrackPath),
            )) {
          return false;
        }
        session.setOptimisticPosition(snapshot.position);
        session.lastPersistedPositionBucket =
            snapshot.position.inSeconds ~/ positionBucketSeconds;
        if (!_sessionObserversAttached) {
          _onSessionPositionChanged?.call(session, snapshot.position);
        }
        _scheduleSessionPlaybackStatePersistence(session.id);
        return true;
      },
    );
  }

  Future<void> seekSessionByOffset(String sessionId, Duration offset) async {
    final session = _service.sessions[sessionId];
    if (session == null ||
        session.isDisposed ||
        !identical(_service.sessions[session.id], session)) {
      return;
    }
    final target = session.position + offset;
    final maxDuration = session.duration;
    final clamped = maxDuration != null && maxDuration > Duration.zero
        ? (target < Duration.zero
              ? Duration.zero
              : (target > maxDuration ? maxDuration : target))
        : (target < Duration.zero ? Duration.zero : target);
    session.beginLoadingIndicatorThreshold();
    publishSessionState(session.id);
    await seekSession(sessionId, clamped);
  }

  Future<bool> resumeSession(String sessionId) async {
    final session = _service.sessions[sessionId];
    if (session == null || session.currentTrackPath.isEmpty) return false;
    final commands = _commandPort;
    if (session.playbackError != null) {
      session.lastPlayedAt = DateTime.now();
      _notifySessionStateChanged(session);
      // Native recovery keeps the failed item when the source and queue cache
      // are still valid; a replaced queue must re-prepare first.
      if (session.loadedPath != null &&
          session.nativePlaybackQueueCache != null) {
        session.beginLoadingIndicatorThreshold();
        return await commands?.startSession(
              session,
              shouldStartTriggerCountdown: true,
            ) ??
            false;
      }
      return await commands?.prepareSession(
            session,
            nextPath: session.currentTrackPath,
          ) ??
          false;
    }
    if (session.playbackRequested) return true;
    if (commands == null) return false;
    session.lastPlayedAt = DateTime.now();
    return _startPausedSession(session, commands);
  }

  Future<void> toggleSessionPlayPause(String sessionId) async {
    final session = _service.sessions[sessionId];
    if (session == null || session.currentTrackPath.isEmpty) return;
    if (session.playbackError == null && session.playbackRequested) {
      await pauseSessionForResume(session);
      return;
    }
    await resumeSession(sessionId);
  }

  Future<bool> _startPausedSession(
    PlaybackSession session,
    PlaybackCommandPort commands,
  ) {
    final processing = session.state.processingState;
    if (session.isLoading ||
        processing == ProcessingState.completed ||
        processing == ProcessingState.idle) {
      return commands.prepareSession(
        session,
        nextPath: session.currentTrackPath,
        forceStartAtZero:
            !session.isLoading && processing == ProcessingState.completed,
      );
    }
    session.beginLoadingIndicatorThreshold();
    return commands.startSession(session, shouldStartTriggerCountdown: true);
  }

  Future<void> switchSessionTrack(String sessionId, String newPath) async {
    final session = _service.sessions[sessionId];
    if (session == null) return;
    session.beginLoadingIndicatorThreshold();
    await _commandPort?.prepareSession(
      session,
      nextPath: newPath,
      autoPlay: session.effectivePlaying,
      forceStartAtZero: true,
      showLoading: false,
    );
    scheduleSessionStatePersistence(sessionId: session.id);
  }

  Future<void> switchSessionQueueTrack(String sessionId, int queueIndex) async {
    final session = _service.sessions[sessionId];
    if (session == null) return;
    if (session.queueLoadingRequired &&
        !await ensureSessionQueueLoaded(sessionId)) {
      return;
    }
    final tracks = session.isPlaybackQueue
        ? session.playbackQueue!.expandedTracks
        : session.customQueueTracks;
    if (tracks == null || tracks.isEmpty) return;
    final index = queueIndex.clamp(0, tracks.length - 1);
    session.beginLoadingIndicatorThreshold();
    await _commandPort?.prepareSession(
      session,
      nextPath: tracks[index].path,
      autoPlay: session.effectivePlaying,
      forceStartAtZero: true,
      showLoading: false,
      // The switcher excludes a removed current track that is still in the
      // runtime queue until playback moves to another occurrence.
      targetQueueIndex: session.hasDetachedQueueTrack ? index + 1 : index,
    );
    scheduleSessionStatePersistence(sessionId: session.id);
  }

  Future<void> seekSessionToNext(String sessionId) =>
      _seekSessionToAdjacentTrack(sessionId, forward: true);

  Future<void> seekSessionToPrev(String sessionId) =>
      _seekSessionToAdjacentTrack(sessionId, forward: false);

  Future<void> _seekSessionToAdjacentTrack(
    String sessionId, {
    required bool forward,
  }) async {
    final session = _service.sessions[sessionId];
    if (session == null || session.pendingNativeTrackPath != null) return;
    if (!forward &&
        !session.isPlaybackQueue &&
        session.position.inSeconds > 3) {
      await seekSession(sessionId, Duration.zero);
      return;
    }
    if (session.queueLoadingRequired &&
        !await ensureSessionQueueLoaded(sessionId)) {
      return;
    }
    final target = _commandPort?.resolveAdvance(
      session,
      forward: forward,
      manualAdvance: true,
    );
    if (target == null) return;
    session.beginLoadingIndicatorThreshold();
    await _commandPort?.prepareSession(
      session,
      nextPath: target.path,
      autoPlay: session.effectivePlaying,
      forceStartAtZero: true,
      showLoading: false,
      targetQueueIndex: target.queueIndex,
    );
  }

  /// Bucket width currently used to decide whether a position is worth writing.
  int get positionBucketSeconds =>
      PlaybackSessionPersistenceCoordinator(this).positionBucketSeconds;
  void setBackgroundMode(bool value) =>
      PlaybackSessionPersistenceCoordinator(this).setBackgroundMode(value);

  bool hasSessionAdjacentTrack(String sessionId, {required bool forward}) {
    final session = _service.sessions[sessionId];
    return session != null &&
        (_commandPort?.hasAdjacent(session, forward: forward) ?? false);
  }

  Future<void> setSessionLoopMode(
    String sessionId,
    SessionLoopMode mode,
  ) async {
    final session = _service.sessions[sessionId];
    if (session == null) return;
    session.loopMode = mode;
    if (mode != SessionLoopMode.single) {
      session.nonSingleLoopMode = mode;
    }
    _notifySessionSettingsChanged(session);
    unawaited(_synchronizeLoopMode?.call(session, mode));
    scheduleSessionStatePersistence(sessionId: session.id);
  }

  Future<void> toggleSessionSingleLoop(String sessionId) async {
    final session = _service.sessions[sessionId];
    if (session == null) return;
    if (session.loopMode == SessionLoopMode.single) {
      await setSessionLoopMode(sessionId, session.nonSingleLoopMode);
      return;
    }
    session.nonSingleLoopMode = session.loopMode;
    await setSessionLoopMode(sessionId, SessionLoopMode.single);
  }

  Future<void> toggleSessionShuffle(String sessionId) async {
    final session = _service.sessions[sessionId];
    if (session == null || session.loopMode == SessionLoopMode.single) return;
    await setSessionLoopMode(sessionId, session.loopMode.nextOrderMode);
  }

  Future<void> toggleSessionCrossFolder(String sessionId) async {
    final session = _service.sessions[sessionId];
    if (session == null || session.loopMode == SessionLoopMode.single) return;
    await setSessionLoopMode(sessionId, session.loopMode.toggledScopeMode);
  }

  Future<bool> setSessionVolume(
    String sessionId,
    double volume, {
    bool persist = true,
    bool notify = true,
  }) => PlaybackEffectsCoordinator(
    this,
  ).setSessionVolume(sessionId, volume, persist: persist, notify: notify);

  Future<bool> toggleSessionMute(String sessionId) async {
    final session = sessionById(sessionId);
    if (session == null || !isRegisteredSession(session)) return false;
    if (session.volume > 0.001) {
      session.volumeBeforeMute = session.volume;
      return setSessionVolume(sessionId, 0);
    }
    final restoredVolume = session.volumeBeforeMute ?? 1.0;
    final request = setSessionVolume(sessionId, restoredVolume);
    final generation = session.volumeCommandGeneration;
    final ok = await request;
    if (ok && session.volumeCommandGeneration == generation) {
      session.volumeBeforeMute = null;
    }
    return ok;
  }

  Future<void> setSessionSpeed(
    String sessionId,
    double speed, {
    bool persist = true,
    bool notify = true,
  }) => PlaybackEffectsCoordinator(
    this,
  ).setSessionSpeed(sessionId, speed, persist: persist, notify: notify);
  Future<bool> setSessionTemporarySpeed(String sessionId, double? speed) =>
      PlaybackEffectsCoordinator(
        this,
      ).setSessionTemporarySpeed(sessionId, speed);
  double nearestPlaybackSpeed(double speed) =>
      PlaybackEffectsCoordinator(this).nearestPlaybackSpeed(speed);

  void _emitPersistedUriReferenceRevision() {
    if (_disposed || _persistedUriReferenceRevisionController.isClosed) return;
    _persistedUriReferenceRevisionController.add(persistedUriReferenceRevision);
  }

  Future<void> get pendingSessionPreparation =>
      PlaybackNativeStateCoordinator(this).pendingSessionPreparation;
  bool get hasScheduledSessionStatePersistence =>
      PlaybackNativeStateCoordinator(this).hasScheduledSessionStatePersistence;
  bool get hasScheduledSessionOrderPersistence =>
      PlaybackNativeStateCoordinator(this).hasScheduledSessionOrderPersistence;
  PlaybackSession? sessionById(String sessionId) =>
      PlaybackNativeStateCoordinator(this).sessionById(sessionId);
  List<PlaybackSession> get ordinarySessions =>
      PlaybackNativeStateCoordinator(this).ordinarySessions;

  void updateNativeSessionRetainedContentUris(
    String sessionId,
    Iterable<String> retainedUris,
  ) => PlaybackNativeStateCoordinator(
    this,
  ).updateNativeSessionRetainedContentUris(sessionId, retainedUris);
  void replaceNativeRetainedContentUris(
    Iterable<NativePlaybackSnapshot> snapshots,
  ) => PlaybackNativeStateCoordinator(
    this,
  ).replaceNativeRetainedContentUris(snapshots);
  Future<bool> refreshNativeRetainedContentUriInventory() =>
      PlaybackNativeStateCoordinator(
        this,
      ).refreshNativeRetainedContentUriInventory();
  void forgetNativeSessionRetainedContentUris(String sessionId) =>
      PlaybackNativeStateCoordinator(
        this,
      ).forgetNativeSessionRetainedContentUris(sessionId);
  int nextTransportCommandId() =>
      PlaybackNativeStateCoordinator(this).nextTransportCommandId();
  bool isRegisteredSession(PlaybackSession session) =>
      PlaybackNativeStateCoordinator(this).isRegisteredSession(session);
  void markSessionStateDirty([String? sessionId]) =>
      PlaybackNativeStateCoordinator(this).markSessionStateDirty(sessionId);
  void syncPresentationState({
    required String? focusedSessionId,
    required int coverGeneration,
    bool? isInitialized,
    bool refreshSessions = true,
  }) => PlaybackNativeStateCoordinator(this).syncPresentationState(
    focusedSessionId: focusedSessionId,
    coverGeneration: coverGeneration,
    isInitialized: isInitialized,
    refreshSessions: refreshSessions,
  );
  Future<void> removeSessionsForTrackPaths(Iterable<String> trackPaths) =>
      PlaybackNativeStateCoordinator(
        this,
      ).removeSessionsForTrackPaths(trackPaths);
  void applyFadeMultiplierToPlayingSessions(double multiplier) =>
      PlaybackNativeStateCoordinator(
        this,
      ).applyFadeMultiplierToPlayingSessions(multiplier);
  void observeTransportCommandId(int? commandId) =>
      PlaybackNativeStateCoordinator(this).observeTransportCommandId(commandId);
  void applyNativeProgress(NativePlaybackProgressUpdate progress) =>
      PlaybackNativeStateCoordinator(this).applyNativeProgress(progress);
  PlaybackNativeSnapshotApplication applyNativeSnapshot(
    NativePlaybackSnapshot snapshot, {
    required bool Function(String path) hasLibraryTrack,
  }) => PlaybackNativeStateCoordinator(
    this,
  ).applyNativeSnapshot(snapshot, hasLibraryTrack: hasLibraryTrack);
  void publishSessionActivated(String sessionId) =>
      PlaybackNativeStateCoordinator(this).publishSessionActivated(sessionId);

  void attachPersistenceRuntime({
    required MusicTrack? Function(String trackPath) trackByPath,
    required bool Function() recordPlaybackProgress,
    required RestoredPlaybackRuntime restoreRuntime,
    required PlaybackHistoryUpdater updatePlaybackHistory,
    required void Function(String? sessionId) onFocusChanged,
    Future<void> Function(PlaybackSession session)? synchronizePausedRecovery,
  }) => PlaybackSessionPersistenceCoordinator(this).attachPersistenceRuntime(
    trackByPath: trackByPath,
    recordPlaybackProgress: recordPlaybackProgress,
    restoreRuntime: restoreRuntime,
    updatePlaybackHistory: updatePlaybackHistory,
    onFocusChanged: onFocusChanged,
    synchronizePausedRecovery: synchronizePausedRecovery,
  );
  void configurePersistence({required bool enabled}) =>
      PlaybackSessionPersistenceCoordinator(
        this,
      ).configurePersistence(enabled: enabled);
  Future<void> loadPersistedState() =>
      PlaybackSessionPersistenceCoordinator(this).loadPersistedState();
  Future<void> removeMissingTemporarySessions() =>
      PlaybackSessionPersistenceCoordinator(
        this,
      ).removeMissingTemporarySessions();
  Future<void> resetPersistedState() =>
      PlaybackSessionPersistenceCoordinator(this).resetPersistedState();
  Future<void> savePersistedState() =>
      PlaybackSessionPersistenceCoordinator(this).savePersistedState();
  Future<void> saveSessionOrder() =>
      PlaybackSessionPersistenceCoordinator(this).saveSessionOrder();
  void scheduleSessionStatePersistence({
    String? sessionId,
    Duration delay = const Duration(milliseconds: 220),
  }) => PlaybackSessionPersistenceCoordinator(
    this,
  ).scheduleSessionStatePersistence(sessionId: sessionId, delay: delay);
  void scheduleSessionOrderPersistence({
    Duration delay = const Duration(milliseconds: 180),
  }) => PlaybackSessionPersistenceCoordinator(
    this,
  ).scheduleSessionOrderPersistence(delay: delay);
  Future<void> flushSessionStatePersistence({String? sessionId}) =>
      PlaybackSessionPersistenceCoordinator(
        this,
      ).flushSessionStatePersistence(sessionId: sessionId);
  void cancelScheduledPersistence() =>
      PlaybackSessionPersistenceCoordinator(this).cancelScheduledPersistence();

  Future<void> setSessionChannelSwap(String sessionId, bool enabled) =>
      PlaybackEffectsCoordinator(
        this,
      ).setSessionChannelSwap(sessionId, enabled);
  Future<void> setSessionSkipSilence(String sessionId, bool enabled) =>
      PlaybackEffectsCoordinator(
        this,
      ).setSessionSkipSilence(sessionId, enabled);
  Future<void> setSessionNoiseReduction(String sessionId, bool enabled) =>
      PlaybackEffectsCoordinator(
        this,
      ).setSessionNoiseReduction(sessionId, enabled);
  Future<void> setSessionVolumeNormalization(String sessionId, bool enabled) =>
      PlaybackEffectsCoordinator(
        this,
      ).setSessionVolumeNormalization(sessionId, enabled);
  Future<void> setSessionSoundField(
    String sessionId, {
    required double panning,
    required double frontBack,
  }) => PlaybackEffectsCoordinator(
    this,
  ).setSessionSoundField(sessionId, panning: panning, frontBack: frontBack);
  Future<void> setSessionEqEnabled(String sessionId, bool enabled) =>
      PlaybackEffectsCoordinator(this).setSessionEqEnabled(sessionId, enabled);
  Future<void> setSessionEqBandLevel(
    String sessionId,
    int frequencyHz,
    double gainDb,
  ) => PlaybackEffectsCoordinator(
    this,
  ).setSessionEqBandLevel(sessionId, frequencyHz, gainDb);
  Future<void> applySessionEqPreset(String sessionId, EqPreset preset) =>
      PlaybackEffectsCoordinator(this).applySessionEqPreset(sessionId, preset);

  Future<void> addTrackToPlaybackQueue(String sessionId, MusicTrack track) =>
      PlaybackQueuePathCoordinator(
        this,
      ).addTrackToPlaybackQueue(sessionId, track);
  Future<void> addWorkToPlaybackQueue(
    String sessionId, {
    required String title,
    required List<MusicTrack> tracks,
    String? workRootPath,
  }) => PlaybackQueuePathCoordinator(this).addWorkToPlaybackQueue(
    sessionId,
    title: title,
    tracks: tracks,
    workRootPath: workRootPath,
  );
  Future<void> removePlaybackQueueEntry(
    String sessionId,
    String entryId, {
    List<MusicTrack>? tracks,
  }) => PlaybackQueuePathCoordinator(
    this,
  ).removePlaybackQueueEntry(sessionId, entryId, tracks: tracks);
  Future<void> reorderPlaybackQueueEntry(
    String sessionId,
    int oldIndex,
    int newIndex,
  ) => PlaybackQueuePathCoordinator(
    this,
  ).reorderPlaybackQueueEntry(sessionId, oldIndex, newIndex);
  bool renamePlaybackQueue(String sessionId, String name) =>
      PlaybackQueuePathCoordinator(this).renamePlaybackQueue(sessionId, name);
  bool setPlaybackQueueColorValue(String sessionId, int? colorValue) =>
      PlaybackQueuePathCoordinator(
        this,
      ).setPlaybackQueueColorValue(sessionId, colorValue);
  bool replaceSessionTrackSnapshots(MusicTrack updatedTrack) =>
      PlaybackQueuePathCoordinator(
        this,
      ).replaceSessionTrackSnapshots(updatedTrack);
  void rememberRetargetedPath(String oldPath, String newPath) =>
      PlaybackQueuePathCoordinator(
        this,
      ).rememberRetargetedPath(oldPath, newPath);
  String resolveRetargetedPath(String value) =>
      PlaybackQueuePathCoordinator(this).resolveRetargetedPath(value);
  Future<void> validatePlaybackCachePaths(Iterable<String> paths) =>
      PlaybackQueuePathCoordinator(this).validatePlaybackCachePaths(paths);
  String? originalPathForRetargeted(String value) =>
      PlaybackQueuePathCoordinator(this).originalPathForRetargeted(value);
  void clearRetargetedPaths() =>
      PlaybackQueuePathCoordinator(this).clearRetargetedPaths();
  Future<void> retargetPath(String oldPath, String newPath) =>
      PlaybackQueuePathCoordinator(this).retargetPath(oldPath, newPath);

  Future<bool> _runUserLaunch(Future<bool> Function() action) async =>
      await _ensureUserLaunchReady() ? await action() : false;

  Future<bool> playDirect(
    FutureOr<List<MusicTrack>> tracks, {
    int startIndex = 0,
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
  }) => _runUserLaunch(
    () => PlaybackQueuePathCoordinator(
      this,
    ).playDirect(tracks, startIndex: startIndex, loopMode: loopMode),
  );

  Future<bool> addTrackToPlaylist(
    MusicTrack track, {
    List<MusicTrack>? workTracks,
  }) => _runUserLaunch(
    () => PlaybackQueuePathCoordinator(
      this,
    ).addTrackToPlaylist(track, workTracks: workTracks),
  );

  Future<bool> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  }) => _runUserLaunch(
    () => PlaybackQueuePathCoordinator(
      this,
    ).launchQueue(tracks, autoPlay: autoPlay, loopMode: loopMode),
  );

  Future<bool> spawnSession(MusicTrack track, {bool? autoPlay}) =>
      _runUserLaunch(
        () => PlaybackQueuePathCoordinator(
          this,
        ).spawnSession(track, autoPlay: autoPlay),
      );

  Future<bool> spawnSessionWithQueue(
    List<MusicTrack> tracks, {
    int startIndex = 0,
    bool? autoPlay,
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
  }) => _runUserLaunch(
    () => PlaybackQueuePathCoordinator(this).spawnSessionWithQueue(
      tracks,
      startIndex: startIndex,
      autoPlay: autoPlay,
      loopMode: loopMode,
    ),
  );

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    Object? firstError;
    StackTrace? firstStackTrace;
    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    cancelScheduledPersistence();
    _seekDispatcher.clear();
    final persistenceTail = _sessionPersistenceTail;
    if (persistenceTail != null) {
      await attempt(() => persistenceTail);
    }
    final sessionsToDispose = _service.sessions.values.toList(growable: false);
    _service.sessions.clear();
    await Future.wait(
      sessionsToDispose.map((session) => attempt(session.shutdown)),
    );
    await attempt(nativeRepository.dispose);
    await attempt(_service.dispose);
    // Riverpod can pause this UI-only subscription while the playlist is offstage.
    // Waiting for it to receive the done event would block native player disposal.
    unawaited(_resumeBatchChanges.close());
    await Future.wait(<Future<void>>[
      attempt(_sessionActivations.close),
      attempt(_persistedUriReferenceRevisionController.close),
    ]);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }
}
