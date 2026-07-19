import 'dart:async';
import 'dart:math';

import 'package:just_audio/just_audio.dart';

import '../../../core/errors/native_result.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/persistence/app_database.dart' show PersistedSession;
import '../../../core/persistence/audio_database_repository.dart';
import '../../asmr/application/asmr_playback_cache_service.dart';
import '../../settings/application/app_preferences.dart';
import '../domain/audio_effects.dart';
import '../domain/playback_mode.dart';
import '../domain/playback_queue.dart';
import 'playback_session.dart';
import 'audio_state_services.dart';
import 'native_playback_repository.dart';
import 'native_playback_bridge.dart';
import 'playback_command_runner.dart';
import 'playback_queue_resolver.dart';

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
    required this.service,
  });

  factory PlaybackFacade.create({
    required AudioDatabaseRepository databaseRepository,
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

  final AudioDatabaseRepository databaseRepository;
  final NativePlaybackRepository nativeRepository;
  final PlaybackCommandRunner commandRunner;
  final AsmrPlaybackCacheService playbackCacheService;
  final PlaybackSessionService service;
  final StreamController<String> _sessionActivations =
      StreamController<String>.broadcast(sync: true);
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
  void Function(String sessionId)? _onSessionCompleted;
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
  Timer? _savePlaybackStateTimer;
  final Set<String> _pendingPlaybackStateSessionIds = <String>{};
  Future<void>? _sessionPersistenceTail;

  static const double maxSessionVolume = 2.0;
  static const List<double> playbackSpeedOptions = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2.0,
  ];

  Stream<String> get sessionActivations => _sessionActivations.stream;
  PlaybackStateSliceData get state => service.slice.state;
  Stream<PlaybackStateSliceData> get states => service.slice.stream;
  PlaybackSession? sessionById(String sessionId) =>
      service.sessionById(sessionId);
  List<PlaybackSession> get ordinarySessions => service.activeSessions
      .where((session) => !session.isPlaybackQueue)
      .toList(growable: false);

  int nextTransportCommandId() => ++_transportCommandSequence;

  void observeTransportCommandId(int? commandId) {
    if (commandId != null && commandId > _transportCommandSequence) {
      _transportCommandSequence = commandId;
    }
  }

  void applyNativeProgress(NativePlaybackProgressUpdate progress) {
    if (service.sessions[progress.sessionId]?.pendingNativeTrackPath != null) {
      return;
    }
    service.applyNativeProgress(progress);
  }

  PlaybackNativeSnapshotApplication applyNativeSnapshot(
    NativePlaybackSnapshot snapshot, {
    required bool Function(String path) hasLibraryTrack,
  }) {
    observeTransportCommandId(snapshot.transportCommandId);
    final normalized = _normalizeNativeSnapshot(
      snapshot,
      hasLibraryTrack: hasLibraryTrack,
    );
    final session = service.sessions[normalized.sessionId];
    if (session == null || session.pendingNativeTrackPath != null) {
      return PlaybackNativeSnapshotApplication.notApplied(normalized);
    }
    final previousTrackPath = session.currentTrackPath;
    final previousState = session.state;
    final previousIsPlaybackStarting = session.isPlaybackStarting;
    final previousPendingPlayingIntent = session.pendingPlayingIntent;
    if (!service.applyNativeSnapshot(normalized)) {
      return PlaybackNativeSnapshotApplication.notApplied(normalized);
    }
    return PlaybackNativeSnapshotApplication(
      snapshot: normalized,
      session: session,
      previousTrackPath: previousTrackPath,
      trackChanged: session.currentTrackPath != previousTrackPath,
      playbackIntentChanged:
          session.state == previousState &&
          (session.isPlaybackStarting != previousIsPlaybackStarting ||
              session.pendingPlayingIntent != previousPendingPlayingIntent),
    );
  }

  NativePlaybackSnapshot _normalizeNativeSnapshot(
    NativePlaybackSnapshot snapshot, {
    required bool Function(String path) hasLibraryTrack,
  }) {
    final rawPath = snapshot.path ?? _pathFromSnapshotUri(snapshot.uri);
    if (rawPath == null || rawPath.isEmpty) return snapshot;
    final resolvedPath = resolveRetargetedPath(rawPath);
    final currentSession = service.sessions[snapshot.sessionId];
    final currentSessionPath = currentSession?.currentTrackPath;
    if (currentSession != null &&
        currentSessionPath != null &&
        currentSessionPath.isNotEmpty &&
        PathMatcher.equalsNormalized(resolvedPath, rawPath)) {
      final originalTrack = _sessionTrackForResolvedPath(
        currentSession,
        resolvedPath,
      );
      if (originalTrack != null &&
          PathMatcher.equalsNormalized(
            resolveRetargetedPath(originalTrack.path),
            resolvedPath,
          )) {
        return snapshot.copyWith(
          path: originalTrack.path,
          uri: _snapshotUriForPath(originalTrack.path),
        );
      }
    }
    if (!PathMatcher.equalsNormalized(resolvedPath, rawPath)) {
      return snapshot.copyWith(
        path: resolvedPath,
        uri: _snapshotUriForPath(resolvedPath),
      );
    }
    if (currentSessionPath == null || currentSessionPath.isEmpty) {
      return snapshot;
    }
    final resolvedSessionPath = resolveRetargetedPath(currentSessionPath);
    if (PathMatcher.equalsNormalized(resolvedSessionPath, resolvedPath) ||
        hasLibraryTrack(resolvedPath) ||
        !hasLibraryTrack(resolvedSessionPath)) {
      return snapshot;
    }
    return snapshot.copyWith(
      path: resolvedSessionPath,
      uri: _snapshotUriForPath(resolvedSessionPath),
    );
  }

  MusicTrack? _sessionTrackForResolvedPath(
    PlaybackSession session,
    String resolvedPath,
  ) {
    for (final track in session.customQueueTracks ?? const <MusicTrack>[]) {
      if (PathMatcher.equalsNormalized(
        resolveRetargetedPath(track.path),
        resolvedPath,
      )) {
        return track;
      }
    }
    return null;
  }

  String _snapshotUriForPath(String value) {
    if (PathMatcher.isContentUri(value) || PathMatcher.isRemoteUri(value)) {
      return value;
    }
    return Uri.file(value).toString();
  }

  String? _pathFromSnapshotUri(String? value) {
    if (value == null || value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null) return value;
    if (uri.scheme == 'file') {
      return uri.toFilePath();
    }
    if (uri.scheme == 'content' ||
        uri.scheme == 'http' ||
        uri.scheme == 'https') {
      return value;
    }
    return null;
  }

  void publishSessionActivated(String sessionId) {
    if (sessionId.isEmpty || _sessionActivations.isClosed) return;
    _sessionActivations.add(sessionId);
  }

  void attachSessionDefaults({
    required bool Function() autoPlayAddedSessions,
    required bool Function() allowDuplicateWorks,
  }) {
    _autoPlayAddedSessions = autoPlayAddedSessions;
    _allowDuplicateWorks = allowDuplicateWorks;
  }

  void attachPersistenceRuntime({
    required MusicTrack? Function(String trackPath) trackByPath,
    required bool Function() recordPlaybackProgress,
    required RestoredPlaybackRuntime restoreRuntime,
    required PlaybackHistoryUpdater updatePlaybackHistory,
    required void Function(String? sessionId) onFocusChanged,
  }) {
    _persistedTrackResolver ??= trackByPath;
    _recordPlaybackProgress ??= recordPlaybackProgress;
    _restoreRuntime ??= restoreRuntime;
    _updatePlaybackHistory ??= updatePlaybackHistory;
    _onPersistenceFocusChanged ??= onFocusChanged;
  }

  void configurePersistence({required bool enabled}) {
    _persistenceEnabled = enabled;
    if (!enabled) cancelScheduledPersistence();
  }

  Future<void> loadPersistedState() async {
    final persistedSessions = await databaseRepository.loadAllSessions();
    if (persistedSessions.isEmpty) return;
    final legacyOrder = await AppPreferences.readJson<List<String>>(
      'session_order_v1',
      (value) => (value as List<dynamic>).cast<String>(),
    );
    final restoredSessions = <PlaybackSession>[];
    final recordProgress = _recordPlaybackProgress?.call() ?? true;

    for (final item in persistedSessions) {
      final customQueueTracks = item.customQueueTracks == null
          ? null
          : List<MusicTrack>.unmodifiable(item.customQueueTracks!);
      MusicTrack? track;
      if (customQueueTracks != null && customQueueTracks.isNotEmpty) {
        track = customQueueTracks.firstWhere(
          (candidate) =>
              PathMatcher.equalsNormalized(candidate.path, item.trackPath),
          orElse: () => customQueueTracks.first,
        );
      }
      track ??= _persistedTrackResolver?.call(item.trackPath);
      if (track == null && item.playbackQueue == null) continue;

      final loopMode =
          SessionLoopMode.values[item.loopModeIndex.clamp(
            0,
            SessionLoopMode.values.length - 1,
          )];
      final restoredPosition = Duration(
        milliseconds: max(0, recordProgress ? item.positionMs : 0),
      );
      final session = PlaybackSession(
        id: item.id,
        currentTrackPath: track?.path ?? '',
        loopMode: loopMode,
        nonSingleLoopMode: loopMode == SessionLoopMode.single
            ? SessionLoopMode.folderSequential
            : loopMode,
        volume: item.volume.clamp(0.0, maxSessionVolume),
        createdAt: item.createdAtMs == null
            ? DateTime.now()
            : DateTime.fromMillisecondsSinceEpoch(item.createdAtMs!),
        state: PlayerState(false, ProcessingState.idle),
        customQueueTracks: customQueueTracks,
        playbackQueue: item.playbackQueue,
        currentQueueIndex: recordProgress ? item.currentQueueIndex : 0,
      );
      session
        ..lastKnownPosition = restoredPosition
        ..setOptimisticDuration(Duration(milliseconds: item.durationMs))
        ..lastPersistedPositionBucket = restoredPosition.inSeconds ~/ 5
        ..channelSwapEnabled = item.channelSwapEnabled
        ..speed = nearestPlaybackSpeed(item.speed)
        ..audioEffects = item.audioEffects;
      service.sessions[session.id] = session;
      observeSession(session);
      restoredSessions.add(session);
    }

    final restoredIds = restoredSessions.map((session) => session.id).toSet();
    final orderedIds = (legacyOrder ?? const <String>[])
        .where(restoredIds.contains)
        .toList(growable: true);
    for (final session in restoredSessions) {
      if (!orderedIds.contains(session.id)) orderedIds.add(session.id);
    }
    service.sessionOrder
      ..clear()
      ..addAll(orderedIds);
    service.markActiveSessionsDirty();
    final focusedSessionId = orderedIds.firstOrNull;
    _onPersistenceFocusChanged?.call(focusedSessionId);
    await _restoreRuntime?.call(
      restoredSessions,
      focusedSessionId: focusedSessionId,
    );
  }

  Future<void> resetForBackupRestore() async {
    cancelScheduledPersistence();
    final removedSessions = service.sessions.values.toList(growable: false);
    service.sessions.clear();
    service.sessionOrder.clear();
    service.markActiveSessionsDirty();
    for (final session in removedSessions) {
      session.isPlaybackStarting = false;
      session.dispose();
    }
    try {
      await nativeRepository.clearAll();
    } catch (error, stackTrace) {
      AppLogService.error(
        'playback_backup_restore_clear_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
    clearDeferredVolumeReloads();
    clearRetargetedPaths();
    _onPersistenceFocusChanged?.call(null);
  }

  PersistedSession _persistedSessionSnapshot(
    PlaybackSession session, {
    required int sortOrder,
    required DateTime now,
    List<MusicTrack>? tracksToUpdate,
  }) {
    final positionMs = max(
      0,
      max(
        session.position.inMilliseconds,
        session.lastKnownPosition.inMilliseconds,
      ),
    );
    final position = Duration(milliseconds: positionMs);
    final track = _persistedTrackResolver?.call(session.currentTrackPath);
    if (tracksToUpdate != null &&
        track != null &&
        (track.lastPlayedPosition.inSeconds ~/ 5 != position.inSeconds ~/ 5 ||
            session.state.playing)) {
      final updated = _updatePlaybackHistory?.call(
        trackPath: track.path,
        position: position,
        now: now,
        updatePlayedAt: session.state.playing,
      );
      if (updated != null) tracksToUpdate.add(updated);
    }
    return PersistedSession(
      id: session.id,
      trackPath: session.currentTrackPath,
      loopModeIndex: session.loopMode.index,
      volume: session.volume,
      speed: session.speed,
      positionMs: positionMs,
      durationMs: session.duration?.inMilliseconds ?? 0,
      customQueueTracks: session.customQueueTracks,
      playbackQueue: session.playbackQueue,
      currentQueueIndex: session.currentQueueIndex,
      channelSwapEnabled: session.channelSwapEnabled,
      audioEffects: session.audioEffects,
      createdAtMs: session.createdAt.millisecondsSinceEpoch,
      updatedAtMs: now.millisecondsSinceEpoch,
      lastPlayedAtMs: session.state.playing ? now.millisecondsSinceEpoch : null,
      sortOrder: sortOrder,
    );
  }

  Future<void> _enqueueSessionPersistence(Future<void> Function() persist) {
    final previous = _sessionPersistenceTail;
    final result = previous == null
        ? Future<void>.sync(persist)
        : previous.then((_) => persist());
    _sessionPersistenceTail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        AppLogService.error(
          'playback_session_persistence_failed',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
    return result;
  }

  Future<void> savePersistedState() {
    if (!_persistenceEnabled) return Future<void>.value();
    _savePlaybackStateTimer?.cancel();
    _savePlaybackStateTimer = null;
    _pendingPlaybackStateSessionIds.clear();
    return _enqueueSessionPersistence(_savePersistedStateNow);
  }

  Future<void> _savePersistedStateNow() async {
    if (!_persistenceEnabled) return;
    final ordered = service.sessionOrder
        .map((id) => service.sessions[id])
        .whereType<PlaybackSession>()
        .toList(growable: false);
    final tracksToUpdate = <MusicTrack>[];
    final now = DateTime.now();
    final payload = ordered
        .asMap()
        .entries
        .map((entry) {
          return _persistedSessionSnapshot(
            entry.value,
            sortOrder: entry.key,
            now: now,
            tracksToUpdate: tracksToUpdate,
          );
        })
        .toList(growable: false);
    if (tracksToUpdate.isNotEmpty) {
      await databaseRepository.upsertTracks(tracksToUpdate);
    }
    await databaseRepository.saveAllSessions(payload);
  }

  Future<void> _savePendingPlaybackStates() async {
    if (!_persistenceEnabled || _pendingPlaybackStateSessionIds.isEmpty) {
      return;
    }
    final sessionIds = Set<String>.of(_pendingPlaybackStateSessionIds);
    _pendingPlaybackStateSessionIds.removeAll(sessionIds);
    final now = DateTime.now();
    final tracksToUpdate = <MusicTrack>[];
    final orderedIds = service.sessionOrder;
    for (final sessionId in sessionIds) {
      final session = service.sessions[sessionId];
      if (session == null) continue;
      final sortOrder = orderedIds.indexOf(sessionId);
      await databaseRepository.upsertSessionPlaybackState(
        _persistedSessionSnapshot(
          session,
          sortOrder: sortOrder < 0 ? orderedIds.length : sortOrder,
          now: now,
          tracksToUpdate: tracksToUpdate,
        ),
      );
    }
    if (tracksToUpdate.isNotEmpty) {
      await databaseRepository.upsertTracks(tracksToUpdate);
    }
  }

  Future<void> saveSessionOrder() async {
    if (!_persistenceEnabled) return;
    await databaseRepository.updateSessionOrder(
      service.sessionOrder.toList(growable: false),
    );
    await AppPreferences.remove('session_order_v1');
  }

  void scheduleSessionStatePersistence({
    Duration delay = const Duration(milliseconds: 220),
  }) {
    if (!_persistenceEnabled) return;
    _savePlaybackStateTimer?.cancel();
    _savePlaybackStateTimer = null;
    _pendingPlaybackStateSessionIds.clear();
    service.saveSessionStateTimer?.cancel();
    service.saveSessionStateTimer = Timer(delay, () {
      service.saveSessionStateTimer = null;
      unawaited(savePersistedState());
    });
  }

  void _scheduleSessionPlaybackStatePersistence(
    String sessionId, {
    Duration delay = const Duration(milliseconds: 800),
  }) {
    if (!_persistenceEnabled || service.saveSessionStateTimer != null) return;
    _pendingPlaybackStateSessionIds.add(sessionId);
    _savePlaybackStateTimer?.cancel();
    _savePlaybackStateTimer = Timer(delay, () {
      _savePlaybackStateTimer = null;
      unawaited(_enqueueSessionPersistence(_savePendingPlaybackStates));
    });
  }

  void scheduleSessionOrderPersistence({
    Duration delay = const Duration(milliseconds: 180),
  }) {
    if (!_persistenceEnabled) return;
    service.saveSessionOrderTimer?.cancel();
    service.saveSessionOrderTimer = Timer(delay, () {
      service.saveSessionOrderTimer = null;
      unawaited(saveSessionOrder());
    });
  }

  Future<void> flushSessionStatePersistence() async {
    service.saveSessionStateTimer?.cancel();
    service.saveSessionStateTimer = null;
    await savePersistedState();
  }

  void cancelScheduledPersistence() {
    _savePlaybackStateTimer?.cancel();
    _savePlaybackStateTimer = null;
    _pendingPlaybackStateSessionIds.clear();
    service.saveSessionStateTimer?.cancel();
    service.saveSessionStateTimer = null;
    service.saveSessionOrderTimer?.cancel();
    service.saveSessionOrderTimer = null;
  }

  void attachSessionRuntime({
    required void Function(PlaybackSession session) onSessionRegistered,
    void Function(List<PlaybackSession> sessions)? onSessionsRemoved,
    required void Function() onSessionsReordered,
    required void Function() onSessionStateChanged,
    void Function()? onRuntimeStateChanged,
    void Function(PlaybackSession session, Duration position)?
    onSessionPositionChanged,
    void Function(String sessionId)? onSessionCompleted,
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

  void registerSession(PlaybackSession session) {
    service.registerSession(session);
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
      if (!service.sessions.containsKey(session.id)) return;

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
        _onSessionCompleted?.call(session.id);
      }
    });
    session.subscriptions.add(stateSub);

    final positionSub = session.positionStream.listen((position) {
      if (!service.sessions.containsKey(session.id)) return;
      session.lastKnownPosition = position;
      final bucket = position.inSeconds ~/ 5;
      if (bucket != session.lastPersistedPositionBucket) {
        session.lastPersistedPositionBucket = bucket;
        _scheduleSessionPlaybackStatePersistence(session.id);
      }
      _onSessionPositionChanged?.call(session, position);
    });
    session.subscriptions.add(positionSub);

    final durationSub = session.durationStream.listen((_) {
      if (!service.sessions.containsKey(session.id)) return;
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
      loopMode: SessionLoopMode.folderSequential,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
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
    final version = service.sessionStateVersion;
    service.reorderSessions(oldIndex, newIndex);
    if (service.sessionStateVersion == version) return;
    _onSessionsReordered?.call();
  }

  Future<void> pauseAllSessions() async {
    for (final session in service.sessions.values) {
      session.setOptimisticState(playing: false);
      session.isLoading = false;
      session.isPlaybackStarting = false;
    }
    _onRuntimeStateChanged?.call();
    _onSessionStateChanged?.call();
    await nativeRepository.pauseAll();
    scheduleSessionStatePersistence();
  }

  Future<void> removeSession(String sessionId) {
    return removeSessions(<String>[sessionId]);
  }

  Future<void> removeSessions(
    Iterable<String> sessionIds, {
    bool persist = true,
    bool notify = true,
  }) async {
    final removedSessions = service.removeSessions(sessionIds);
    if (removedSessions.isEmpty) return;
    for (final session in removedSessions) {
      session.isPlaybackStarting = false;
      _deferredVolumeReloadSessionIds.remove(session.id);
    }
    _onSessionsRemoved?.call(removedSessions);
    if (notify) _onSessionStateChanged?.call();
    await Future.wait(
      removedSessions.map((session) async {
        await nativeRepository.removeSession(session.id);
        session.dispose();
      }),
    );
    _onRuntimeStateChanged?.call();
    if (persist) {
      _scheduleNewSessionPersistence(respectConfiguration: false);
    }
  }

  Future<void> clearAllSessions() async {
    final removedSessions = service.removeSessions(
      service.sessions.keys.toList(growable: false),
    );
    if (removedSessions.isEmpty) return;
    for (final session in removedSessions) {
      session.isPlaybackStarting = false;
      _deferredVolumeReloadSessionIds.remove(session.id);
    }
    _onSessionsRemoved?.call(removedSessions);
    _onSessionStateChanged?.call();
    await nativeRepository.clearAll();
    for (final session in removedSessions) {
      session.dispose();
    }
    _onRuntimeStateChanged?.call();
    _scheduleNewSessionPersistence(respectConfiguration: false);
  }

  Future<void> seekSession(String sessionId, Duration position) async {
    final session = service.sessions[sessionId];
    if (session == null ||
        session.isDisposed ||
        !identical(service.sessions[session.id], session)) {
      return;
    }
    session.setOptimisticPosition(position);
    session.lastPersistedPositionBucket = position.inSeconds ~/ 5;
    _onSessionPositionChanged?.call(session, position);
    await nativeRepository.seek(session.id, position);
  }

  Future<void> toggleSessionPlayPause(String sessionId) async {
    final session = service.sessions[sessionId];
    if (session == null || session.currentTrackPath.isEmpty) return;
    if (session.playbackError != null || session.isLoading) {
      await _prepareSession?.call(session, nextPath: session.currentTrackPath);
      return;
    }
    if (session.effectivePlaying) {
      await _pauseSession?.call(session);
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
    await _startSession?.call(session, shouldStartTriggerCountdown: true);
  }

  Future<void> switchSessionTrack(String sessionId, String newPath) async {
    final session = service.sessions[sessionId];
    if (session == null) return;
    await _prepareSession?.call(
      session,
      nextPath: newPath,
      forceStartAtZero: true,
      showLoading: false,
    );
    scheduleSessionStatePersistence();
  }

  Future<void> switchSessionQueueTrack(String sessionId, int queueIndex) async {
    final session = service.sessions[sessionId];
    if (session == null) return;
    final tracks = session.isPlaybackQueue
        ? session.playbackQueue!.expandedTracks
        : session.customQueueTracks;
    if (tracks == null || tracks.isEmpty) return;
    final index = queueIndex.clamp(0, tracks.length - 1);
    await _prepareSession?.call(
      session,
      nextPath: tracks[index].path,
      forceStartAtZero: true,
      showLoading: false,
      targetQueueIndex: index,
    );
    scheduleSessionStatePersistence();
  }

  Future<void> seekSessionToNext(String sessionId) async {
    final session = service.sessions[sessionId];
    final target = session == null
        ? null
        : _resolveAdvance?.call(session, forward: true);
    if (session == null || target == null) return;
    await _prepareSession?.call(
      session,
      nextPath: target.path,
      forceStartAtZero: true,
      showLoading: false,
      targetQueueIndex: target.queueIndex,
    );
  }

  Future<void> seekSessionToPrev(String sessionId) async {
    final session = service.sessions[sessionId];
    if (session == null) return;
    if (!session.isPlaybackQueue && session.position.inSeconds > 3) {
      await seekSession(sessionId, Duration.zero);
      return;
    }
    final target = _resolveAdvance?.call(session, forward: false);
    if (target == null) return;
    await _prepareSession?.call(
      session,
      nextPath: target.path,
      forceStartAtZero: true,
      showLoading: false,
      targetQueueIndex: target.queueIndex,
    );
  }

  bool hasSessionAdjacentTrack(String sessionId, {required bool forward}) {
    final session = service.sessions[sessionId];
    return session != null &&
        !session.isLoading &&
        (_hasAdjacent?.call(session, forward: forward) ?? false);
  }

  Future<void> setSessionLoopMode(
    String sessionId,
    SessionLoopMode mode,
  ) async {
    final session = service.sessions[sessionId];
    if (session == null) return;
    session.loopMode = mode;
    if (mode != SessionLoopMode.single) {
      session.nonSingleLoopMode = mode;
    }
    service.markActiveSessionsDirty();
    _onSessionSettingsChanged?.call();
    final synchronize = _synchronizeLoopMode;
    if (synchronize != null) {
      unawaited(synchronize(session, mode));
    }
    scheduleSessionStatePersistence();
  }

  Future<void> toggleSessionSingleLoop(String sessionId) async {
    final session = service.sessions[sessionId];
    if (session == null) return;
    if (session.loopMode == SessionLoopMode.single) {
      await setSessionLoopMode(sessionId, session.nonSingleLoopMode);
      return;
    }
    session.nonSingleLoopMode = session.loopMode;
    await setSessionLoopMode(sessionId, SessionLoopMode.single);
  }

  Future<void> toggleSessionShuffle(String sessionId) async {
    final session = service.sessions[sessionId];
    if (session == null || session.loopMode == SessionLoopMode.single) return;
    final nextMode = session.loopMode.isShuffle
        ? (session.loopMode.isCrossFolder
              ? SessionLoopMode.crossSequential
              : SessionLoopMode.folderSequential)
        : (session.loopMode.isCrossFolder
              ? SessionLoopMode.crossRandom
              : SessionLoopMode.folderRandom);
    await setSessionLoopMode(sessionId, nextMode);
  }

  Future<void> toggleSessionCrossFolder(String sessionId) async {
    final session = service.sessions[sessionId];
    if (session == null || session.loopMode == SessionLoopMode.single) return;
    final nextMode = session.loopMode.isCrossFolder
        ? (session.loopMode.isShuffle
              ? SessionLoopMode.folderRandom
              : SessionLoopMode.folderSequential)
        : (session.loopMode.isShuffle
              ? SessionLoopMode.crossRandom
              : SessionLoopMode.crossSequential);
    await setSessionLoopMode(sessionId, nextMode);
  }

  Future<void> setSessionChannelSwap(String sessionId, bool enabled) {
    final session = service.sessions[sessionId];
    if (session == null) return Future<void>.value();
    if (session.channelSwapEnabled == enabled) {
      return session.audioEffectsSyncFuture ?? flushSessionStatePersistence();
    }
    return _queueSessionAudioEffectsSync(
      session,
      audioEffects: session.audioEffects,
      channelSwapEnabled: enabled,
      errorLabel: 'setSessionChannelSwap',
    );
  }

  Future<void> setSessionSkipSilence(String sessionId, bool enabled) {
    return _updateSessionAudioEffects(
      sessionId,
      (state) => state.copyWith(skipSilenceEnabled: enabled),
      errorLabel: 'setSessionSkipSilence',
    );
  }

  Future<void> setSessionNoiseReduction(String sessionId, bool enabled) {
    return _updateSessionAudioEffects(
      sessionId,
      (state) => state.copyWith(noiseReductionEnabled: enabled),
      errorLabel: 'setSessionNoiseReduction',
    );
  }

  Future<void> setSessionVolumeNormalization(String sessionId, bool enabled) {
    return _updateSessionAudioEffects(
      sessionId,
      (state) => state.copyWith(volumeNormalizationEnabled: enabled),
      errorLabel: 'setSessionVolumeNormalization',
    );
  }

  Future<void> setSessionPanning(String sessionId, double panning) {
    return _updateSessionAudioEffects(
      sessionId,
      (state) => state.copyWith(panning: panning),
      errorLabel: 'setSessionPanning',
    );
  }

  Future<void> setSessionEqEnabled(String sessionId, bool enabled) {
    return _updateSessionAudioEffects(
      sessionId,
      (state) => state.copyWith(eqEnabled: enabled),
      errorLabel: 'setSessionEqEnabled',
    );
  }

  Future<void> setSessionEqBandLevel(
    String sessionId,
    int frequencyHz,
    double gainDb,
  ) {
    return _updateSessionAudioEffects(sessionId, (state) {
      final levels = Map<int, double>.of(state.eqBandLevels);
      levels[frequencyHz] = _clampEqGainForSession(sessionId, gainDb);
      return state.copyWith(
        eqEnabled: true,
        eqPresetId: null,
        eqBandLevels: levels,
      );
    }, errorLabel: 'setSessionEqBandLevel');
  }

  Future<void> applySessionEqPreset(String sessionId, EqPreset preset) {
    return _updateSessionAudioEffects(sessionId, (state) {
      final isFlatPreset = preset.bandLevels.isEmpty;
      return state.copyWith(
        eqEnabled: isFlatPreset ? state.eqEnabled : true,
        eqPresetId: preset.id,
        eqBandLevels: _mapPresetToSessionBands(sessionId, preset),
      );
    }, errorLabel: 'applySessionEqPreset');
  }

  Future<NativeResult<NativePlaybackSnapshot>> _syncSessionAudioEffects(
    PlaybackSession session,
    NativeAudioEffects audioEffects,
  ) async {
    final shouldKeepPlaying = session.effectivePlaying;
    final loadedPath = session.loadedPath;
    final needsPrepare =
        loadedPath == null ||
        !PathMatcher.equalsNormalized(loadedPath, session.currentTrackPath);
    if (needsPrepare) {
      final prepare = _prepareSession;
      if (prepare == null) {
        return const NativeFailure('Playback session preparation unavailable.');
      }
      await prepare(
        session,
        nextPath: session.currentTrackPath,
        autoPlay: shouldKeepPlaying,
      );
      if (!service.sessions.containsKey(session.id)) {
        return const NativeFailure(
          'Session removed before audio effects sync.',
        );
      }
      if (session.loadedPath == null) {
        return const NativeFailure(
          'Failed to prepare session before audio effects sync.',
        );
      }
    }
    var response = await nativeRepository.setAudioEffects(
      session.id,
      audioEffects,
    );
    if (response.isOk ||
        needsPrepare ||
        !service.sessions.containsKey(session.id)) {
      return response;
    }

    session.loadedPath = null;
    final prepare = _prepareSession;
    if (prepare == null) return response;
    await prepare(
      session,
      nextPath: session.currentTrackPath,
      autoPlay: shouldKeepPlaying,
      showLoading: false,
    );
    if (session.loadedPath == null ||
        !service.sessions.containsKey(session.id)) {
      return response;
    }
    response = await nativeRepository.setAudioEffects(session.id, audioEffects);
    return response;
  }

  Future<void> _updateSessionAudioEffects(
    String sessionId,
    AudioEffectsState Function(AudioEffectsState state) update, {
    required String errorLabel,
  }) {
    final session = service.sessions[sessionId];
    if (session == null) return Future<void>.value();
    return _queueSessionAudioEffectsSync(
      session,
      audioEffects: update(session.audioEffects),
      channelSwapEnabled: session.channelSwapEnabled,
      errorLabel: errorLabel,
    );
  }

  Future<void> _queueSessionAudioEffectsSync(
    PlaybackSession session, {
    required AudioEffectsState audioEffects,
    required bool channelSwapEnabled,
    required String errorLabel,
  }) {
    if (!session.hasPendingAudioEffectsSync) {
      session.confirmedNativeAudioEffects = NativeAudioEffects(
        state: session.audioEffects,
        channelSwapEnabled: session.channelSwapEnabled,
      );
    }
    session
      ..pendingNativeAudioEffects = NativeAudioEffects(
        state: audioEffects,
        channelSwapEnabled: channelSwapEnabled,
      )
      ..audioEffects = audioEffects
      ..channelSwapEnabled = channelSwapEnabled
      ..audioEffectsSyncRevision += 1
      ..audioEffectsSyncErrorLabel = errorLabel;
    service.markActiveSessionsDirty();
    _onSessionStateChanged?.call();

    final activeDrain = session.audioEffectsSyncFuture;
    if (activeDrain != null) return activeDrain;

    final completer = Completer<void>();
    session.audioEffectsSyncFuture = completer.future;
    unawaited(() async {
      try {
        await _drainSessionAudioEffectsSync(session);
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        if (identical(session.audioEffectsSyncFuture, completer.future)) {
          session.audioEffectsSyncFuture = null;
        }
      }
    }());
    return completer.future;
  }

  Future<void> _drainSessionAudioEffectsSync(PlaybackSession session) async {
    while (identical(service.sessions[session.id], session)) {
      final revision = session.audioEffectsSyncRevision;
      final desiredAudioEffects = session.pendingNativeAudioEffects;
      if (desiredAudioEffects == null) return;
      final errorLabel = session.audioEffectsSyncErrorLabel;

      final response = await _syncSessionAudioEffects(
        session,
        desiredAudioEffects,
      );
      if (!identical(service.sessions[session.id], session)) return;

      if (response.isOk) {
        final snapshot = response.valueOrNull;
        session.confirmedNativeAudioEffects = NativeAudioEffects(
          state: _resolvedAudioEffects(
            snapshot,
            fallbackAudioEffects: desiredAudioEffects.state,
          ),
          channelSwapEnabled: snapshot?.hasChannelSwapPayload ?? false
              ? snapshot!.channelSwapEnabled
              : desiredAudioEffects.channelSwapEnabled,
        );
        if (snapshot != null) session.eqCapabilities = snapshot.eqCapabilities;
      } else {
        AppLogService.warning(
          'PlaybackFacade.$errorLabel error: '
          '${response.errorOrNull}',
        );
      }

      if (revision != session.audioEffectsSyncRevision) continue;
      final confirmed = session.confirmedNativeAudioEffects!;
      session
        ..audioEffects = confirmed.state
        ..channelSwapEnabled = confirmed.channelSwapEnabled;
      service.markActiveSessionsDirty();
      _onSessionStateChanged?.call();

      await flushSessionStatePersistence();
      if (!identical(service.sessions[session.id], session)) return;
      if (revision != session.audioEffectsSyncRevision) continue;
      session.pendingNativeAudioEffects = null;
      return;
    }
  }

  AudioEffectsState _resolvedAudioEffects(
    NativePlaybackSnapshot? snapshot, {
    required AudioEffectsState fallbackAudioEffects,
  }) {
    if (snapshot == null || !snapshot.hasAudioEffectsPayload) {
      return fallbackAudioEffects;
    }
    final shouldKeepFallback =
        fallbackAudioEffects != AudioEffectsState.flat &&
        snapshot.audioEffects == AudioEffectsState.flat;
    return shouldKeepFallback ? fallbackAudioEffects : snapshot.audioEffects;
  }

  Map<int, double> _mapPresetToSessionBands(String sessionId, EqPreset preset) {
    final session = service.sessions[sessionId];
    final bands = session?.eqCapabilities.bands ?? const <EqBandInfo>[];
    if (bands.isEmpty) {
      return Map<int, double>.unmodifiable(preset.bandLevels);
    }
    final mapped = <int, double>{};
    for (final presetEntry in preset.bandLevels.entries) {
      final targetBand = bands.reduce((best, candidate) {
        final bestDistance = (best.frequencyHz - presetEntry.key).abs();
        final candidateDistance = (candidate.frequencyHz - presetEntry.key)
            .abs();
        return candidateDistance < bestDistance ? candidate : best;
      });
      mapped[targetBand.frequencyHz] = _clampEqGainForSession(
        sessionId,
        (mapped[targetBand.frequencyHz] ?? 0) + presetEntry.value,
      );
    }
    return Map<int, double>.unmodifiable(mapped);
  }

  double _clampEqGainForSession(String sessionId, double gainDb) {
    final capabilities = service.sessions[sessionId]?.eqCapabilities;
    if (capabilities == null || !capabilities.supported) {
      return gainDb.clamp(-12.0, 12.0);
    }
    return gainDb.clamp(capabilities.minGainDb, capabilities.maxGainDb);
  }

  Future<void> setSessionVolume(
    String sessionId,
    double volume, {
    bool persist = true,
    bool notify = true,
  }) async {
    final session = service.sessions[sessionId];
    if (session == null ||
        session.isDisposed ||
        !identical(service.sessions[session.id], session)) {
      return;
    }
    final nextVolume = volume.clamp(0.0, maxSessionVolume);
    final hasDeferredReload = _deferredVolumeReloadSessionIds.contains(
      session.id,
    );
    if ((session.volume - nextVolume).abs() < 0.001) {
      if (persist && hasDeferredReload) {
        await nativeRepository.setVolume(session.id, session.volume);
        if (!_isCurrentSession(session)) return;
        _deferredVolumeReloadSessionIds.remove(session.id);
      }
      if (persist) await flushSessionStatePersistence();
      return;
    }
    session.volume = nextVolume;
    if (persist) {
      _deferredVolumeReloadSessionIds.remove(session.id);
    } else {
      _deferredVolumeReloadSessionIds.add(session.id);
    }
    if (notify) {
      service.markActiveSessionsDirty();
      _onSessionStateChanged?.call();
    }
    await nativeRepository.setVolume(
      session.id,
      session.volume,
      reloadSource: persist,
    );
    if (!_isCurrentSession(session)) return;
    if (persist) await flushSessionStatePersistence();
  }

  Future<void> setSessionSpeed(
    String sessionId,
    double speed, {
    bool persist = true,
    bool notify = true,
  }) async {
    final session = service.sessions[sessionId];
    if (session == null ||
        session.isDisposed ||
        !identical(service.sessions[session.id], session)) {
      return;
    }
    final nextSpeed = nearestPlaybackSpeed(speed);
    if ((session.speed - nextSpeed).abs() < 0.001) {
      if (persist) await flushSessionStatePersistence();
      return;
    }
    final previous = session.speed;
    session.speed = nextSpeed;
    service.markActiveSessionsDirty();
    if (notify) _onSessionSettingsChanged?.call();
    final response = await nativeRepository.setSpeed(session.id, nextSpeed);
    if (!_isCurrentSession(session)) return;
    if (response.isFailure) {
      session.speed = previous;
      service.markActiveSessionsDirty();
      AppLogService.warning(
        'PlaybackFacade.setSessionSpeed error: ${response.errorOrNull}',
      );
      if (notify) _onSessionSettingsChanged?.call();
      return;
    }
    if (persist) await flushSessionStatePersistence();
  }

  bool _isCurrentSession(PlaybackSession? session) {
    return session != null &&
        !session.isDisposed &&
        identical(service.sessions[session.id], session);
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

  Future<void> addTrackToPlaybackQueue(String sessionId, MusicTrack track) {
    return _addPlaybackQueueEntry(
      sessionId,
      PlaybackQueueEntry(
        id: _nextQueueEntryId(),
        kind: PlaybackQueueEntryKind.track,
        title: track.displayName,
        tracks: <MusicTrack>[track],
      ),
    );
  }

  Future<void> addWorkToPlaybackQueue(
    String sessionId, {
    required String title,
    required List<MusicTrack> tracks,
    String? workRootPath,
  }) {
    if (tracks.isEmpty) return Future<void>.value();
    return _addPlaybackQueueEntry(
      sessionId,
      PlaybackQueueEntry(
        id: _nextQueueEntryId(),
        kind: PlaybackQueueEntryKind.work,
        title: title,
        tracks: List<MusicTrack>.unmodifiable(tracks),
        workRootPath: workRootPath,
      ),
    );
  }

  Future<void> _addPlaybackQueueEntry(
    String sessionId,
    PlaybackQueueEntry entry,
  ) async {
    final session = service.sessions[sessionId];
    final queue = session?.playbackQueue;
    if (session == null || queue == null) return;
    final wasEmpty = queue.expandedTracks.isEmpty;
    session.playbackQueue = queue.copyWith(
      entries: List<PlaybackQueueEntry>.unmodifiable(<PlaybackQueueEntry>[
        ...queue.entries,
        entry,
      ]),
    );
    service.markActiveSessionsDirty();
    _onSessionStateChanged?.call();
    _scheduleNewSessionPersistence();
    await _synchronizePlaybackQueueSession?.call(
      session,
      selectFirst: wasEmpty,
    );
    service.markActiveSessionsDirty();
    _onSessionStateChanged?.call();
    publishSessionActivated(session.id);
  }

  Future<void> removePlaybackQueueEntry(
    String sessionId,
    String entryId,
  ) async {
    final session = service.sessions[sessionId];
    final queue = session?.playbackQueue;
    if (session == null || queue == null) return;
    final entries = queue.entries
        .where((entry) => entry.id != entryId)
        .toList(growable: false);
    if (entries.length == queue.entries.length) return;
    session.playbackQueue = queue.copyWith(entries: entries);
    await _synchronizePlaybackQueueSession?.call(session, selectFirst: false);
    service.markActiveSessionsDirty();
    _onSessionStateChanged?.call();
    _scheduleNewSessionPersistence();
  }

  Future<void> reorderPlaybackQueueEntry(
    String sessionId,
    int oldIndex,
    int newIndex,
  ) async {
    final session = service.sessions[sessionId];
    final queue = session?.playbackQueue;
    if (session == null || queue == null) return;
    if (oldIndex < newIndex) newIndex -= 1;
    final entries = queue.entries.toList();
    if (oldIndex < 0 ||
        oldIndex >= entries.length ||
        newIndex < 0 ||
        newIndex > entries.length) {
      return;
    }
    final item = entries.removeAt(oldIndex);
    entries.insert(newIndex, item);
    session.playbackQueue = queue.copyWith(entries: entries);
    await _synchronizePlaybackQueueSession?.call(session, selectFirst: false);
    service.markActiveSessionsDirty();
    _onSessionStateChanged?.call();
    await databaseRepository.updatePlaybackQueueEntryOrder(
      session.id,
      entries.map((entry) => entry.id).toList(growable: false),
    );
  }

  String _nextQueueEntryId() =>
      'queue_entry_${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(1 << 20)}';

  bool renamePlaybackQueue(String sessionId, String name) {
    final session = service.sessions[sessionId];
    final queue = session?.playbackQueue;
    final trimmed = name.trim();
    if (session == null || queue == null || trimmed.isEmpty) return false;
    session.playbackQueue = queue.copyWith(name: trimmed);
    service.markActiveSessionsDirty();
    scheduleSessionStatePersistence();
    _onSessionStateChanged?.call();
    return true;
  }

  bool setPlaybackQueueColorValue(String sessionId, int? colorValue) {
    final session = service.sessions[sessionId];
    final queue = session?.playbackQueue;
    if (session == null || queue == null) return false;
    session.playbackQueue = queue.copyWith(
      colorValue: colorValue,
      clearColor: colorValue == null,
    );
    service.markActiveSessionsDirty();
    scheduleSessionStatePersistence();
    _onSessionStateChanged?.call();
    return true;
  }

  bool replaceSessionTrackSnapshots(MusicTrack updatedTrack) {
    var changed = false;
    for (final session in service.sessions.values) {
      final customQueueTracks = session.customQueueTracks;
      if (customQueueTracks != null) {
        var customQueueChanged = false;
        final tracks = customQueueTracks
            .map((track) {
              if (!PathMatcher.equalsNormalized(
                track.path,
                updatedTrack.path,
              )) {
                return track;
              }
              customQueueChanged = true;
              return updatedTrack;
            })
            .toList(growable: false);
        if (customQueueChanged) {
          session.customQueueTracks = List<MusicTrack>.unmodifiable(tracks);
          changed = true;
        }
      }
      final queue = session.playbackQueue;
      if (queue == null) continue;
      var queueChanged = false;
      final entries = queue.entries
          .map((entry) {
            var entryChanged = false;
            final tracks = entry.tracks
                .map((track) {
                  if (!PathMatcher.equalsNormalized(
                    track.path,
                    updatedTrack.path,
                  )) {
                    return track;
                  }
                  entryChanged = true;
                  queueChanged = true;
                  return updatedTrack;
                })
                .toList(growable: false);
            if (!entryChanged) return entry;
            return PlaybackQueueEntry(
              id: entry.id,
              kind: entry.kind,
              title: entry.title,
              tracks: List<MusicTrack>.unmodifiable(tracks),
              workRootPath: entry.workRootPath,
            );
          })
          .toList(growable: false);
      if (!queueChanged) continue;
      session.playbackQueue = queue.copyWith(
        entries: List.unmodifiable(entries),
      );
      changed = true;
    }
    return changed;
  }

  void rememberRetargetedPath(String oldPath, String newPath) {
    final normalizedOldPath = PathMatcher.normalize(oldPath);
    final normalizedNewPath = PathMatcher.normalize(newPath);
    if (PathMatcher.equalsNormalized(normalizedOldPath, normalizedNewPath)) {
      return;
    }
    _retargetedPathAliases[normalizedOldPath] = normalizedNewPath;
  }

  String resolveRetargetedPath(String value) {
    if (value.isEmpty || _retargetedPathAliases.isEmpty) {
      return PathMatcher.normalize(value);
    }
    var current = PathMatcher.normalize(value);
    final seen = <String>{current};
    while (true) {
      String? bestMatch;
      String? nextValue;
      for (final entry in _retargetedPathAliases.entries) {
        if (!PathMatcher.isWithinOrEqual(current, entry.key)) continue;
        if (bestMatch == null || entry.key.length > bestMatch.length) {
          bestMatch = entry.key;
          nextValue = entry.value;
        }
      }
      if (bestMatch == null || nextValue == null) return current;
      final resolved = PathMatcher.normalize(
        PathMatcher.replaceWithinOrEqual(current, bestMatch, nextValue),
      );
      if (PathMatcher.equalsNormalized(resolved, current) ||
          !seen.add(resolved)) {
        return resolved;
      }
      current = resolved;
    }
  }

  void clearRetargetedPaths() => _retargetedPathAliases.clear();

  Future<void> retargetPath(String oldPath, String newPath) async {
    rememberRetargetedPath(oldPath, newPath);
    var changed = false;
    for (final session in service.sessions.values) {
      if (PathMatcher.isWithinOrEqual(session.currentTrackPath, oldPath)) {
        session.currentTrackPath = PathMatcher.replaceWithinOrEqual(
          session.currentTrackPath,
          oldPath,
          newPath,
        );
        changed = true;
      }
      final loadedPath = session.loadedPath;
      if (loadedPath != null &&
          PathMatcher.isWithinOrEqual(loadedPath, oldPath)) {
        session.loadedPath = PathMatcher.replaceWithinOrEqual(
          loadedPath,
          oldPath,
          newPath,
        );
        changed = true;
      }
    }
    if (!changed) return;
    service.markActiveSessionsDirty();
    final current = service.slice.state;
    service.syncSlice(
      activeSessions: service.activeSessions,
      playingSessionCount: service.playingSessionCount,
      focusedSessionId: current.focusedSessionId,
      multiThreadPlaybackEnabled: current.multiThreadPlaybackEnabled,
      coverGeneration: current.coverGeneration,
      isInitialized: current.isInitialized,
    );
    await savePersistedState();
  }

  Future<void> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  }) {
    return spawnSessionWithQueue(
      tracks,
      autoPlay: autoPlay,
      loopMode: loopMode,
    );
  }

  Future<void> spawnSession(MusicTrack track, {bool? autoPlay}) async {
    final matchingSessionIds = _matchingWorkSessionIds(track);
    if (matchingSessionIds.isNotEmpty) {
      await removeSessions(matchingSessionIds);
    }
    final session = createTrackSession(track);
    unawaited(
      _enqueueSessionPreparation(
        session,
        nextPath: track.path,
        autoPlay: autoPlay ?? _autoPlayAddedSessions(),
      ),
    );
    publishSessionActivated(session.id);
  }

  Future<void> spawnSessionWithQueue(
    List<MusicTrack> tracks, {
    int startIndex = 0,
    bool? autoPlay,
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
  }) async {
    if (tracks.isEmpty) return;
    final clampedStartIndex = startIndex.clamp(0, tracks.length - 1);
    final startTrack = tracks[clampedStartIndex];
    final matchingSessionIds = _matchingWorkSessionIds(startTrack);
    if (matchingSessionIds.isNotEmpty) {
      await removeSessions(matchingSessionIds);
    }
    final session = createTrackSession(
      startTrack,
      loopMode: loopMode,
      customQueueTracks: List<MusicTrack>.unmodifiable(tracks),
    );
    unawaited(
      _enqueueSessionPreparation(
        session,
        nextPath: startTrack.path,
        autoPlay: autoPlay ?? _autoPlayAddedSessions(),
      ),
    );
    publishSessionActivated(session.id);
  }

  List<String> _matchingWorkSessionIds(MusicTrack incomingTrack) {
    if (_allowDuplicateWorks()) return const <String>[];
    final incomingKey = _workKey(incomingTrack);
    return service.sessions.values
        .where((session) {
          final representative = _representativeTrack(session);
          return representative != null &&
              _workKey(representative) == incomingKey;
        })
        .map((session) => session.id)
        .toList(growable: false);
  }

  MusicTrack? _representativeTrack(PlaybackSession session) {
    final queueTracks = session.customQueueTracks;
    if (queueTracks != null && queueTracks.isNotEmpty) {
      return queueTracks.first;
    }
    return _persistedTrackResolver?.call(session.currentTrackPath);
  }

  String _workKey(MusicTrack track) {
    if (track.isSingle || track.groupKey == '__single_files__') {
      return 'track:${PathMatcher.normalize(track.path)}';
    }
    final groupKey = PathMatcher.normalize(track.groupKey);
    return groupKey.isEmpty
        ? 'track:${PathMatcher.normalize(track.path)}'
        : 'group:$groupKey';
  }

  Future<void> _enqueueSessionPreparation(
    PlaybackSession session, {
    required String nextPath,
    required bool autoPlay,
  }) {
    service.enqueueSessionPreparation(() async {
      if (!service.sessions.containsKey(session.id)) return;
      await _prepareSession?.call(
        session,
        nextPath: nextPath,
        autoPlay: autoPlay,
      );
    });
    return service.sessionPreparationQueue;
  }

  Future<void> dispose() async {
    cancelScheduledPersistence();
    final persistenceTail = _sessionPersistenceTail;
    if (persistenceTail != null) await persistenceTail;
    await _sessionActivations.close();
    await playbackCacheService.dispose();
    await nativeRepository.dispose();
    await service.dispose();
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
