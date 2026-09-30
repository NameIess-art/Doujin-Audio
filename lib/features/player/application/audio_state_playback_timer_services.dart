part of 'audio_state_services.dart';

class PlaybackSessionService {
  MusicTrack? Function(String path)? libraryTrackByPath;
  final Map<String, PlaybackSession> sessions = {};
  final List<String> sessionOrder = [];
  bool activeSessionsDirty = true;
  int sessionStateVersion = 0;
  List<PlaybackSession> activeSessionsCache = const [];
  final Map<String, Future<void>> _preparationTasks = {};
  Timer? saveSessionStateTimer;
  Timer? saveSessionOrderTimer;
  final aggregate = AudioStateSlice<PlaybackAggregateState>(
    const PlaybackAggregateState(),
    sync: true,
  );
  final catalog = AudioStateSlice<PlaybackCatalogState>(
    PlaybackCatalogState(),
    sync: true,
  );
  final Map<String, PlaybackSessionSnapshot> _snapshots = {};
  final Map<String, PlaybackSessionSnapshot> _directorySnapshots = {};
  final Map<String, PlaybackSessionSnapshot> _overlaySnapshots = {};
  final Map<String, AudioStateSlice<PlaybackSessionSnapshot?>> _sessionSlices =
      {};
  final Map<String, ({bool playing, bool audio, bool keepAlive})>
  _contributions = {};
  int _playingCount = 0;
  int _playingAudioCount = 0;
  int _keepAliveCount = 0;
  bool _catalogDirty = false;
  int coverGeneration = 0;

  List<PlaybackSession> get activeSessions {
    if (activeSessionsDirty) {
      final result = <PlaybackSession>[];
      final orderSet = sessionOrder.toSet();
      for (final id in sessionOrder) {
        final session = sessions[id];
        if (session != null) result.add(session);
      }
      for (final session in sessions.values) {
        if (!orderSet.contains(session.id)) result.add(session);
      }
      activeSessionsCache = List<PlaybackSession>.unmodifiable(result);
      activeSessionsDirty = false;
    }
    return activeSessionsCache;
  }

  PlaybackStateSliceData get state => PlaybackStateSliceData(
    activeSessions: activeSessions
        .map(PlaybackSessionSnapshot.fromRuntime)
        .toList(growable: false),
    playingSessionCount: _playingCount,
    focusedSessionId: aggregate.state.focusedSessionId,
    coverGeneration: coverGeneration,
    isInitialized: aggregate.state.isInitialized,
  );
  int get playingSessionCount => _playingCount;
  bool get hasPlayingAudioSession => _playingAudioCount > 0;
  bool get hasPlaybackToKeepAlive => _keepAliveCount > 0;
  Future<void> get pendingSessionPreparation =>
      Future.wait(_preparationTasks.values);

  Stream<PlaybackSessionSnapshot?> sessionStates(String id) async* {
    final slice = _sessionSlices.putIfAbsent(
      id,
      () =>
          AudioStateSlice<PlaybackSessionSnapshot?>(_snapshots[id], sync: true),
    );
    try {
      yield* slice.stream;
    } finally {
      if (!sessions.containsKey(id) &&
          !slice.hasListeners &&
          identical(_sessionSlices[id], slice)) {
        _sessionSlices.remove(id);
        unawaited(slice.dispose());
      }
    }
  }

  static bool _sameDirectory(
    PlaybackSessionSnapshot a,
    PlaybackSessionSnapshot b,
  ) =>
      a.currentTrackPath == b.currentTrackPath &&
      a.queueVersion == b.queueVersion &&
      a.isTemporary == b.isTemporary &&
      a.lastPlayedAt == b.lastPlayedAt &&
      a.createdAt == b.createdAt;

  static bool _showInOverlay(PlaybackSessionSnapshot s) =>
      s.currentTrackPath.isNotEmpty &&
      (s.isTemporary ||
          s.retainInNowPlaying ||
          (s.playbackRequested &&
              (s.isLoading ||
                  s.isPlaybackLoading ||
                  s.state.processing == PlaybackProcessingStatus.loading ||
                  s.state.processing == PlaybackProcessingStatus.buffering ||
                  s.state.processing == PlaybackProcessingStatus.ready)));

