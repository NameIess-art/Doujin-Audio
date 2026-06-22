part of 'audio_provider.dart';

extension AudioProviderLibraryCovers on AudioProvider {
  /// Recursively scans for all images in the root folder containing the given track.
  Future<List<String>> discoverImagesInRoot(String trackPath) async {
    final track = trackByPath(trackPath);
    return _coverArtworkCacheService.discoverImagesInRoot(trackPath, track);
  }

  /// Recursively scans for all images in the given folder.
  Future<List<String>> discoverImagesInFolder(String folderPath) async {
    return _coverArtworkCacheService.discoverImagesInFolder(folderPath);
  }

  /// Sets a manual cover image for a track and persists it.
  Future<void> setTrackManualCover(String trackPath, String? imagePath) async {
    final targetTrack = trackByPath(trackPath);
    if (targetTrack == null) return;

    final scopeFolder = _resolveCoverScopeFolderPath(
      targetTrack,
      trackPath: trackPath,
    );
    final normalizedScope = scopeFolder == null || scopeFolder.isEmpty
        ? null
        : PathMatcher.normalize(scopeFolder);
    final tracksToUpdate = <MusicTrack>[];

    if (normalizedScope != null) {
      for (var i = 0; i < _library.length; i++) {
        final track = _library[i];
        final trackScope = _notificationCoverSearchKey(track);
        if (trackScope == null ||
            !PathMatcher.equalsNormalized(trackScope, normalizedScope)) {
          continue;
        }
        final updatedTrack = _copyTrack(track, manualCoverPath: imagePath);
        _library[i] = updatedTrack;
        _libraryByPath[track.path] = updatedTrack;
        tracksToUpdate.add(updatedTrack);
      }
    } else {
      final updatedTrack = _copyTrack(targetTrack, manualCoverPath: imagePath);
      final index = _library.indexWhere((track) => track.path == trackPath);
      if (index >= 0) {
        _library[index] = updatedTrack;
      }
      _libraryByPath[trackPath] = updatedTrack;
      tracksToUpdate.add(updatedTrack);
    }

    // Clear only the affected cover scope so visible unrelated rows keep their
    // decoded image and resolved Future.
    _invalidateResolvedCoverScope(normalizedScope);

    // Mark sessions dirty to refresh playlist tab and bottom card
    _markActiveSessionsDirty();

    // Persist to DB
    if (tracksToUpdate.isNotEmpty) {
      await _audioDatabaseRepository.upsertTracks(tracksToUpdate);
    }

    // Refresh system notifications to reflect the new cover
    _syncNotificationState();

    _notifyLibraryChanged();
  }

  Future<void> setFolderManualCover(String folderPath, String imagePath) {
    return _setFolderManualCover(folderPath, imagePath);
  }
}
