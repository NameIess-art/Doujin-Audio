part of 'audio_provider.dart';

extension AudioProviderQueues on AudioProvider {
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
    _registerSession(session);
    _scheduleSessionPersistence();
    return session;
  }

  List<PlaybackSession> get ordinaryPlaybackSessions => activeSessions
      .where((session) => !session.isPlaybackQueue)
      .toList(growable: false);

  void renamePlaybackQueue(String sessionId, String name) {
    final session = _sessions[sessionId];
    final queue = session?.playbackQueue;
    final trimmed = name.trim();
    if (session == null || queue == null || trimmed.isEmpty) return;
    session.playbackQueue = queue.copyWith(name: trimmed);
    _markActiveSessionsDirty();
    _notifyPlaybackChanged();
    _scheduleSessionPersistence();
  }

  void setPlaybackQueueColor(String sessionId, Color? color) {
    final session = _sessions[sessionId];
    final queue = session?.playbackQueue;
    if (session == null || queue == null) return;
    session.playbackQueue = queue.copyWith(
      colorValue: color?.toARGB32(),
      clearColor: color == null,
    );
    _markActiveSessionsDirty();
    _notifyPlaybackChanged();
    _scheduleSessionPersistence();
  }

  Future<void> addTrackToPlaybackQueue(
    String sessionId,
    MusicTrack track,
  ) async {
    await _addPlaybackQueueEntry(
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
    String sessionId,
    MusicTrack track,
  ) async {
    final workTracks = tracksInSameWork(track.path);
    final groupTracks = tracksInSameGroup(track.path);
    final tracks = workTracks.isNotEmpty
        ? workTracks
        : groupTracks.isNotEmpty
        ? groupTracks
        : (library
              .where(
                (candidate) => PathMatcher.equalsNormalized(
                  candidate.groupKey,
                  track.groupKey,
                ),
              )
              .toList(growable: false)
            ..sort(getTrackComparator));
    if (tracks.isEmpty) return;
    await _addPlaybackQueueEntry(
      sessionId,
      PlaybackQueueEntry(
        id: _nextQueueEntryId(),
        kind: PlaybackQueueEntryKind.work,
        title: track.groupTitle,
        tracks: List<MusicTrack>.unmodifiable(tracks),
      ),
    );
  }

  Future<void> _addPlaybackQueueEntry(
    String sessionId,
    PlaybackQueueEntry entry,
  ) async {
    final session = _sessions[sessionId];
    final queue = session?.playbackQueue;
    if (session == null || queue == null) return;
    final wasEmpty = queue.expandedTracks.isEmpty;
    session.playbackQueue = queue.copyWith(
      entries: List<PlaybackQueueEntry>.unmodifiable(<PlaybackQueueEntry>[
        ...queue.entries,
        entry,
      ]),
    );
    await _syncPlaybackQueueSession(session, selectFirst: wasEmpty);
  }

  Future<void> removePlaybackQueueEntry(
    String sessionId,
    String entryId,
  ) async {
    final session = _sessions[sessionId];
    final queue = session?.playbackQueue;
    if (session == null || queue == null) return;
    final entries = queue.entries
        .where((entry) => entry.id != entryId)
        .toList(growable: false);
    if (entries.length == queue.entries.length) return;
    session.playbackQueue = queue.copyWith(entries: entries);
    await _syncPlaybackQueueSession(session);
  }

  Future<void> _syncPlaybackQueueSession(
    PlaybackSession session, {
    bool selectFirst = false,
  }) async {
    final tracks =
        session.playbackQueue?.expandedTracks ?? const <MusicTrack>[];
    final previousPath = session.currentTrackPath;
    final previousIndex = session.currentQueueIndex;
    final previousPosition = session.position;
    final wasPlaying = session.state.playing;
    session.customQueueTracks = List<MusicTrack>.unmodifiable(tracks);

    if (tracks.isEmpty) {
      session.currentTrackPath = '';
      session.currentQueueIndex = 0;
      session.loadedPath = null;
      session.resetStreamsForNewTrack();
      session.setOptimisticState(
        playing: false,
        processingState: ProcessingState.idle,
      );
      await _nativePlaybackRepository.removeSession(session.id);
    } else {
      var nextIndex = selectFirst
          ? 0
          : previousIndex.clamp(0, tracks.length - 1);
      if (!selectFirst &&
          nextIndex < tracks.length &&
          !PathMatcher.equalsNormalized(tracks[nextIndex].path, previousPath)) {
        final matchingIndex = tracks.indexWhere(
          (track) => PathMatcher.equalsNormalized(track.path, previousPath),
        );
        nextIndex = matchingIndex < 0 ? 0 : matchingIndex;
      }
      session.currentQueueIndex = nextIndex;
      session.currentTrackPath = tracks[nextIndex].path;
      session.lastKnownPosition =
          PathMatcher.equalsNormalized(session.currentTrackPath, previousPath)
          ? previousPosition
          : Duration.zero;
      session.loadedPath = null;
      await _prepareAndPlay(
        session,
        nextPath: session.currentTrackPath,
        autoPlay: wasPlaying,
      );
    }
    _markActiveSessionsDirty();
    _notifyPlaybackChanged();
    _scheduleSessionPersistence();
  }

  String _nextQueueEntryId() =>
      'queue_entry_${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(1 << 20)}';
}
