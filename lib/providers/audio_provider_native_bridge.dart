part of 'audio_provider.dart';

extension AudioProviderNativeBridge on AudioProvider {
  String? _nativeSnapshotPathFromUri(String? uriValue) {
    if (uriValue == null || uriValue.isEmpty) return null;
    final uri = Uri.tryParse(uriValue);
    if (uri == null) return uriValue;
    if (uri.scheme == 'file') return uri.toFilePath(windows: false);
    if (uri.scheme == 'content') return uriValue;
    return null;
  }

  NativePlaybackSnapshot _normalizeNativePlaybackSnapshot(
    NativePlaybackSnapshot snapshot,
  ) {
    final rawPath = snapshot.path ?? _nativeSnapshotPathFromUri(snapshot.uri);
    if (rawPath == null || rawPath.isEmpty) {
      return snapshot;
    }
    final resolvedPath = _resolveRetargetedPath(rawPath);
    if (PathMatcher.equalsNormalized(resolvedPath, rawPath)) {
      return snapshot;
    }
    return snapshot.copyWith(path: resolvedPath);
  }

  void _handleNativePlaybackSnapshot(NativePlaybackSnapshot snapshot) {
    final normalizedSnapshot = _normalizeNativePlaybackSnapshot(snapshot);
    final previousTrackPath =
        _sessions[normalizedSnapshot.sessionId]?.currentTrackPath;
    _playbackService.applyNativeSnapshot(normalizedSnapshot);

    // Update track duration in library if it was unknown
    final session = _sessions[snapshot.sessionId];
    if (session != null &&
        previousTrackPath != null &&
        session.currentTrackPath != previousTrackPath) {
      _ensureSubtitleTrackLoaded(session.currentTrackPath);
      _refreshNotificationSubtitleForSession(
        session,
        position: session.position,
        syncNotification: false,
      );
      _markActiveSessionsDirty();
      _syncNotificationState();
      _scheduleSaveSessionState(delay: const Duration(milliseconds: 800));
      _notifyListeners();
    }
    final trackPath = session?.currentTrackPath;
    if (trackPath != null && normalizedSnapshot.duration != null) {
      final track = _libraryByPath[trackPath];
      if (track != null && track.duration == Duration.zero) {
        final updatedTrack = track.copyWith(
          duration: normalizedSnapshot.duration!,
        );
        _libraryByPath[trackPath] = updatedTrack;
        final index = _library.indexOf(track);
        if (index != -1) {
          _library[index] = updatedTrack;
          unawaited(_audioDatabaseRepository.upsertTracks([updatedTrack]));
        }
      }
    }
  }
}
