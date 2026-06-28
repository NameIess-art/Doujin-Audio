part of 'audio_provider.dart';

extension AudioProviderNativeBridge on AudioProvider {
  void _handleNativePlaybackProgress(NativePlaybackProgressUpdate progress) {
    _playbackService.applyNativeProgress(progress);
  }

  String _snapshotUriForPath(String pathValue) {
    if (PathMatcher.isContentUri(pathValue) ||
        PathMatcher.isRemoteUri(pathValue)) {
      return pathValue;
    }
    return Uri.file(pathValue).toString();
  }

  String? _nativeSnapshotPathFromUri(String? uriValue) {
    if (uriValue == null || uriValue.isEmpty) return null;
    final uri = Uri.tryParse(uriValue);
    if (uri == null) return uriValue;
    if (uri.scheme == 'file') {
      return uri.toFilePath(windows: _isWindowsDriveUri(uri));
    }
    if (uri.scheme == 'content') return uriValue;
    if (uri.scheme == 'http' || uri.scheme == 'https') return uriValue;
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
    final currentSession = _sessions[snapshot.sessionId];
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
            _resolveRetargetedPath(originalTrack.path),
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

    final resolvedSessionPath = _resolveRetargetedPath(currentSessionPath);
    if (PathMatcher.equalsNormalized(resolvedSessionPath, resolvedPath)) {
      return snapshot;
    }
    if (trackByPath(resolvedPath) != null ||
        trackByPath(resolvedSessionPath) == null) {
      return snapshot;
    }

    return snapshot.copyWith(
      path: resolvedSessionPath,
      uri: _snapshotUriForPath(resolvedSessionPath),
    );
  }

  void _handleNativePlaybackSnapshot(NativePlaybackSnapshot snapshot) {
    final normalizedSnapshot = _normalizeNativePlaybackSnapshot(snapshot);
    final existingSession = _sessions[normalizedSnapshot.sessionId];
    final pendingPath = existingSession?.pendingNativeTrackPath;
    final snapshotPath =
        normalizedSnapshot.path ??
        _nativeSnapshotPathFromUri(normalizedSnapshot.uri);
    if (pendingPath != null &&
        snapshotPath != null &&
        !PathMatcher.equalsNormalized(pendingPath, snapshotPath)) {
      return;
    }
    final previousTrackPath = existingSession?.currentTrackPath;
    final previousState = existingSession?.state;
    final previousIsPlaybackStarting = existingSession?.isPlaybackStarting;
    final applied = _playbackService.applyNativeSnapshot(normalizedSnapshot);
    if (!applied) return;

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
      _notifyPlaybackChanged();
    }
    final trackPath = session?.currentTrackPath;
    if (trackPath != null && normalizedSnapshot.duration != null) {
      final track = trackByPath(trackPath);
      if (track != null && track.duration == Duration.zero) {
        final updatedTrack = track.copyWith(
          duration: normalizedSnapshot.duration!,
        );
        final libraryTrack = _libraryByPath[trackPath];
        if (libraryTrack != null) {
          _libraryByPath[trackPath] = updatedTrack;
          final index = _library.indexOf(libraryTrack);
          if (index != -1) {
            _library[index] = updatedTrack;
          }
          unawaited(_audioDatabaseRepository.upsertTracks([updatedTrack]));
        }
        if (_replaceSessionTrackSnapshots(updatedTrack)) {
          _markActiveSessionsDirty();
          _scheduleSaveSessionState(delay: const Duration(milliseconds: 800));
        }
      }
    }
    if (session != null &&
        session.state == previousState &&
        session.isPlaybackStarting != previousIsPlaybackStarting) {
      _syncKeepCpuAwake();
    }
  }
}

bool _isWindowsDriveUri(Uri uri) {
  return isWindowsDriveFileUri(uri);
}
