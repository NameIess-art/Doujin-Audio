import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:just_audio/just_audio.dart';

import '../../../core/errors/native_result.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/logging/app_log_service.dart';
import '../../asmr/application/asmr_playback_cache_service.dart';
import '../../settings/application/app_preferences.dart';
import '../domain/audio_effects.dart';
import '../domain/playback_mode.dart';
import '../domain/playback_queue.dart';
import '../domain/playback_persistence_repository.dart';
import 'playback_session.dart';
import 'playback_session_snapshot.dart';
import 'audio_state_services.dart';
import 'native_playback_repository.dart';
import 'native_playback_bridge.dart';
import 'playback_command_runner.dart';
import 'playback_queue_resolver.dart';

part 'playback_native_state_coordinator.dart';
part 'playback_session_persistence_coordinator.dart';
part 'playback_effects_coordinator.dart';
part 'playback_queue_path_coordinator.dart';

typedef PlaybackQueueSessionSynchronizer =
    Future<void> Function(PlaybackSession session, {bool selectFirst});
typedef PlaybackSessionPreparer =
    Future<bool> Function(
      PlaybackSession session, {
      required String nextPath,
      bool autoPlay,
      bool forceStartAtZero,
      bool showLoading,
      int? targetQueueIndex,
    });
typedef PlaybackSessionPauser = Future<void> Function(PlaybackSession session);
typedef PlaybackSessionStarter =
    Future<bool> Function(
      PlaybackSession session, {
      required bool shouldStartTriggerCountdown,
    });
typedef PlaybackAdvanceResolver =
    PlaybackAdvanceResult? Function(
      PlaybackSession session, {
      required bool forward,
    });
typedef PlaybackAdjacentResolver =
    bool Function(PlaybackSession session, {required bool forward});
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

bool _defaultAutoPlayAddedSessions() => true;
bool _defaultAllowDuplicateWorks() => false;

/// Owns playback sessions and the platform playback runtime.
final class PlaybackFacade {
  PlaybackFacade({
    required this.databaseRepository,
    required this.nativeRepository,
    required this.commandRunner,
    required this.playbackCacheService,
    required PlaybackSessionService service,
  }) : _service = service;

  factory PlaybackFacade.create({
    required PlaybackPersistenceRepository databaseRepository,
    NativePlaybackRepository? nativeRepository,
    PlaybackCommandRunner commandRunner = const PlaybackCommandRunner(),
    AsmrPlaybackCacheService? playbackCacheService,
    PlaybackSessionService? service,
  }) {
    return PlaybackFacade(
      databaseRepository: databaseRepository,
      nativeRepository: nativeRepository ?? NativePlaybackRepository(),
      commandRunner: commandRunner,
      playbackCacheService: playbackCacheService ?? AsmrPlaybackCacheService(),
      service: service ?? PlaybackSessionService(),
    );
  }

  final PlaybackPersistenceRepository databaseRepository;
  final NativePlaybackRepository nativeRepository;
  final PlaybackCommandRunner commandRunner;
  final AsmrPlaybackCacheService playbackCacheService;
  final PlaybackSessionService _service;
  final StreamController<String> _sessionActivations =
      StreamController<String>.broadcast(sync: true);
  final StreamController<int> _persistedUriReferenceRevisionController =
      StreamController<int>.broadcast(sync: true);
  final Map<String, Set<String>> _nativeRetainedContentUrisBySession =
      <String, Set<String>>{};
  int _nativePersistedUriReferenceRevision = 0;
  bool _nativeRetainedContentUriInventoryReady = false;
  MusicTrack? Function(String trackPath)? _persistedTrackResolver;
  bool Function()? _recordPlaybackProgress;
  RestoredPlaybackRuntime? _restoreRuntime;
  PlaybackHistoryUpdater? _updatePlaybackHistory;
  void Function(String? sessionId)? _onPersistenceFocusChanged;
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
  PlaybackSessionPreparer? _prepareSession;
  PlaybackSessionPauser? _pauseSession;
  PlaybackSessionStarter? _startSession;
  PlaybackAdvanceResolver? _resolveAdvance;
  PlaybackAdjacentResolver? _hasAdjacent;
  PlaybackLoopModeSynchronizer? _synchronizeLoopMode;
  bool Function() _autoPlayAddedSessions = _defaultAutoPlayAddedSessions;
  bool Function() _allowDuplicateWorks = _defaultAllowDuplicateWorks;
  bool _sessionObserversAttached = false;
  final Map<String, String> _retargetedPathAliases = <String, String>{};
  final Random _random = Random();
  final Set<String> _deferredVolumeReloadSessionIds = <String>{};
  int _transportCommandSequence = 0;
  int _sessionSeed = 0;
  bool _persistenceEnabled = true;
  bool _backgroundMode = false;
  Timer? _savePlaybackStateTimer;
  final Set<String> _pendingPlaybackStateSessionIds = <String>{};
  Future<void>? _sessionPersistenceTail;

