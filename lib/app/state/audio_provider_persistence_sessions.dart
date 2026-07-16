part of 'audio_provider.dart';

extension AudioProviderPersistenceSessions on AudioProvider {
  Future<void> _restorePersistedPlaybackRuntime(
    List<PlaybackSession> restoredSessions, {
    required String? focusedSessionId,
  }) async {
    try {
      final restoredIds = restoredSessions
          .map((session) => session.id)
          .toList(growable: false);
      final firstSessionId = focusedSessionId;

      for (final id in restoredIds) {
        final session = _sessions[id];
        if (session == null) continue;

        final shouldPrepareNow = id == firstSessionId;
        if (!shouldPrepareNow &&
            !_nativePlaybackRepository.supportsDeferredSessionRegistration) {
          continue;
        }

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
            audioEffects: NativeAudioEffects(
              state: session.audioEffects,
              channelSwapEnabled: session.channelSwapEnabled,
            ),
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
            shuffle: session.loopMode.isShuffle,
            candidateUris: _candidatePlaybackUrisForTrack(track),
            deferPlayerCreation: !shouldPrepareNow,
          );
          if (!prepareResult.isOk) {
            continue;
          }
          final preparedSnapshot = prepareResult.valueOrNull;
          if (AppPlatform.usesDesktopPlaybackBridge &&
              preparedSnapshot != null) {
            _handleNativePlaybackSnapshot(
              preparedSnapshot.copyWith(
                volume: session.volume,
                speed: session.speed,
                audioEffects: session.audioEffects,
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
        } catch (error, stackTrace) {
          _logAudioProviderPersistenceFailure(error, stackTrace);
        }
      }

      final snapshotResponse = await _nativePlaybackRepository.snapshot();
      final snapshotValue = snapshotResponse.valueOrNull;
      if (snapshotValue != null) {
        for (final snapshot in snapshotValue.sessions) {
          final session = _sessions[snapshot.sessionId];
          _handleNativePlaybackSnapshot(
            session == null
                ? snapshot
                : snapshot.copyWith(
                    volume: session.volume,
                    speed: session.speed,
                    audioEffects: session.audioEffects,
                    channelSwapEnabled: session.channelSwapEnabled,
                  ),
          );
        }
      }

      _syncNotificationState();
      if (_sessions.isNotEmpty) _notifyListeners();
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }
}
