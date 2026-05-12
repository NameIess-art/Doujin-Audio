part of 'audio_provider.dart';

extension AudioProviderAudioDetails on AudioProvider {
  static const LibraryOrganizer _detailLibraryOrganizer = LibraryOrganizer();

  AudioDetailTarget audioDetailTargetForTrack(MusicTrack track) {
    if (track.isSingle) {
      return AudioDetailTarget.singleAudioFile(track.path);
    }
    final watchedRoots = _watchedFolders.toList(growable: false)
      ..sort((a, b) => b.length.compareTo(a.length));
    return AudioDetailTarget.libraryRootFolder(
      _detailLibraryOrganizer.rootPathForTrack(track, watchedRoots),
    );
  }

  AudioDetailTarget? audioDetailTargetForSession(String sessionId) {
    final trackPath = sessionTrackPath(sessionId);
    if (trackPath == null || trackPath.isEmpty) return null;
    final track = trackByPath(trackPath);
    if (track == null) {
      return AudioDetailTarget.singleAudioFile(trackPath);
    }
    return audioDetailTargetForTrack(track);
  }

  Future<AudioDetailLoadResult> loadAudioDetail(AudioDetailTarget target) {
    return _audioDetailRepository.load(target);
  }

  Future<AudioDetailSaveResult> saveAudioDetail(AudioDetail detail) async {
    final result = await _audioDetailRepository.save(detail);
    _markAudioDetailDataChanged();
    _notifyListeners();
    return result;
  }

  Future<void> deleteAudioDetail(AudioDetailTarget target) async {
    await _audioDetailRepository.delete(target);
    _markAudioDetailDataChanged();
    _notifyListeners();
  }

  Future<AudioDetailSaveResult?> prefillAudioDetailRjCodeFromText(
    AudioDetailTarget target,
    String text,
  ) async {
    final result = await _audioDetailRepository.prefillRjCodeFromText(
      target,
      text,
    );
    if (result != null) {
      _markAudioDetailDataChanged();
      _notifyListeners();
    }
    return result;
  }

  Future<DlsiteMetadata> fetchDlsiteMetadata(String rjCode) {
    return _dlsiteMetadataService.fetchByRjCode(rjCode);
  }

  Future<DlsiteMetadataApplyResult> applyDlsiteMetadata(
    AudioDetail detail,
    DlsiteMetadata metadata, {
    required bool saveCover,
  }) async {
    final nextDetail = detail.copyWith(
      rjCode: metadata.rjCode,
      workTitle: metadata.workTitle,
      circleName: metadata.circleName,
      voiceActors: metadata.voiceActors,
      tags: metadata.tags,
    );
    final saveResult = await saveAudioDetail(nextDetail);

    String? coverPath;
    Object? coverError;
    final coverUrl = metadata.coverUrl;
    if (saveCover &&
        nextDetail.target.isLibraryRootFolder &&
        coverUrl != null) {
      try {
        coverPath = await _dlsiteMetadataService.downloadCover(
          coverUrl: coverUrl,
          folderPath: nextDetail.target.targetPath,
          rjCode: metadata.rjCode,
        );
        await _setFolderManualCover(nextDetail.target.targetPath, coverPath);
      } catch (error) {
        coverError = error;
      }
    }

    return DlsiteMetadataApplyResult(
      detail: saveResult.detail,
      coverPath: coverPath,
      coverError: coverError,
    );
  }

  Future<AudioDetailRenameResult> renameAudioDetailTarget(
    AudioDetail detail,
  ) async {
    return renameAudioDetailTargetToName(detail, detail.workTitle);
  }

  Future<AudioDetailRenameResult> renameAudioDetailTargetToName(
    AudioDetail detail,
    String targetName,
  ) async {
    final name = targetName.trim();
    if (name.isEmpty) {
      throw const AudioDetailRenameException('missingTitle');
    }
    final oldTarget = detail.target;

    final safeName = _safeFileName(name);
    if (safeName.isEmpty) {
      throw const AudioDetailRenameException('invalidTitle');
    }

    final oldPath = PathMatcher.normalize(oldTarget.targetPath);
    final newPath = PathMatcher.isContentUri(oldPath)
        ? await _renameContentAudioDetailTarget(oldTarget, safeName)
        : await _renameFileSystemAudioDetailTarget(
            oldTarget,
            oldPath,
            safeName,
          );
    if (PathMatcher.equalsNormalized(oldPath, newPath)) {
      return AudioDetailRenameResult(detail: detail, renamed: false);
    }

    final newTarget = AudioDetailTarget(
      targetType: oldTarget.targetType,
      targetPath: newPath,
    );
    if (oldTarget.isLibraryRootFolder) {
      await _retargetLibraryFolder(oldPath, newPath, safeName);
    } else {
      await _retargetSingleTrack(oldPath, newPath, safeName);
    }

    final renamedDetail = detail.copyWith(target: newTarget);
    final saveResult = await saveAudioDetail(renamedDetail);
    await deleteAudioDetail(oldTarget);
    _notifyListeners();
    return AudioDetailRenameResult(
      detail: saveResult.detail,
      renamed: true,
      backupFailed: saveResult.backupFailed,
    );
  }

