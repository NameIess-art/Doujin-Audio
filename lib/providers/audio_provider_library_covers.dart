part of 'audio_provider.dart';

extension AudioProviderLibraryCovers on AudioProvider {
  /// Recursively scans for all images in the root folder containing the given track.
  Future<List<String>> discoverImagesInRoot(String trackPath) async {
    final rootFolder = getRootFolderPath(trackPath);
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

    final rootFolder = getRootFolderPath(trackPath);
    final tracksToUpdate = <MusicTrack>[];
    
    // If we found a root folder, update ALL tracks in that root.
    // Otherwise fall back to just tracks in the same immediate group.
    if (rootFolder.isNotEmpty) {
      for (var i = 0; i < _library.length; i++) {
        final track = _library[i];
        if (PathMatcher.isWithinOrEqual(track.path, rootFolder)) {
          final updatedTrack = _copyTrack(track, manualCoverPath: imagePath);
          _library[i] = updatedTrack;
          _libraryByPath[track.path] = updatedTrack;
          tracksToUpdate.add(updatedTrack);
        }
      }
    } else {
      final groupTracks = tracksInSameGroup(trackPath).toList();
      for (final track in groupTracks) {
        final updatedTrack = _copyTrack(track, manualCoverPath: imagePath);
        _libraryByPath[track.path] = updatedTrack;
        final index = _library.indexWhere((t) => t.path == track.path);
        if (index >= 0) {
          _library[index] = updatedTrack;
        }
        tracksToUpdate.add(updatedTrack);
      }
    }

    // Clear caches to force re-resolution
    _clearResolvedCoverPaths();
    
    // Rebuild indexes to ensure folder cards and other groupings see the new track data
    _rebuildLibraryIndexes();
    // Mark sessions dirty to refresh playlist tab and bottom card
    _markActiveSessionsDirty();
    
    // Persist to DB
    if (tracksToUpdate.isNotEmpty) {
      await _audioDatabaseRepository.upsertTracks(tracksToUpdate);
    }
    
    // Refresh system notifications to reflect the new cover
    _syncNotificationState();
    
    _notifyListeners();
  }

}