  void publishSession(PlaybackSession session) {
    if (session.isDisposed || !identical(sessions[session.id], session)) return;
    final id = session.id;
    final next = PlaybackSessionSnapshot.fromRuntime(session);
    _snapshots[id] = next;
    _sessionSlices[id]?.update(next);
    final directory = _directorySnapshots[id];
    if (directory == null || !_sameDirectory(directory, next)) {
      _directorySnapshots[id] = next;
      _catalogDirty = true;
    }
    final previousOverlay = _overlaySnapshots[id];
    if (_showInOverlay(next)) {
      if (previousOverlay == null || !_sameDirectory(previousOverlay, next)) {
        _overlaySnapshots[id] = next;
        _catalogDirty = true;
      }
    } else if (_overlaySnapshots.remove(id) != null) {
      _catalogDirty = true;
    }
    final track = session.state.playing
        ? session.trackForPath(session.currentTrackPath) ??
              libraryTrackByPath?.call(session.currentTrackPath)
        : null;
    final contribution = (
      playing: session.state.playing,
      audio:
          session.state.playing &&
          !isVideoMediaFile(session.currentTrackPath) &&
          (track != null
              ? !track.isVideo
              : isSupportedMediaFile(session.currentTrackPath)),
      keepAlive:
          session.state.playing ||
          session.isLoading ||
          session.isPlaybackStarting ||
          session.loadedPath != null,
    );
    final previous = _contributions[id];
    _playingCount +=
        (contribution.playing ? 1 : 0) - (previous?.playing == true ? 1 : 0);
    _playingAudioCount +=
        (contribution.audio ? 1 : 0) - (previous?.audio == true ? 1 : 0);
    _keepAliveCount +=
        (contribution.keepAlive ? 1 : 0) -
        (previous?.keepAlive == true ? 1 : 0);
    _contributions[id] = contribution;
    _publishCatalog();
    _publishAggregate();
  }

  void _publishAggregate({
    String? focusedSessionId,
    bool? isInitialized,
    bool updateFocus = false,
  }) {
    aggregate.update(
      PlaybackAggregateState(
        sessionCount: sessions.length,
        playingSessionCount: _playingCount,
        hasPlayingAudioSession: _playingAudioCount > 0,
        hasPlaybackToKeepAlive: _keepAliveCount > 0,
        focusedSessionId: updateFocus
            ? focusedSessionId
            : aggregate.state.focusedSessionId,
        isInitialized: isInitialized ?? aggregate.state.isInitialized,
      ),
    );
  }

  void _publishCatalog() {
    if (!_catalogDirty) return;
    _catalogDirty = false;
    final ordered = activeSessions;
    catalog.update(
      PlaybackCatalogState(
        sessions: [
          for (final session in ordered) ?_directorySnapshots[session.id],
        ],
        nowPlayingSessions: [
          for (final session in ordered) ?_overlaySnapshots[session.id],
        ],
        isInitialized: aggregate.state.isInitialized,
      ),
    );
  }

  void markActiveSessionsDirty() {
    activeSessionsDirty = true;
    _catalogDirty = true;
    sessionStateVersion++;
  }

  void markSessionStateDirty() => sessionStateVersion++;
  PlaybackSession? sessionById(String sessionId) => sessions[sessionId];
  bool isTrackActive(String path) =>
      sessions.values.any((s) => s.currentTrackPath == path);

  void registerSession(PlaybackSession session) {
    sessions[session.id] = session;
    sessionOrder.remove(session.id);
    sessionOrder.insert(0, session.id);
    markActiveSessionsDirty();
    publishSession(session);
  }

  List<PlaybackSession> removeSessions(Iterable<String> sessionIds) {
    final removed = <PlaybackSession>[];
    for (final id in LinkedHashSet<String>.from(sessionIds)) {
      final session = sessions.remove(id);
      if (session == null) continue;
      removed.add(session);
      sessionOrder.remove(id);
      _snapshots.remove(id);
      _directorySnapshots.remove(id);
      _overlaySnapshots.remove(id);
      final previous = _contributions.remove(id);
      _playingCount -= previous?.playing == true ? 1 : 0;
      _playingAudioCount -= previous?.audio == true ? 1 : 0;
      _keepAliveCount -= previous?.keepAlive == true ? 1 : 0;
      final slice = _sessionSlices[id];
      slice?.update(null);
      if (slice != null && !slice.hasListeners) {
        _sessionSlices.remove(id);
        unawaited(slice.dispose());
      }
    }
    if (removed.isNotEmpty) {
      markActiveSessionsDirty();
      _publishCatalog();
      _publishAggregate();
    }
    return removed;
  }