  /// Position-persistence bucket while the UI is visible.
  static const int foregroundPositionBucketSeconds = 5;

  /// Position-persistence bucket once the UI is gone.
  ///
  /// Nothing on screen consumes a resumable position in the background, and the
  /// native service persists its own copy. A 5s bucket there costs ~720 SQLite
  /// transactions per hour - ~8600 over a 12h screen-off session - for a
  /// precision no one can observe.
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
  PlaybackStateSliceData get state => _service.slice.state;
  Stream<PlaybackStateSliceData> get states => _service.slice.stream;
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
  bool get hasPlayingSession =>
      _service.sessions.values.any((session) => session.state.playing);
  bool get hasPlaybackToKeepAlive => _service.sessions.values.any(
    (session) =>
        session.state.playing ||
        session.isLoading ||
        session.isPlaybackStarting ||
        session.loadedPath != null,
  );
  bool get hasRetainedPlaybackSession => _service.sessions.isNotEmpty;
  bool get persistedSessionStateReady => state.isInitialized;
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

  void attachSessionDefaults({
    required bool Function() autoPlayAddedSessions,
    required bool Function() allowDuplicateWorks,
  }) {
    _autoPlayAddedSessions = autoPlayAddedSessions;
    _allowDuplicateWorks = allowDuplicateWorks;
  }

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

  void attachPlaybackCommands({
    required PlaybackSessionPreparer prepareSession,
    required PlaybackSessionPauser pauseSession,
    required PlaybackSessionStarter startSession,
    required PlaybackAdvanceResolver resolveAdvance,
    required PlaybackAdjacentResolver hasAdjacent,
  }) {
    _prepareSession ??= prepareSession;
    _pauseSession ??= pauseSession;
    _startSession ??= startSession;
    _resolveAdvance ??= resolveAdvance;
    _hasAdjacent ??= hasAdjacent;
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
    _prepareSession = null;
    _pauseSession = null;
    _startSession = null;
    _resolveAdvance = null;
    _hasAdjacent = null;
    _synchronizeLoopMode = null;
    _autoPlayAddedSessions = _defaultAutoPlayAddedSessions;
    _allowDuplicateWorks = _defaultAllowDuplicateWorks;
  }

  void registerSession(PlaybackSession session) {
    _service.registerSession(session);
    if (_sessionObserversAttached) {
      _bindSessionListeners(session);
    }
    _onSessionRegistered?.call(session);
  }

  void observeSession(PlaybackSession session) {
    _bindSessionListeners(session);
  }

