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
        final track = trackByPath(trackPath);
        if (track == null) continue;

        final loopModeIndex = item.loopModeIndex;
        final loopMode = SessionLoopMode
            .values[loopModeIndex.clamp(0, SessionLoopMode.values.length - 1)];
        final volume = item.volume;
        final restoredPositionMs = item.positionMs;
        final restoredPosition = Duration(
          milliseconds: max(0, restoredPositionMs),
        );

        final restoredSessionId = item.id;
        final createdAt = item.createdAtMs == null
            ? DateTime.now()
            : DateTime.fromMillisecondsSinceEpoch(item.createdAtMs!);
        final session = PlaybackSession(
          id: restoredSessionId,
          currentTrackPath: track.path,
          loopMode: loopMode,
          nonSingleLoopMode: loopMode == SessionLoopMode.single
              ? SessionLoopMode.folderSequential
              : loopMode,
          volume: volume,
          createdAt: createdAt,
          state: PlayerState(false, ProcessingState.idle),
        );
        session.lastKnownPosition = restoredPosition;
        session.setOptimisticDuration(Duration(milliseconds: item.durationMs));
        session.lastPersistedPositionBucket = restoredPosition.inSeconds ~/ 5;
        session.channelSwapEnabled = item.channelSwapEnabled;
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
          final track = trackByPath(session.currentTrackPath);
          if (track == null) continue;

          final uri = track.path.startsWith('content://')
              ? Uri.parse(track.path)
              : Uri.file(track.path);
          final prepareResult = await _nativePlaybackRepository.prepareSession(
            sessionId: session.id,
            uri: uri,
            title: track.displayName,
            subtitle: track.groupTitle,
            startPosition: session.lastKnownPosition,
            volume: session.volume,
            repeatOne: session.loopMode == SessionLoopMode.single,
          );
          if (!prepareResult.isOk) {
            continue;
          }
          if (session.channelSwapEnabled) {
            await _nativePlaybackRepository.setChannelSwap(
              session.id,
              session.channelSwapEnabled,
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
      final payload = ordered
          .asMap()
          .entries
          .map(
            (entry) => PersistedSession(
              id: entry.value.id,
              trackPath: entry.value.currentTrackPath,
              loopModeIndex: entry.value.loopMode.index,
              volume: entry.value.volume,
              positionMs: max(
                0,
                max(
                  entry.value.position.inMilliseconds,
                  entry.value.lastKnownPosition.inMilliseconds,
                ),
              ),
              durationMs: entry.value.duration?.inMilliseconds ?? 0,
              channelSwapEnabled: entry.value.channelSwapEnabled,
              createdAtMs: entry.value.createdAt.millisecondsSinceEpoch,
              updatedAtMs: DateTime.now().millisecondsSinceEpoch,
              lastPlayedAtMs: entry.value.state.playing
                  ? DateTime.now().millisecondsSinceEpoch
                  : null,
              sortOrder: entry.key,
            ),
          )
          .toList(growable: false);
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
