part of 'audio_provider.dart';

extension AudioProviderLibraryCovers on AudioProvider {
  /// Recursively scans for all images in the root folder containing the given track.
  Future<List<String>> discoverImagesInRoot(String trackPath) async {
    String rootFolder = '';
    // Find the watched root containing this track
    for (final folder in _watchedFolders) {
      if (PathMatcher.isWithinOrEqual(trackPath, folder)) {
        rootFolder = folder;
        break;
      }
    }
    if (rootFolder.isEmpty) {
      for (final libraryPath in _watchedLibraries) {
        if (PathMatcher.isWithinOrEqual(trackPath, libraryPath)) {
          rootFolder = libraryPath;
          break;
        }
      }
    }

    if (rootFolder.isEmpty) return [];

    final images = <String>[];
    try {
      final dir = Directory(rootFolder);
      if (!await dir.exists()) return [];

      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final ext = path.extension(entity.path).toLowerCase();
          if (AudioProvider._supportedImageExtensions.contains(ext)) {
            images.add(entity.path);
          }
        }
      }
    } catch (e) {
      debugPrint('Error discovering images in root $rootFolder: $e');
    }

    // Sort to keep a stable order
    images.sort((a, b) => a.compareTo(b));
    return images;
  }

  /// Sets a manual cover image for a track and persists it.
  Future<void> setTrackManualCover(String trackPath, String? imagePath) async {
    final targetTrack = trackByPath(trackPath);
    if (targetTrack == null) return;

    final updatedTracks = <MusicTrack>[];
    final tracksToUpdate = tracksInSameGroup(trackPath).toList();
    if (tracksToUpdate.isEmpty) {
      tracksToUpdate.add(targetTrack);
    }

    for (final track in tracksToUpdate) {
      final updatedTrack = MusicTrack(
        path: track.path,
        displayName: track.displayName,
        groupKey: track.groupKey,
        groupTitle: track.groupTitle,
        groupSubtitle: track.groupSubtitle,
        isSingle: track.isSingle,
        scannedAt: track.scannedAt,
        fileSizeBytes: track.fileSizeBytes,
        modifiedAt: track.modifiedAt,
        lastPlayedPosition: track.lastPlayedPosition,
        lastPlayedAt: track.lastPlayedAt,
        isFavorite: track.isFavorite,
        tags: track.tags,
        coverCachePath: track.coverCachePath,
        lyricsPath: track.lyricsPath,
        manualCoverPath: imagePath,
      );

      // Update in memory
      _libraryByPath[track.path] = updatedTrack;
      final index = _library.indexWhere((t) => t.path == track.path);
      if (index >= 0) {
        _library[index] = updatedTrack;
      }
      updatedTracks.add(updatedTrack);
    }

    // Clear caches to force re-resolution
    _clearResolvedCoverPaths();
    
    // Rebuild indexes to ensure folder cards and other groupings see the new track data
    _rebuildLibraryIndexes();
    // Mark sessions dirty to refresh playlist tab and bottom card
    _markActiveSessionsDirty();
    
    // Persist to DB
    if (updatedTracks.isNotEmpty) {
      await _audioDatabaseRepository.upsertTracks(updatedTracks);
    }
    
    // Refresh system notifications to reflect the new cover
    _syncNotificationState();
    
    _notifyListeners();
  }

}