  void _bindSessionListeners(PlaybackSession session) {
    final stateSub = session.stateStream.listen((state) {
      if (!_service.sessions.containsKey(session.id)) return;

      final previousState =
          session.previousStateBeforeLastStateEvent ?? session.state;
      session.previousStateBeforeLastStateEvent = null;
      final previousPlaying = previousState.playing;
      final previousProcessing = previousState.processingState;
      session.state = state;
      final isNewCompletion =
          previousProcessing != ProcessingState.completed &&
          state.processingState == ProcessingState.completed;
      final currentGeneration = session.playbackCommandGeneration;
      final shouldAutoAdvanceAfterCompletion =
          isNewCompletion &&
          !session.loopMode.isOneShot &&
          !session.isLoading &&
          !session.isAdvancingAfterCompletion &&
          session.playbackError == null &&
          _resolveAdvance?.call(session, forward: true) != null &&
          session.lastHandledCompletionGeneration != currentGeneration;
      if (shouldAutoAdvanceAfterCompletion) {
        session.isLoading = true;
        session.isAdvancingAfterCompletion = true;
        session.lastHandledCompletionGeneration = currentGeneration;
      }
      if (!state.playing &&
          (state.processingState == ProcessingState.idle ||
              state.processingState == ProcessingState.completed)) {
        session.isPlaybackStarting = false;
      }
      if (state.processingState != ProcessingState.completed) {
        session.isAdvancingAfterCompletion = false;
      }
      _onRuntimeStateChanged?.call();
      _onSessionStateChanged?.call();

      if (previousPlaying != state.playing ||
          previousProcessing != state.processingState) {
        scheduleSessionStatePersistence();
      }

      if (isNewCompletion && shouldAutoAdvanceAfterCompletion) {
        _dispatchSessionCompleted(session.id);
      }
    });
    session.subscriptions.add(stateSub);

    final positionSub = session.positionStream.listen((position) {
      if (!_service.sessions.containsKey(session.id)) return;
      session.lastKnownPosition = position;
      final bucket = position.inSeconds ~/ positionBucketSeconds;
      if (bucket != session.lastPersistedPositionBucket) {
        session.lastPersistedPositionBucket = bucket;
        _scheduleSessionPlaybackStatePersistence(session.id);
      }
      _onSessionPositionChanged?.call(session, position);
    });
    session.subscriptions.add(positionSub);

    final durationSub = session.durationStream.listen((_) {
      if (!_service.sessions.containsKey(session.id)) return;
      _scheduleSessionPlaybackStatePersistence(
        session.id,
        delay: const Duration(milliseconds: 1500),
      );
      _onSessionDurationChanged?.call(session.id);
    });
    session.subscriptions.add(durationSub);
  }