  Future<void> enqueueSessionPreparation(
    String id,
    Future<void> Function() prepare,
  ) {
    final previous = _preparationTasks[id] ?? Future<void>.value();
    final task = previous
        .catchError((Object error, StackTrace stackTrace) {
          AppLogService.warning(
            'playback_session_preparation_failed',
            error: error,
            stackTrace: stackTrace,
          );
        })
        .then((_) => prepare());
    _preparationTasks[id] = task;
    unawaited(
      task.then(
        (_) {
          if (identical(_preparationTasks[id], task)) {
            _preparationTasks.remove(id);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_preparationTasks[id], task)) {
            _preparationTasks.remove(id);
          }
          AppLogService.warning(
            'playback_session_preparation_failed',
            error: error,
            stackTrace: stackTrace,
          );
        },
      ),
    );
    return task;
  }

  void reorderSessions(int oldIndex, int newIndex) {
    final ids = activeSessions.map((s) => s.id).toList();
    if (oldIndex < 0 ||
        oldIndex >= ids.length ||
        newIndex < 0 ||
        newIndex > ids.length) {
      return;
    }
    if (newIndex > oldIndex) newIndex--;
    ids.insert(newIndex, ids.removeAt(oldIndex));
    sessionOrder
      ..clear()
      ..addAll(ids);
    markActiveSessionsDirty();
    _publishCatalog();
  }

  bool applyNativeSnapshot(NativePlaybackSnapshot snapshot) {
    final session = sessions[snapshot.sessionId];
    if (session == null || !session.applyNativeSnapshot(snapshot)) return false;
    publishSession(session);
    return true;
  }

  bool applyNativeProgress(NativePlaybackProgressUpdate progress) {
    final session = sessions[progress.sessionId];
    if (session == null) return false;
    session.applyNativeProgress(progress);
    return true;
  }

  void syncSlice({
    required List<PlaybackSession> activeSessions,
    required int playingSessionCount,
    required String? focusedSessionId,
    required int coverGeneration,
    required bool isInitialized,
    bool refreshSessions = true,
  }) {
    this.coverGeneration = coverGeneration;
    if (refreshSessions) {
      for (final session in activeSessions) {
        publishSession(session);
      }
    }
    if (aggregate.state.isInitialized != isInitialized) _catalogDirty = true;
    _publishAggregate(
      focusedSessionId: focusedSessionId,
      isInitialized: isInitialized,
      updateFocus: true,
    );
    _publishCatalog();
  }

  Future<void> dispose() async {
    await Future.wait([
      aggregate.dispose(),
      catalog.dispose(),
      ..._sessionSlices.values.map((s) => s.dispose()),
    ]);
    _sessionSlices.clear();
  }
}

class TimerService {
  TimerMode? timerMode;
  Duration? timerDuration;
  TimerMode timerDraftMode = TimerMode.manual;
  Duration timerDraftDuration = const Duration(minutes: 30);
  bool timerActive = false;
  Duration? timerRemaining;
  DateTime? timerEndsAt;
  Timer? countdownTimer;
  bool timerWaitingForPlayback = false;
  int timerGeneration = 0;
  final List<String> pausedByTimerSessionIds = <String>[];
  bool autoResumeEnabled = false;
  int autoResumeHour = 7;
  int autoResumeMinute = 0;
  Timer? autoResumeTimer;
  DateTime? autoResumeAt;
  bool stopAfterCurrentTrack = false;
  final AudioStateSlice<TimerStateSliceData> slice =
      AudioStateSlice<TimerStateSliceData>(TimerStateSliceData());

  void syncSlice({required bool isInitialized}) {
    slice.update(
      TimerStateSliceData(
        mode: timerMode,
        duration: timerDuration,
        draftMode: timerDraftMode,
        draftDuration: timerDraftDuration,
        active: timerActive,
        remaining: timerRemaining,
        autoResumeEnabled: autoResumeEnabled,
        autoResumeHour: autoResumeHour,
        autoResumeMinute: autoResumeMinute,
        autoResumeAt: autoResumeAt,
        pausedByTimerSessionIds: pausedByTimerSessionIds,
        stopAfterCurrentTrack: stopAfterCurrentTrack,
        isInitialized: isInitialized,
      ),
    );
  }

  Future<void> dispose() => slice.dispose();
}