  Future<String> _renameFileSystemAudioDetailTarget(
    AudioDetailTarget oldTarget,
    String oldPath,
    String safeName,
  ) async {
    final newPath = oldTarget.isLibraryRootFolder
        ? path.join(path.dirname(oldPath), safeName)
        : path.join(
            path.dirname(oldPath),
            '$safeName${path.extension(oldPath)}',
          );
    if (PathMatcher.equalsNormalized(oldPath, newPath)) return newPath;
    if (oldTarget.isLibraryRootFolder) {
      await Directory(oldPath).rename(newPath);
    } else {
      await File(oldPath).rename(newPath);
    }
    return newPath;
  }

  Future<String> _renameContentAudioDetailTarget(
    AudioDetailTarget oldTarget,
    String safeName,
  ) async {
    final name = oldTarget.isLibraryRootFolder
        ? safeName
        : '$safeName${_contentFileExtension(oldTarget.targetPath)}';
    final raw = await AudioProvider._fileCacheChannel
        .invokeMapMethod<String, Object?>(FileCacheMethod.renameDocument, {
          'path': oldTarget.targetPath,
          'name': name,
        });
    final renamedPath = raw?['path'] as String?;
    if (renamedPath == null || renamedPath.isEmpty) {
      throw const AudioDetailRenameException('renameFailed');
    }
    return renamedPath;
  }

  String _contentFileExtension(String targetPath) {
    final segment = PathMatcher.lastContentPathSegment(targetPath);
    final decoded = segment == null
        ? targetPath
        : PathMatcher.safeDecodeComponent(segment).replaceAll('\\', '/');
    return path.extension(decoded);
  }

  Future<void> _retargetLibraryFolder(
    String oldFolderPath,
    String newFolderPath,
    String folderName,
  ) async {
    final updatedTracks = <MusicTrack>[];
    for (var i = 0; i < _library.length; i++) {
      final track = _library[i];
      if (!PathMatcher.isWithinOrEqual(track.path, oldFolderPath)) continue;

      final nextTrackPath = _replacePathPrefix(
        track.path,
        oldFolderPath,
        newFolderPath,
      );
      final nextGroupKey =
          PathMatcher.isWithinOrEqual(track.groupKey, oldFolderPath)
          ? _replacePathPrefix(track.groupKey, oldFolderPath, newFolderPath)
          : track.groupKey;
      final updatedTrack = _copyTrack(
        track,
        path: nextTrackPath,
        groupKey: nextGroupKey,
        groupTitle: PathMatcher.equalsNormalized(nextGroupKey, newFolderPath)
            ? folderName
            : PathDisplay.folderName(nextGroupKey),
        groupSubtitle: PathDisplay.displayPathFor(nextGroupKey),
        coverCachePath: _retargetNullablePath(
          track.coverCachePath,
          oldFolderPath,
          newFolderPath,
        ),
        lyricsPath: _retargetNullablePath(
          track.lyricsPath,
          oldFolderPath,
          newFolderPath,
        ),
        manualCoverPath: _retargetNullablePath(
          track.manualCoverPath,
          oldFolderPath,
          newFolderPath,
        ),
      );
      _library[i] = updatedTrack;
      updatedTracks.add(updatedTrack);
    }

    for (var i = 0; i < _watchedFolders.length; i++) {
      if (PathMatcher.equalsNormalized(_watchedFolders[i], oldFolderPath)) {
        _watchedFolders[i] = newFolderPath;
      }
    }
    for (var i = 0; i < _watchedLibraries.length; i++) {
      if (PathMatcher.equalsNormalized(_watchedLibraries[i], oldFolderPath)) {
        _watchedLibraries[i] = newFolderPath;
      }
    }

    for (var i = 0; i < _libraryNodeOrder.length; i++) {
      if (PathMatcher.equalsNormalized(_libraryNodeOrder[i], oldFolderPath)) {
        _libraryNodeOrder[i] = newFolderPath;
      }
    }

    for (var i = 0; i < _groupOrder.length; i++) {
      if (PathMatcher.isWithinOrEqual(_groupOrder[i], oldFolderPath)) {
        _groupOrder[i] = _replacePathPrefix(
          _groupOrder[i],
          oldFolderPath,
          newFolderPath,
        );
      }
    }

    _retargetActiveSessions(oldFolderPath, newFolderPath);
    _clearResolvedCoverPaths();
    _syncGroupOrderFromLibrary();
    _rebuildLibraryIndexes();
    await _audioDatabaseRepository.saveAllTracks(_library);
    await _saveWatchedFolders();
    await _saveWatchedLibraries();
    await _saveGroupOrder();
    await _saveLibraryNodeOrder();
    await _saveSessionState();
  }

