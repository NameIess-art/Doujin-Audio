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
    _playbackFacade.registerSession(session);
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
    _playbackService.markActiveSessionsDirty();
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
    _playbackService.markActiveSessionsDirty();
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
    if (track.isSingle) {
      await addTrackToPlaybackQueue(sessionId, track);
      return;
    }
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
    final resolvedWorkRootPath = workRootForTrack(track.path);
    final workRootPath = resolvedWorkRootPath?.isNotEmpty == true
        ? resolvedWorkRootPath
        : track.groupKey.trim().isEmpty || track.groupKey == '__single_files__'
        ? null
        : PathMatcher.normalize(track.groupKey);
    await _addPlaybackQueueEntry(
      sessionId,
      PlaybackQueueEntry(
        id: _nextQueueEntryId(),
        kind: PlaybackQueueEntryKind.work,
        title: track.groupTitle,
        tracks: List<MusicTrack>.unmodifiable(tracks),
        workRootPath: workRootPath,
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
    _playbackService.markActiveSessionsDirty();
    _notifyPlaybackChanged();
    _scheduleSessionPersistence();
    await _syncPlaybackQueueSession(
      session,
      selectFirst: wasEmpty,
      persistSession: false,
    );
    _playbackFacade.publishSessionActivated(session.id);
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

  Future<void> reorderPlaybackQueueEntry(
    String sessionId,
    int oldIndex,
    int newIndex,
  ) async {
    final session = _sessions[sessionId];
    final queue = session?.playbackQueue;
    if (session == null || queue == null) return;

    if (oldIndex < newIndex) {
      newIndex -= 1;
    }

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
    await _syncPlaybackQueueSession(session, persistSession: false);
    await _audioDatabaseRepository.updatePlaybackQueueEntryOrder(
      session.id,
      entries.map((entry) => entry.id).toList(growable: false),
    );
  }

  Future<void> _syncPlaybackQueueSession(
    PlaybackSession session, {
    bool selectFirst = false,
    bool persistSession = true,
  }) async {
    final tracks =
        session.playbackQueue?.expandedTracks ?? const <MusicTrack>[];
    final previousPath = session.currentTrackPath;
    final previousIndex = session.currentQueueIndex;
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
      await _prepareAndPlay(
        session,
        nextPath: tracks[nextIndex].path,
        autoPlay: wasPlaying,
        targetQueueIndex: nextIndex,
      );
    }
    _playbackService.markActiveSessionsDirty();
    _notifyPlaybackChanged();
    if (persistSession) {
      _scheduleSessionPersistence();
    }
  }

  bool _replaceSessionTrackSnapshots(MusicTrack updatedTrack) {
    var changed = false;
    for (final session in _sessions.values) {
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
        entries: List<PlaybackQueueEntry>.unmodifiable(entries),
      );
      changed = true;
    }
    return changed;
  }

  String _nextQueueEntryId() =>
      'queue_entry_${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(1 << 20)}';
}
