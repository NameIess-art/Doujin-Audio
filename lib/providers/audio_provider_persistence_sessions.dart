part of 'audio_provider.dart';

extension AudioProviderPersistenceSessions on AudioProvider {
  Future<void> _loadSessions() async {
    try {
      final db = _audioDatabaseRepository;
      var persistedSessions = await db.loadAllSessions();

      if (persistedSessions.isEmpty) {
        final prefs = await _prefs;
        final raw = prefs.getString(_kSessionsKey);
        final migrated = AppDatabase.tryMigrateSessionsFromJson(raw);
        if (migrated != null && migrated.isNotEmpty) {
          await db.saveAllSessions(migrated);
          await prefs.remove(_kSessionsKey);
          persistedSessions = migrated;
        }
      }

      if (persistedSessions.isEmpty) return;

      final restoredIds = <String>[];
      for (final item in persistedSessions) {
        final trackPath = item.trackPath;
        final customQueueTracks = item.customQueueTracks == null
            ? null
            : List<MusicTrack>.unmodifiable(item.customQueueTracks!);
        final playbackQueue = item.playbackQueue;
        final track =
            customQueueTracks?.firstWhere(
              (candidate) =>
                  PathMatcher.equalsNormalized(candidate.path, trackPath),
              orElse: () => customQueueTracks.first,
            ) ??
            trackByPath(trackPath);
        if (track == null && playbackQueue == null) continue;

        final loopModeIndex = item.loopModeIndex;
        final loopMode = SessionLoopMode
            .values[loopModeIndex.clamp(0, SessionLoopMode.values.length - 1)];
        final volume = item.volume.clamp(0.0, _maxSessionVolume);
        final speed = _nearestPlaybackSpeed(item.speed);

        final recordProgress = _settingsRepository.recordPlaybackProgress;
        final restoredPositionMs = recordProgress ? item.positionMs : 0;
        final restoredPosition = Duration(
          milliseconds: max(0, restoredPositionMs),
        );

        final restoredSessionId = item.id;
        final createdAt = item.createdAtMs == null
            ? DateTime.now()
            : DateTime.fromMillisecondsSinceEpoch(item.createdAtMs!);
        final session = PlaybackSession(
          id: restoredSessionId,
          currentTrackPath: track?.path ?? '',
          loopMode: loopMode,
          nonSingleLoopMode: loopMode == SessionLoopMode.single
              ? SessionLoopMode.folderSequential
              : loopMode,
          volume: volume,
          createdAt: createdAt,
          state: PlayerState(false, ProcessingState.idle),
          customQueueTracks: customQueueTracks,
          playbackQueue: playbackQueue,
          currentQueueIndex: recordProgress ? item.currentQueueIndex : 0,
        );
        session.lastKnownPosition = restoredPosition;
        session.setOptimisticDuration(Duration(milliseconds: item.durationMs));
        session.lastPersistedPositionBucket = restoredPosition.inSeconds ~/ 5;
        session.channelSwapEnabled = item.channelSwapEnabled;
        session.speed = speed;
        session.audioEffects = item.audioEffects;
        _sessions[session.id] = session;
        _markActiveSessionsDirty();
        _bindSessionListeners(session);
        restoredIds.add(session.id);
      }

      final validOrdered = _sessionOrder
          .where((id) => restoredIds.contains(id))
          .toList();
      for (final id in restoredIds) {
        if (!validOrdered.contains(id)) validOrdered.add(id);
      }
      _sessionOrder
        ..clear()
        ..addAll(validOrdered);
      _markActiveSessionsDirty();

      final firstSessionId = _sessionOrder.firstOrNull;
      _notificationFocusSessionId = firstSessionId;

      for (final id in restoredIds) {
        final session = _sessions[id];
        if (session == null) continue;

        // Only prepare the first (focused) session to save memory.
        // Others will be lazily prepared when the user interacts with them.
        final shouldPrepareNow = id == firstSessionId;
        if (!shouldPrepareNow) continue;

        try {
          final track = _sessionTrackForPath(session, session.currentTrackPath);
          if (track == null) continue;

          final uri =
              track.path.startsWith('content://') ||
                  PathMatcher.isRemoteUri(track.path)
              ? Uri.parse(track.path)
              : Uri.file(track.path);
          final prepareResult = await _nativePlaybackRepository.prepareSession(
            sessionId: session.id,
            uri: uri,
            title: track.displayName,
            path: track.path,
            subtitle: track.groupTitle,
            startPosition: session.lastKnownPosition,
            volume: session.volume,
            speed: session.speed,
            repeatOne: session.loopMode == SessionLoopMode.single,
            queue: _nativePlaybackQueueFor(
              session,
              currentPath: session.currentTrackPath,
            ),
            queueStartIndex: _nativePlaybackQueueStartIndexFor(
              session,
              currentPath: session.currentTrackPath,
            ),
            repeatAll: session.loopMode != SessionLoopMode.single,
            shuffle: _isShuffleMode(session.loopMode),
          );
          if (!prepareResult.isOk) {
            continue;
          }
          if (session.channelSwapEnabled ||
              session.audioEffects.hasEnabledEffects) {
            await _nativePlaybackRepository.setAudioEffects(
              session.id,
              NativeAudioEffects(
                state: session.audioEffects,
                channelSwapEnabled: session.channelSwapEnabled,
              ),
            );
          }
          session.loadedPath = track.path;
          _ensureSubtitleTrackLoaded(track.path);
          _refreshNotificationSubtitleForSession(
            session,
            position: session.lastKnownPosition,
            syncNotification: false,
          );
        } catch (e) {
          debugPrint('AudioProvider persistence error: $e');
        }
      }

      final snapshotResponse = await _nativePlaybackRepository.snapshot();
      final snapshotValue = snapshotResponse.valueOrNull;
      if (snapshotValue != null) {
        for (final snapshot in snapshotValue.sessions) {
          _handleNativePlaybackSnapshot(snapshot);
        }
      }

      _syncNotificationState();
      if (_sessions.isNotEmpty) _notifyListeners();
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
  }

  Future<void> _saveSessionState() async {
    try {
      final ordered = _sessionOrder
          .map((id) => _sessions[id])
          .whereType<PlaybackSession>()
          .toList();
      final tracksToUpdate = <MusicTrack>[];
      final now = DateTime.now();

      final payload = ordered
          .asMap()
          .entries
          .map((entry) {
            final session = entry.value;
            final positionMs = max(
              0,
              max(
                session.position.inMilliseconds,
                session.lastKnownPosition.inMilliseconds,
              ),
            );

            final track = _libraryByPath[session.currentTrackPath];
            if (track != null) {
              final posDur = Duration(milliseconds: positionMs);
              final shouldUpdateAt = session.state.playing;
              if (track.lastPlayedPosition.inSeconds ~/ 5 !=
                      posDur.inSeconds ~/ 5 ||
                  shouldUpdateAt) {
                final updatedTrack = track.copyWith(
                  lastPlayedPosition: posDur,
                  lastPlayedAt: shouldUpdateAt ? now : track.lastPlayedAt,
                );
                _libraryByPath[track.path] = updatedTrack;
                final idx = _libraryIndexByPath[track.path];
                if (idx != null &&
                    idx < _library.length &&
                    _library[idx].path == track.path) {
                  _library[idx] = updatedTrack;
                }
                tracksToUpdate.add(updatedTrack);
              }
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
              lastPlayedAtMs: session.state.playing
                  ? now.millisecondsSinceEpoch
                  : null,
              sortOrder: entry.key,
            );
          })
          .toList(growable: false);

      if (tracksToUpdate.isNotEmpty && !_skipDisposePersistence) {
        await _audioDatabaseRepository.upsertTracks(tracksToUpdate);
      }
      await _audioDatabaseRepository.saveAllSessions(payload);
      final prefs = await _prefs;
      await prefs.remove(_kSessionsKey);
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
  }

  void _scheduleSaveSessionState({
    Duration delay = const Duration(milliseconds: 220),
  }) {
    _saveSessionStateTimer?.cancel();
    _saveSessionStateTimer = Timer(delay, () {
      _saveSessionStateTimer = null;
      unawaited(_saveSessionState());
    });
  }

  void _scheduleSessionPersistence() {
    _scheduleSaveSessionState();
    _scheduleSaveSessionOrder();
  }
}
