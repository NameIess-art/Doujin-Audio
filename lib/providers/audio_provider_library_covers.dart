part of 'audio_provider.dart';

extension AudioProviderLibraryCovers on AudioProvider {
  /// Recursively scans for all images in the root folder containing the given track.
  Future<List<String>> discoverImagesInRoot(String trackPath) async {
    final track = trackByPath(trackPath);
    final scopeFolder = _resolveCoverScopeFolderPath(
      this,
      track,
      trackPath: trackPath,
    );
    if (scopeFolder == null || scopeFolder.isEmpty) return [];

    if (PathMatcher.isContentUri(scopeFolder) ||
        PathMatcher.isContentUri(trackPath)) {
      return _discoverContentImages(
        trackPath: trackPath,
        groupKey: track?.groupKey,
        rootFolder: scopeFolder,
      );
    }

    return _discoverFileSystemImages(scopeFolder);
  }

  /// Recursively scans for all images in the given folder.
  Future<List<String>> discoverImagesInFolder(String folderPath) async {
    if (folderPath.trim().isEmpty) return [];
    final normalizedFolder = PathMatcher.normalize(folderPath);
    if (normalizedFolder.isEmpty) return [];

    if (PathMatcher.isContentUri(normalizedFolder)) {
      return _discoverContentImages(
        trackPath: normalizedFolder,
        rootFolder: normalizedFolder,
      );
    }

    return _discoverFileSystemImages(normalizedFolder);
  }

  /// Sets a manual cover image for a track and persists it.
  Future<void> setTrackManualCover(String trackPath, String? imagePath) async {
    final targetTrack = trackByPath(trackPath);
    if (targetTrack == null) return;

    final scopeFolder = _resolveCoverScopeFolderPath(
      this,
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

    // Clear caches to force re-resolution
    _clearResolvedCoverPaths();

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

  Future<void> setFolderManualCover(String folderPath, String imagePath) {
    return _setFolderManualCover(folderPath, imagePath);
  }

  Future<List<String>> _discoverContentImages({
    required String trackPath,
    required String rootFolder,
    String? groupKey,
  }) async {
    try {
      final raw = await AudioProvider._fileCacheChannel
          .invokeMethod<List<dynamic>>(
            FileCacheMethod.discoverRootImages,
            <String, Object?>{
              'path': trackPath,
              'groupKey': groupKey,
              'rootFolder': rootFolder,
            },
          );
      if (raw == null) return [];
      return raw
          .map((item) => item?.toString().trim() ?? '')
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    } on MissingPluginException {
      return [];
    } catch (e) {
      debugPrint('Error discovering content images in root $rootFolder: $e');
      return [];
    }
  }

  Future<List<String>> _discoverFileSystemImages(String folderPath) async {
    final normalizedScope = PathMatcher.normalize(folderPath);
    final cached = _discoveredImagesByScopeCache[normalizedScope];
    if (cached != null) {
      return cached;
    }

    final images = <String>[];
    try {
      final dir = Directory(folderPath);
      if (!await dir.exists()) return [];

      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final ext = path.extension(entity.path).toLowerCase();
        if (!AudioProvider._supportedImageExtensions.contains(ext)) {
          continue;
        }
        images.add(entity.path);
      }
    } catch (e) {
      debugPrint('Error discovering images in root $folderPath: $e');
    }

    images.sort((a, b) => a.compareTo(b));
    final snapshot = List<String>.unmodifiable(images);
    _discoveredImagesByScopeCache[normalizedScope] = snapshot;
    return snapshot;
  }
}
