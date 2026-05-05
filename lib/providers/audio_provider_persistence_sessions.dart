part of 'audio_provider.dart';

extension AudioProviderPersistenceSessions on AudioProvider {
  Future<void> _loadSessions() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(_kSessionsKey);
      if (raw == null || raw.isEmpty) return;
      final list = json.decode(raw) as List<dynamic>;

      final restoredIds = <String>[];
      for (final item in list.whereType<Map<String, dynamic>>()) {
        final trackPath = item['path'] as String?;
        if (trackPath == null) continue;
        final track = trackByPath(trackPath);
        if (track == null) continue;

        final loopModeIndex =
            item['loopMode'] as int? ?? SessionLoopMode.folderSequential.index;
        final loopMode = SessionLoopMode
            .values[loopModeIndex.clamp(0, SessionLoopMode.values.length - 1)];
        final volume = (item['volume'] as num?)?.toDouble() ?? 1.0;
        final restoredPositionMs = (item['positionMs'] as num?)?.toInt() ?? 0;
        final restoredPosition = Duration(
          milliseconds: max(0, restoredPositionMs),
        );

        final restoredSessionId = item['id'] as String? ?? _nextSessionId();
        final session = PlaybackSession(
          id: restoredSessionId,
          currentTrackPath: track.path,
          loopMode: loopMode,
          nonSingleLoopMode: loopMode == SessionLoopMode.single
              ? SessionLoopMode.folderSequential
              : loopMode,
          volume: volume,
          createdAt: DateTime.now(),
          state: PlayerState(false, ProcessingState.idle),
        );
        session.lastKnownPosition = restoredPosition;
        session.lastPersistedPositionBucket = restoredPosition.inSeconds ~/ 5;
        _sessions[session.id] = session;
        _markActiveSessionsDirty();
        _bindSessionListeners(session);
        restoredIds.add(session.id);

        try {
          final uri = track.path.startsWith('content://')
              ? Uri.parse(track.path)
              : Uri.file(track.path);
          final prepareResult = await NativePlaybackBridge.instance
              .prepareSession(
                sessionId: session.id,
                uri: uri,
                title: track.displayName,
                subtitle: track.groupTitle,
                startPosition: restoredPosition,
                volume: volume,
                repeatOne: loopMode == SessionLoopMode.single,
              );
          if ((prepareResult['ok'] as bool?) != true) {
            continue;
          }
          session.loadedPath = track.path;
          _ensureSubtitleTrackLoaded(track.path);
          _refreshNotificationSubtitleForSession(
            session,
            position: restoredPosition,
            syncNotification: false,
          );
        } catch (e) {
          debugPrint('AudioProvider persistence error: $e');
        }
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
      _notificationFocusSessionId = _sessionOrder.isNotEmpty
          ? _sessionOrder.first
          : restoredIds.isNotEmpty
          ? restoredIds.first
          : null;

      final snapshotResponse = await NativePlaybackBridge.instance.snapshot();
      final snapshotValue = snapshotResponse['value'];
      if (snapshotValue is List) {
        for (final raw in snapshotValue.whereType<Map<dynamic, dynamic>>()) {
          _handleNativePlaybackSnapshot(NativePlaybackSnapshot.fromMap(raw));
        }
      } else if (snapshotValue is Map) {
        _handleNativePlaybackSnapshot(
          NativePlaybackSnapshot.fromMap(snapshotValue),
        );
      }

      _syncNotificationState();
      if (_sessions.isNotEmpty) _notifyListeners();
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
  }

  Future<void> _saveSessionState() async {
    try {
      final prefs = await _prefs;
      final ordered = _sessionOrder
          .map((id) => _sessions[id])
          .whereType<PlaybackSession>()
          .toList();
      final encoded = json.encode(
        ordered
            .map(
              (s) => {
                'id': s.id,
                'path': s.currentTrackPath,
                'loopMode': s.loopMode.index,
                'volume': s.volume,
                'positionMs': max(
                  0,
                  max(
                    s.position.inMilliseconds,
                    s.lastKnownPosition.inMilliseconds,
                  ),
                ),
              },
            )
            .toList(),
      );
      await prefs.setString(_kSessionsKey, encoded);
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
