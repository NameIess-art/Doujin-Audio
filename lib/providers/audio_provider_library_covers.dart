part of 'audio_provider.dart';

extension AudioProviderLibraryCovers on AudioProvider {
  Future<List<String>> discoverCoverCandidatesInFolder(String folderPath) {
    return _coverArtworkCacheService.discoverCoverCandidatesInFolder(
      folderPath,
    );
  }

  /// Sets a manual cover image for a track and persists it.
  Future<void> setTrackManualCover(String trackPath, String? imagePath) async {
    final targetTrack = trackByPath(trackPath);
    if (targetTrack == null) return;
    final updatedTrack = _copyTrack(targetTrack, manualCoverPath: imagePath);
    final index = _library.indexWhere((track) => track.path == trackPath);
    if (index >= 0) _library[index] = updatedTrack;
    _libraryByPath[trackPath] = updatedTrack;
    _coverArtworkCacheService.invalidateFolders(<String?>[
      _coverArtworkCacheService.coverSearchKeyForTrack(updatedTrack),
      _coverArtworkCacheService.coverScopeFolderForTrack(updatedTrack),
    ]);
    _markActiveSessionsDirty();
    await _audioDatabaseRepository.upsertTracks(<MusicTrack>[updatedTrack]);
    _syncNotificationState();
    _notifyLibraryAndPlaybackChanged();
  }

  Future<void> setFolderManualCover(
    String folderPath,
    String imagePath, {
    bool newlySaved = false,
  }) async {
    await _coverArtworkCacheService.setFolderCoverSelection(
      folderPath,
      imagePath,
      newlySaved: newlySaved,
    );
    _markActiveSessionsDirty();
    _syncNotificationState();
    _notifyLibraryAndPlaybackChanged();
  }

  Future<void> _retargetFolderCoverSelection(
    String oldFolderPath,
    String newFolderPath,
  ) {
    return _coverArtworkCacheService.retargetFolderCoverSelection(
      oldFolderPath,
      newFolderPath,
    );
  }
}