  Future<void> _retargetSingleTrack(
    String oldTrackPath,
    String newTrackPath,
    String displayName,
  ) async {
    final track = _libraryByPath[oldTrackPath];
    if (track != null) {
      final updatedTrack = _copyTrack(
        track,
        path: newTrackPath,
        displayName: displayName,
      );
      final index = _library.indexWhere((item) => item.path == oldTrackPath);
      if (index >= 0) _library[index] = updatedTrack;
      _retargetActiveSessions(oldTrackPath, newTrackPath);
      for (var i = 0; i < _libraryNodeOrder.length; i++) {
        if (PathMatcher.equalsNormalized(_libraryNodeOrder[i], oldTrackPath)) {
          _libraryNodeOrder[i] = newTrackPath;
        }
      }
      _clearResolvedCoverPaths();
      _rebuildLibraryIndexes();
      await _audioDatabaseRepository.deleteTracks([oldTrackPath]);
      await _audioDatabaseRepository.upsertTracks([updatedTrack]);
      await _saveSessionState();
    }
  }

  Future<void> _setFolderManualCover(
    String folderPath,
    String coverPath,
  ) async {
    final rootFolder = getRootFolderPath(folderPath);
    final targetPath = rootFolder.isNotEmpty ? rootFolder : folderPath;

    final updatedTracks = <MusicTrack>[];
    for (var i = 0; i < _library.length; i++) {
      final track = _library[i];
      if (!PathMatcher.isWithinOrEqual(track.path, targetPath)) continue;
      final updatedTrack = _copyTrack(track, manualCoverPath: coverPath);
      _library[i] = updatedTrack;
      _libraryByPath[track.path] = updatedTrack;
      updatedTracks.add(updatedTrack);
    }
    if (updatedTracks.isEmpty) return;
    _clearResolvedCoverPaths();
    _markActiveSessionsDirty();
    await _audioDatabaseRepository.upsertTracks(updatedTracks);
    _syncNotificationState();
    _notifyListeners();
  }

  void _retargetActiveSessions(String oldPath, String newPath) {
    for (final session in _sessions.values) {
      if (!PathMatcher.isWithinOrEqual(session.currentTrackPath, oldPath)) {
        continue;
      }
      final nextPath = _replacePathPrefix(
        session.currentTrackPath,
        oldPath,
        newPath,
      );
      session.currentTrackPath = nextPath;
      if (session.loadedPath != null &&
          PathMatcher.isWithinOrEqual(session.loadedPath!, oldPath)) {
        session.loadedPath = _replacePathPrefix(
          session.loadedPath!,
          oldPath,
          newPath,
        );
      }
    }
    _markActiveSessionsDirty();
  }

  String? _retargetNullablePath(String? value, String oldRoot, String newRoot) {
    if (value == null || !PathMatcher.isWithinOrEqual(value, oldRoot)) {
      return value;
    }
    return _replacePathPrefix(value, oldRoot, newRoot);
  }

  String _replacePathPrefix(String value, String oldRoot, String newRoot) {
    return PathMatcher.replaceWithinOrEqual(value, oldRoot, newRoot);
  }

  String _safeFileName(String value) {
    return PathDisplay.safeFileName(value);
  }

  MusicTrack _copyTrack(
    MusicTrack track, {
    String? path,
    String? displayName,
    String? groupKey,
    String? groupTitle,
    String? groupSubtitle,
    String? coverCachePath,
    String? lyricsPath,
    String? manualCoverPath,
  }) {
    return MusicTrack(
      path: path ?? track.path,
      displayName: displayName ?? track.displayName,
      groupKey: groupKey ?? track.groupKey,
      groupTitle: groupTitle ?? track.groupTitle,
      groupSubtitle: groupSubtitle ?? track.groupSubtitle,
      isSingle: track.isSingle,
      scannedAt: track.scannedAt,
      fileSizeBytes: track.fileSizeBytes,
      modifiedAt: track.modifiedAt,
      lastPlayedPosition: track.lastPlayedPosition,
      lastPlayedAt: track.lastPlayedAt,
      isFavorite: track.isFavorite,
      tags: track.tags,
      coverCachePath: coverCachePath ?? track.coverCachePath,
      lyricsPath: lyricsPath ?? track.lyricsPath,
      manualCoverPath: manualCoverPath ?? track.manualCoverPath,
      duration: track.duration,
    );
  }
}

class AudioDetailRenameResult {
  const AudioDetailRenameResult({
    required this.detail,
    required this.renamed,
    this.backupFailed = false,
  });

  final AudioDetail detail;
  final bool renamed;
  final bool backupFailed;
}

class AudioDetailRenameException implements Exception {
  const AudioDetailRenameException(this.reason);

  final String reason;
}