  PlaybackSession createTrackSession(
    MusicTrack track, {
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
    double? volume,
    List<MusicTrack>? customQueueTracks,
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
            state: PlayerState(false, ProcessingState.idle),
            customQueueTracks: customQueueTracks,
          )
          ..speed = 1.0
          ..channelSwapEnabled = false
          ..audioEffects = AudioEffectsState.flat;
    registerSession(session);
    _scheduleNewSessionPersistence();
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
      state: PlayerState(false, ProcessingState.idle),
      customQueueTracks: const <MusicTrack>[],
      playbackQueue: PlaybackQueueDefinition(name: name, entries: const []),
    );
    registerSession(session);
    _scheduleNewSessionPersistence();
    return session;
  }

  String _nextSessionId() {
    _sessionSeed += 1;
    return 'session_${DateTime.now().microsecondsSinceEpoch}_$_sessionSeed';
  }

  void _scheduleNewSessionPersistence({bool respectConfiguration = true}) {
    if (respectConfiguration && !_persistenceEnabled) return;
    scheduleSessionStatePersistence();
    scheduleSessionOrderPersistence();
  }

  void reorderSessions(int oldIndex, int newIndex) {
    final version = _service.sessionStateVersion;
    _service.reorderSessions(oldIndex, newIndex);
    if (_service.sessionStateVersion == version) return;
    _onSessionsReordered?.call();
  }

  Future<bool> pauseAllSessions() async {
    final response = await nativeRepository.pauseAll();
    if (response.isFailure) {
      _logNativeCommandFailure('pauseAllSessions', response);
      return false;
    }
    for (final session in _service.sessions.values) {
      session.setOptimisticState(playing: false);
      session.isLoading = false;
      session.isPlaybackStarting = false;
    }
    _onRuntimeStateChanged?.call();
    _onSessionStateChanged?.call();
    scheduleSessionStatePersistence();
    return true;
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
    }

    final removedSessions = _service.removeSessions(removedSessionIds);
    _removeNativeRetainedContentUris(removedSessionIds);
    if (removedSessions.isEmpty) return allSucceeded;
    for (final session in removedSessions) {
      session.isPlaybackStarting = false;
      _deferredVolumeReloadSessionIds.remove(session.id);
    }
    await Future.wait(removedSessions.map((session) => session.shutdown()));
    _onSessionsRemoved?.call(removedSessions);
    if (notify) _onSessionStateChanged?.call();
    _onRuntimeStateChanged?.call();
    if (persist) {
      _scheduleNewSessionPersistence(respectConfiguration: false);
    }
    return allSucceeded;
  }

  Future<bool> clearAllSessions() async {
    final response = await nativeRepository.clearAll();
    if (response.isFailure) {
      _logNativeCommandFailure('clearAllSessions', response);
      return false;
    }
    _clearNativeRetainedContentUris();
    final removedSessions = _service.removeSessions(
      _service.sessions.keys.toList(growable: false),
    );
    if (removedSessions.isEmpty) return true;
    for (final session in removedSessions) {
      session.isPlaybackStarting = false;
      _deferredVolumeReloadSessionIds.remove(session.id);
    }
    _onSessionsRemoved?.call(removedSessions);
    _onSessionStateChanged?.call();
    await Future.wait(removedSessions.map((session) => session.shutdown()));
    _onRuntimeStateChanged?.call();
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
    session.beginLoadingIndicatorThreshold();
    session.setOptimisticPosition(position);
    session.lastPersistedPositionBucket =
        position.inSeconds ~/ positionBucketSeconds;
    _onSessionPositionChanged?.call(session, position);
    await nativeRepository.seek(session.id, position);
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
    await seekSession(sessionId, clamped);
  }

  Future<void> toggleSessionPlayPause(String sessionId) async {
    final session = _service.sessions[sessionId];
    if (session == null || session.currentTrackPath.isEmpty) return;
    if (session.playbackError != null) {
      session.lastPlayedAt = DateTime.now();
      _onSessionStateChanged?.call();
      // A native player can keep the failed media item while ExoPlayer is in
      // an error/idle state. Re-preparing the unchanged path is a no-op in the
      // preparation coordinator, so route retries through native recovery when
      // the session still has a loaded source. Preparation is only needed when
      // the original native session was never created.
      if (session.loadedPath != null) {
        session.beginLoadingIndicatorThreshold();
        await _startSession?.call(session, shouldStartTriggerCountdown: true);
      } else {
        await _prepareSession?.call(
          session,
          nextPath: session.currentTrackPath,
        );
      }
      return;
    }
    if (session.playbackRequested) {
      await _pauseSession?.call(session);
      return;
    }
    session.lastPlayedAt = DateTime.now();
    if (session.isLoading) {
      await _prepareSession?.call(session, nextPath: session.currentTrackPath);
      return;
    }
    if (session.state.processingState == ProcessingState.completed ||
        session.state.processingState == ProcessingState.idle) {
      await _prepareSession?.call(
        session,
        nextPath: session.currentTrackPath,
        forceStartAtZero:
            session.state.processingState == ProcessingState.completed,
      );
      return;
    }
    session.beginLoadingIndicatorThreshold();
    await _startSession?.call(session, shouldStartTriggerCountdown: true);
  }

  Future<void> switchSessionTrack(String sessionId, String newPath) async {
    final session = _service.sessions[sessionId];
    if (session == null) return;
    await _prepareSession?.call(
      session,
      nextPath: newPath,
      autoPlay: session.effectivePlaying,
      forceStartAtZero: true,
      showLoading: false,
    );
    scheduleSessionStatePersistence();
  }

  Future<void> switchSessionQueueTrack(String sessionId, int queueIndex) async {
    final session = _service.sessions[sessionId];
    if (session == null) return;
    final tracks = session.isPlaybackQueue
        ? session.playbackQueue!.expandedTracks
        : session.customQueueTracks;
    if (tracks == null || tracks.isEmpty) return;
    final index = queueIndex.clamp(0, tracks.length - 1);
    await _prepareSession?.call(
      session,
      nextPath: tracks[index].path,
      autoPlay: session.effectivePlaying,
      forceStartAtZero: true,
      showLoading: false,
      targetQueueIndex: index,
    );
    scheduleSessionStatePersistence();
  }

  Future<void> seekSessionToNext(String sessionId) async {
    final session = _service.sessions[sessionId];
    if (session == null || session.pendingNativeTrackPath != null) return;
    final target = _resolveAdvance?.call(session, forward: true);
    if (target == null) return;
    session.beginLoadingIndicatorThreshold();
    await _prepareSession?.call(
      session,
      nextPath: target.path,
      autoPlay: session.effectivePlaying,
      forceStartAtZero: true,
      showLoading: false,
      targetQueueIndex: target.queueIndex,
    );
  }

  Future<void> seekSessionToPrev(String sessionId) async {
    final session = _service.sessions[sessionId];
    if (session == null || session.pendingNativeTrackPath != null) return;
    if (!session.isPlaybackQueue && session.position.inSeconds > 3) {
      await seekSession(sessionId, Duration.zero);
      return;
    }
    final target = _resolveAdvance?.call(session, forward: false);
    if (target == null) return;
    session.beginLoadingIndicatorThreshold();
    await _prepareSession?.call(
      session,
      nextPath: target.path,
      autoPlay: session.effectivePlaying,
      forceStartAtZero: true,
      showLoading: false,
      targetQueueIndex: target.queueIndex,
    );
  }

  /// Bucket width currently used to decide whether a position is worth writing.
  int get positionBucketSeconds => _backgroundMode
      ? backgroundPositionBucketSeconds
      : foregroundPositionBucketSeconds;

  /// Switches position-persistence cadence with UI visibility.
  ///
  /// Entering the background flushes first so the fine-grained position observed
  /// while visible is not lost to the coarser bucket.
  void setBackgroundMode(bool value) {
    if (_backgroundMode == value) return;
    if (value) {
      _savePlaybackStateTimer?.cancel();
      _savePlaybackStateTimer = null;
      if (_pendingPlaybackStateSessionIds.isNotEmpty) {
        unawaited(_enqueueSessionPersistence(_savePendingPlaybackStates));
      }
    }
    _backgroundMode = value;
    // Buckets from the previous width are not comparable to the new one.
    for (final session in _service.sessions.values) {
      session.lastPersistedPositionBucket =
          session.lastKnownPosition.inSeconds ~/ positionBucketSeconds;
    }
  }

  bool hasSessionAdjacentTrack(String sessionId, {required bool forward}) {
    final session = _service.sessions[sessionId];
    return session != null &&
        !session.isLoading &&
        (_hasAdjacent?.call(session, forward: forward) ?? false);
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
    _service.markActiveSessionsDirty();
    _onSessionSettingsChanged?.call();
    final synchronize = _synchronizeLoopMode;
    if (synchronize != null) {
      unawaited(synchronize(session, mode));
    }
    scheduleSessionStatePersistence();
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
  }) async {
    final session = _service.sessions[sessionId];
    if (session == null ||
        session.isDisposed ||
        !identical(_service.sessions[session.id], session)) {
      return false;
    }
    final nextVolume = volume.clamp(0.0, maxSessionVolume);
    final hasDeferredReload = _deferredVolumeReloadSessionIds.contains(
      session.id,
    );
    if ((session.volume - nextVolume).abs() < 0.001) {
      if (persist && hasDeferredReload) {
        final response = await nativeRepository.setVolume(
          session.id,
          session.volume,
        );
        if (response.isFailure) {
          _logNativeCommandFailure(
            'setSessionVolume',
            response,
            sessionId: session.id,
          );
          return false;
        }
        if (!_isCurrentSession(session)) return true;
        _deferredVolumeReloadSessionIds.remove(session.id);
      }
      if (persist) await flushSessionStatePersistence();
      return true;
    }
    final previousVolume = session.volume;
    final previouslyDeferred = hasDeferredReload;
    session.volume = nextVolume;
    if (persist) {
      _deferredVolumeReloadSessionIds.remove(session.id);
    } else {
      _deferredVolumeReloadSessionIds.add(session.id);
    }
    if (notify) {
      _service.markActiveSessionsDirty();
      _onSessionStateChanged?.call();
    }
    final response = await nativeRepository.setVolume(
      session.id,
      session.volume,
      reloadSource: persist,
    );
    if (!_isCurrentSession(session)) return response.isOk;
    if (response.isFailure) {
      session.volume = previousVolume;
      if (previouslyDeferred) {
        _deferredVolumeReloadSessionIds.add(session.id);
      } else {
        _deferredVolumeReloadSessionIds.remove(session.id);
      }
      if (notify) {
        _service.markActiveSessionsDirty();
        _onSessionStateChanged?.call();
      }
      _logNativeCommandFailure(
        'setSessionVolume',
        response,
        sessionId: session.id,
      );
      return false;
    }
    if (persist) await flushSessionStatePersistence();
    return true;
  }

  Future<void> setSessionSpeed(
    String sessionId,
    double speed, {
    bool persist = true,
    bool notify = true,
  }) async {
    final session = _service.sessions[sessionId];
    if (session == null ||
        session.isDisposed ||
        !identical(_service.sessions[session.id], session)) {
      return;
    }
    final nextSpeed = nearestPlaybackSpeed(speed);
    if ((session.speed - nextSpeed).abs() < 0.001) {
      if (persist) await flushSessionStatePersistence();
      return;
    }
    final previous = session.speed;
    session.speed = nextSpeed;
    _service.markActiveSessionsDirty();
    if (notify) _onSessionSettingsChanged?.call();
    final response = await nativeRepository.setSpeed(session.id, nextSpeed);
    if (!_isCurrentSession(session)) return;
    if (response.isFailure) {
      session.speed = previous;
      _service.markActiveSessionsDirty();
      AppLogService.warning(
        'PlaybackFacade.setSessionSpeed error: ${response.errorOrNull}',
      );
      if (notify) _onSessionSettingsChanged?.call();
      return;
    }
    if (persist) await flushSessionStatePersistence();
  }

  Future<bool> setSessionTemporarySpeed(String sessionId, double? speed) async {
    final session = _service.sessions[sessionId];
    if (session == null ||
        session.isDisposed ||
        !identical(_service.sessions[session.id], session)) {
      return false;
    }
    final normalizedSpeed = speed?.clamp(0.25, 3.0).toDouble();
    final response = await nativeRepository.setTemporarySpeed(
      session.id,
      normalizedSpeed,
    );
    if (response.isOk) return true;
    AppLogService.warning(
      'PlaybackFacade.setSessionTemporarySpeed error: '
      '${response.errorCodeOrNull} ${response.errorOrNull}',
    );
    return false;
  }

  bool _isCurrentSession(PlaybackSession? session) {
    return session != null &&
        !session.isDisposed &&
        identical(_service.sessions[session.id], session);
  }

  double nearestPlaybackSpeed(double speed) {
    return playbackSpeedOptions.reduce((best, candidate) {
      final bestDistance = (best - speed).abs();
      final candidateDistance = (candidate - speed).abs();
      return candidateDistance < bestDistance ? candidate : best;
    });
  }

  void clearDeferredVolumeReloads() {
    _deferredVolumeReloadSessionIds.clear();
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
  void markSessionStateDirty() =>
      PlaybackNativeStateCoordinator(this).markSessionStateDirty();
  void syncPresentationState({
    required String? focusedSessionId,
    required bool multiThreadPlaybackEnabled,
    required int coverGeneration,
    bool? isInitialized,
  }) => PlaybackNativeStateCoordinator(this).syncPresentationState(
    focusedSessionId: focusedSessionId,
    multiThreadPlaybackEnabled: multiThreadPlaybackEnabled,
    coverGeneration: coverGeneration,
    isInitialized: isInitialized,
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
  }) => PlaybackSessionPersistenceCoordinator(this).attachPersistenceRuntime(
    trackByPath: trackByPath,
    recordPlaybackProgress: recordPlaybackProgress,
    restoreRuntime: restoreRuntime,
    updatePlaybackHistory: updatePlaybackHistory,
    onFocusChanged: onFocusChanged,
  );
  void configurePersistence({required bool enabled}) =>
      PlaybackSessionPersistenceCoordinator(
        this,
      ).configurePersistence(enabled: enabled);
  Future<void> loadPersistedState() =>
      PlaybackSessionPersistenceCoordinator(this).loadPersistedState();
  Future<void> resetPersistedState() =>
      PlaybackSessionPersistenceCoordinator(this).resetPersistedState();
  Future<void> savePersistedState() =>
      PlaybackSessionPersistenceCoordinator(this).savePersistedState();
  Future<void> saveSessionOrder() =>
      PlaybackSessionPersistenceCoordinator(this).saveSessionOrder();
  void scheduleSessionStatePersistence({
    Duration delay = const Duration(milliseconds: 220),
  }) => PlaybackSessionPersistenceCoordinator(
    this,
  ).scheduleSessionStatePersistence(delay: delay);
  void scheduleSessionOrderPersistence({
    Duration delay = const Duration(milliseconds: 180),
  }) => PlaybackSessionPersistenceCoordinator(
    this,
  ).scheduleSessionOrderPersistence(delay: delay);
  Future<void> flushSessionStatePersistence() =>
      PlaybackSessionPersistenceCoordinator(
        this,
      ).flushSessionStatePersistence();
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
  Future<void> setSessionPanning(String sessionId, double panning) =>
      PlaybackEffectsCoordinator(this).setSessionPanning(sessionId, panning);
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
  Future<void> removePlaybackQueueEntry(String sessionId, String entryId) =>
      PlaybackQueuePathCoordinator(
        this,
      ).removePlaybackQueueEntry(sessionId, entryId);
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
  void clearRetargetedPaths() =>
      PlaybackQueuePathCoordinator(this).clearRetargetedPaths();
  Future<void> retargetPath(String oldPath, String newPath) =>
      PlaybackQueuePathCoordinator(this).retargetPath(oldPath, newPath);
  Future<bool> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  }) => PlaybackQueuePathCoordinator(
    this,
  ).launchQueue(tracks, autoPlay: autoPlay, loopMode: loopMode);
  Future<bool> spawnSession(MusicTrack track, {bool? autoPlay}) =>
      PlaybackQueuePathCoordinator(
        this,
      ).spawnSession(track, autoPlay: autoPlay);
  Future<bool> spawnSessionWithQueue(
    List<MusicTrack> tracks, {
    int startIndex = 0,
    bool? autoPlay,
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
  }) => PlaybackQueuePathCoordinator(this).spawnSessionWithQueue(
    tracks,
    startIndex: startIndex,
    autoPlay: autoPlay,
    loopMode: loopMode,
  );

  Future<void> dispose() async {
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
    final persistenceTail = _sessionPersistenceTail;
    if (persistenceTail != null) {
      await attempt(() => persistenceTail);
    }
    await Future.wait(<Future<void>>[
      attempt(_sessionActivations.close),
      attempt(_persistedUriReferenceRevisionController.close),
    ]);
    final sessionsToDispose = _service.sessions.values.toList(growable: false);
    _service.sessions.clear();
    await Future.wait(
      sessionsToDispose.map((session) => attempt(session.shutdown)),
    );
    await attempt(playbackCacheService.dispose);
    await attempt(nativeRepository.dispose);
    await attempt(_service.dispose);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  void _dispatchSessionCompleted(String sessionId) {
    final callback = _onSessionCompleted;
    if (callback == null) return;
    unawaited(() async {
      try {
        await callback(sessionId);
      } catch (error, stackTrace) {
        final session = _service.sessions[sessionId];
        if (session != null) {
          session.isLoading = false;
          session.isAdvancingAfterCompletion = false;
          session.playbackError = error.toString();
          _onRuntimeStateChanged?.call();
          _onSessionStateChanged?.call();
        }
        AppLogService.error(
          'PlaybackFacade.sessionCompleted error',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }());
  }
}

final class PlaybackNativeSnapshotApplication {
  const PlaybackNativeSnapshotApplication({
    required this.snapshot,
    required this.session,
    required this.previousTrackPath,
    required this.trackChanged,
    required this.playbackIntentChanged,
  });

  const PlaybackNativeSnapshotApplication.notApplied(this.snapshot)
    : session = null,
      previousTrackPath = null,
      trackChanged = false,
      playbackIntentChanged = false;

  final NativePlaybackSnapshot snapshot;
  final PlaybackSession? session;
  final String? previousTrackPath;
  final bool trackChanged;
  final bool playbackIntentChanged;

  bool get applied => session != null;
}
