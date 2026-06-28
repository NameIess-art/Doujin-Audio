part of 'audio_state_services.dart';

class PlaybackSessionService {
  final Map<String, PlaybackSession> sessions = <String, PlaybackSession>{};
  final List<String> sessionOrder = <String>[];
  bool activeSessionsDirty = true;
  int sessionStateVersion = 0;
  List<PlaybackSession> activeSessionsCache = const <PlaybackSession>[];
  Future<void> sessionPreparationQueue = Future<void>.value();
  Timer? saveSessionStateTimer;
  Timer? saveSessionOrderTimer;
  final AudioStateSlice<PlaybackStateSliceData> slice =
      AudioStateSlice<PlaybackStateSliceData>(const PlaybackStateSliceData());

  List<PlaybackSession> get activeSessions {
    if (activeSessionsDirty) {
      final result = <PlaybackSession>[];
      final orderSet = sessionOrder.toSet();
      for (final id in sessionOrder) {
        final session = sessions[id];
        if (session != null) {
          result.add(session);
        }
      }
      for (final session in sessions.values) {
        if (!orderSet.contains(session.id)) {
          result.add(session);
        }
      }
      activeSessionsCache = List<PlaybackSession>.unmodifiable(result);
      activeSessionsDirty = false;
    }
    return activeSessionsCache;
  }

  int get playingSessionCount =>
      sessions.values.where((session) => session.state.playing).length;

  void markActiveSessionsDirty() {
    activeSessionsDirty = true;
    sessionStateVersion++;
  }

  void markSessionStateDirty() {
    sessionStateVersion++;
  }

  PlaybackSession? sessionById(String sessionId) => sessions[sessionId];

  bool isTrackActive(String trackPath) =>
      sessions.values.any((session) => session.currentTrackPath == trackPath);

  void registerSession(PlaybackSession session) {
    sessions[session.id] = session;
    sessionOrder.remove(session.id);
    sessionOrder.insert(0, session.id);
    markActiveSessionsDirty();
  }

  List<PlaybackSession> removeSessions(Iterable<String> sessionIds) {
    final removedSessions = <PlaybackSession>[];
    for (final sessionId in LinkedHashSet<String>.from(sessionIds)) {
      final session = sessions.remove(sessionId);
      if (session == null) continue;
      removedSessions.add(session);
      sessionOrder.remove(sessionId);
    }
    if (removedSessions.isNotEmpty) {
      markActiveSessionsDirty();
    }
    return removedSessions;
  }

  void enqueueSessionPreparation(Future<void> Function() prepare) {
    sessionPreparationQueue = sessionPreparationQueue
        .catchError((_) {})
        .then((_) => prepare());
  }

  void reorderSessions(int oldIndex, int newIndex) {
    final orderedIds = activeSessions.map((session) => session.id).toList();
    if (oldIndex < 0 || oldIndex >= orderedIds.length) return;
    if (newIndex < 0 || newIndex > orderedIds.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final movedId = orderedIds.removeAt(oldIndex);
    orderedIds.insert(newIndex, movedId);
    sessionOrder
      ..clear()
      ..addAll(orderedIds);
    markActiveSessionsDirty();
  }

  bool applyNativeSnapshot(NativePlaybackSnapshot snapshot) {
    final session = sessions[snapshot.sessionId];
    if (session == null) return false;
    final previousTrackPath = session.currentTrackPath;
    session.applyNativeSnapshot(snapshot);
    if (session.currentTrackPath != previousTrackPath) {
      markActiveSessionsDirty();
    }
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
    required bool multiThreadPlaybackEnabled,
    required int coverGeneration,
    required bool isInitialized,
  }) {
    slice.update(
      PlaybackStateSliceData(
        activeSessions: UnmodifiableListView<PlaybackSession>(activeSessions),
        playingSessionCount: playingSessionCount,
        focusedSessionId: focusedSessionId,
        multiThreadPlaybackEnabled: multiThreadPlaybackEnabled,
        coverGeneration: coverGeneration,
        sessionStateVersion: sessionStateVersion,
        isInitialized: isInitialized,
      ),
    );
  }

  Future<void> dispose() => slice.dispose();
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
  final AudioStateSlice<TimerStateSliceData> slice =
      AudioStateSlice<TimerStateSliceData>(const TimerStateSliceData());

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
        pausedByTimerSessionIds: UnmodifiableListView<String>(
          pausedByTimerSessionIds,
        ),
        isInitialized: isInitialized,
      ),
    );
  }

  Future<void> dispose() => slice.dispose();
}
