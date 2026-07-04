part of 'audio_provider.dart';

class DlsiteMetadataQuery {
  const DlsiteMetadataQuery({
    this.rjCode,
    this.searchTitles = const <String>[],
  });

  factory DlsiteMetadataQuery.fromDetail(AudioDetail detail) {
    final rjCode = AudioDetail.findRjCodeInText(detail.rjCode);
    if (rjCode != null) {
      return DlsiteMetadataQuery(rjCode: rjCode);
    }
    final seen = <String>{};
    final searchTitles =
        <String>[
              detail.target.isLibraryRootFolder
                  ? PathDisplay.folderName(detail.target.targetPath)
                  : PathDisplay.fileName(
                      detail.target.targetPath,
                      withoutExtension: true,
                    ),
              detail.workTitle,
            ]
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty && seen.add(value))
            .toList(growable: false);
    return DlsiteMetadataQuery(searchTitles: searchTitles);
  }

  final String? rjCode;
  final List<String> searchTitles;

  bool get hasQuery => rjCode != null || searchTitles.isNotEmpty;
}

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
    return _audioDetailCacheService.load(target);
  }

  Future<AudioDetailSaveResult> saveAudioDetail(AudioDetail detail) async {
    final result = await _audioDetailCacheService.save(detail);
    _librarySnapshotCacheService.markDetailChanged(result.detail);
    _notifyListeners();
    return result;
  }

  Future<void> deleteAudioDetail(AudioDetailTarget target) async {
    await _audioDetailCacheService.delete(target);
    _librarySnapshotCacheService.markDetailChanged();
    _notifyListeners();
  }

  Future<AudioDetailSaveResult?> prefillAudioDetailRjCodeFromText(
    AudioDetailTarget target,
    String text,
  ) async {
    final result = await _audioDetailCacheService.prefillRjCodeFromText(
      target,
      text,
    );
    if (result != null) {
      _librarySnapshotCacheService.markDetailChanged(result.detail);
      _notifyListeners();
    }
    return result;
  }

  Future<DlsiteMetadata> fetchDlsiteMetadata(String rjCode) {
    return _dlsiteMetadataService.fetchByRjCode(
      rjCode,
      language: _dlsiteMetadataLanguage,
    );
  }

  Future<List<DlsiteMetadata>> searchDlsiteMetadataByTitles(
    Iterable<String> titles,
  ) {
    return _dlsiteMetadataService.searchByTitleCandidates(
      titles,
      language: _dlsiteMetadataLanguage,
    );
  }

  Future<DlsiteMetadata> fetchPreferredMetadata(String rjCode) async {
    DlsiteMetadata? asmrMetadata;
    try {
      asmrMetadata = await _asmrMetadataService.fetchByRjCode(
        rjCode,
        language: _dlsiteMetadataLanguage,
      );
    } catch (_) {
      return fetchDlsiteMetadata(rjCode);
    }
    if (!_metadataHasMissingValue(asmrMetadata)) {
      return asmrMetadata;
    }
    try {
      final dlsiteMetadata = await fetchDlsiteMetadata(rjCode);
      return _mergeMetadata(asmrMetadata, dlsiteMetadata);
    } catch (_) {
      return asmrMetadata;
    }
  }

  Future<List<DlsiteMetadata>> searchPreferredMetadataByTitles(
    Iterable<String> titles,
  ) async {
    List<DlsiteMetadata>? asmrResults;
    try {
      asmrResults = await _asmrMetadataService.searchByTitleCandidates(
        titles,
        language: _dlsiteMetadataLanguage,
      );
    } catch (_) {
      return searchDlsiteMetadataByTitles(titles);
    }

    if (asmrResults.every((metadata) => !_metadataHasMissingValue(metadata))) {
      return asmrResults;
    }
    try {
      final dlsiteResults = await searchDlsiteMetadataByTitles(titles);
      return _mergeMetadataLists(asmrResults, dlsiteResults);
    } catch (_) {
      return asmrResults;
    }
  }

  bool _metadataHasMissingValue(DlsiteMetadata metadata) {
    return metadata.rjCode.trim().isEmpty ||
        metadata.workTitle.trim().isEmpty ||
        metadata.circleName.trim().isEmpty ||
        metadata.voiceActors.isEmpty ||
        metadata.tags.isEmpty ||
        metadata.releaseDate == null ||
        metadata.salesCount == null ||
        metadata.rating == null;
  }

  List<DlsiteMetadata> _mergeMetadataLists(
    List<DlsiteMetadata> primary,
    List<DlsiteMetadata> fallback,
  ) {
    final fallbackByKey = <String, DlsiteMetadata>{};
    for (final metadata in fallback) {
      final key = _metadataMergeKey(metadata);
      if (key.isNotEmpty) {
        fallbackByKey.putIfAbsent(key, () => metadata);
      }
    }

    final singleFallback = primary.length == 1 && fallback.length == 1
        ? fallback.single
        : null;
    return primary
        .map((metadata) {
          final fallbackMetadata =
              fallbackByKey[_metadataMergeKey(metadata)] ?? singleFallback;
          return fallbackMetadata == null
              ? metadata
              : _mergeMetadata(metadata, fallbackMetadata);
        })
        .toList(growable: false);
  }

  String _metadataMergeKey(DlsiteMetadata metadata) {
    final rjCode = metadata.rjCode.trim().toUpperCase();
    if (rjCode.isNotEmpty) return 'rj:$rjCode';
    final title = metadata.workTitle.trim().toLowerCase();
    return title.isEmpty ? '' : 'title:$title';
  }

  DlsiteMetadata _mergeMetadata(
    DlsiteMetadata primary,
    DlsiteMetadata fallback,
  ) {
    return primary.copyWith(
      rjCode: _fallbackString(primary.rjCode, fallback.rjCode),
      workTitle: _fallbackString(primary.workTitle, fallback.workTitle),
      circleName: _fallbackString(primary.circleName, fallback.circleName),
      voiceActors: primary.voiceActors.isNotEmpty
          ? primary.voiceActors
          : fallback.voiceActors,
      tags: primary.tags.isNotEmpty ? primary.tags : fallback.tags,
      releaseDate: primary.releaseDate ?? fallback.releaseDate,
      salesCount: primary.salesCount ?? fallback.salesCount,
      rating: primary.rating ?? fallback.rating,
      coverUrl: _fallbackNullableString(primary.coverUrl, fallback.coverUrl),
    );
  }

  String _fallbackString(String primary, String fallback) {
    return primary.trim().isNotEmpty ? primary : fallback;
  }

  String? _fallbackNullableString(String? primary, String? fallback) {
    return primary != null && primary.trim().isNotEmpty ? primary : fallback;
  }

  DlsiteMetadataQuery buildDlsiteMetadataQuery(AudioDetail detail) {
    return DlsiteMetadataQuery.fromDetail(detail);
  }

  Future<DlsiteMetadataApplyResult> applyDlsiteMetadata(
    AudioDetail detail,
    DlsiteMetadata metadata, {
    required bool saveCover,
    bool missingOnly = false,
  }) async {
    final nextDetail = detail.copyWith(
      rjCode: _metadataStringValue(
        current: detail.rjCode,
        fetched: metadata.rjCode,
        missingOnly: missingOnly,
      ),
      workTitle: _metadataStringValue(
        current: detail.workTitle,
        fetched: metadata.workTitle,
        missingOnly: missingOnly,
      ),
      circleName: _metadataStringValue(
        current: detail.circleName,
        fetched: metadata.circleName,
        missingOnly: missingOnly,
      ),
      voiceActors: _metadataListValue(
        current: detail.voiceActors,
        fetched: metadata.voiceActors,
        missingOnly: missingOnly,
      ),
      tags: _metadataListValue(
        current: detail.tags,
        fetched: metadata.tags,
        missingOnly: missingOnly,
      ),
      releaseDate: missingOnly && detail.releaseDate != null
          ? detail.releaseDate
          : metadata.releaseDate,
      salesCount: missingOnly && detail.salesCount != null
          ? detail.salesCount
          : metadata.salesCount,
      rating: missingOnly && detail.rating != null
          ? detail.rating
          : metadata.rating,
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
          language: _dlsiteMetadataLanguage,
        );
        await setFolderManualCover(
          nextDetail.target.targetPath,
          coverPath,
          newlySaved: true,
        );
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

  String _metadataStringValue({
    required String current,
    required String fetched,
    required bool missingOnly,
  }) {
    return missingOnly && current.trim().isNotEmpty ? current : fetched;
  }

  List<String> _metadataListValue({
    required List<String> current,
    required List<String> fetched,
    required bool missingOnly,
  }) {
    return missingOnly && current.isNotEmpty ? current : fetched;
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

    final renamedDetail = detail.copyWith(
      target: newTarget,
      cardCoverPath: _retargetNullablePath(
        detail.cardCoverPath,
        oldPath,
        newPath,
      ),
    );
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
    // If the document already has this name, skip the rename to avoid
    // provider errors on some Android versions when the name is unchanged.
    final currentName = PathMatcher.lastContentPathSegment(
      oldTarget.targetPath,
    );
    if (currentName != null) {
      final decodedCurrent = PathMatcher.safeDecodeComponent(currentName);
      if (decodedCurrent == name) return oldTarget.targetPath;
    }
    final raw = await AudioProvider._fileCacheGateway.renameDocument(
      path: oldTarget.targetPath,
      name: name,
    );
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
    _rememberRetargetedPath(oldFolderPath, newFolderPath);
    await _retargetFolderCoverSelection(oldFolderPath, newFolderPath);
    await _audioDatabaseRepository.retargetTimeSegmentLabelsWithinPath(
      oldRoot: oldFolderPath,
      newRoot: newFolderPath,
    );
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

    _retargetLibraryExclusions(oldFolderPath, newFolderPath);
    final retargetedEntries = _retargetLibraryEntries(
      oldFolderPath,
      newFolderPath,
      folderName,
    );
    _retargetActiveSessions(oldFolderPath, newFolderPath);
    _invalidateResolvedCoverScopes([oldFolderPath, newFolderPath]);
    _syncGroupOrderFromLibrary();
    _rebuildLibraryIndexes();
    await _audioDatabaseRepository.saveAllTracks(_library);
    await _audioDatabaseRepository.deleteLibraryEntriesForLibrary(
      oldFolderPath,
    );
    if (retargetedEntries.isNotEmpty) {
      await _audioDatabaseRepository.upsertLibraryEntries(retargetedEntries);
    }
    await _saveWatchedFolders();
    await _saveWatchedLibraries();
    await _saveLibraryExclusions();
    await _saveGroupOrder();
    await _saveLibraryNodeOrder();
    await _saveSessionState();
  }

  void _retargetLibraryExclusions(String oldRoot, String newRoot) {
    if (_excludedLibraryFolders.isEmpty && _excludedLibraryTracks.isEmpty) {
      return;
    }

    Map<String, Set<String>> retarget(Map<String, Set<String>> source) {
      final result = <String, Set<String>>{};
      for (final entry in source.entries) {
        final nextKey = PathMatcher.equalsNormalized(entry.key, oldRoot)
            ? newRoot
            : entry.key;
        final nextValues = entry.value
            .map(
              (value) => PathMatcher.isWithinOrEqual(value, oldRoot)
                  ? _replacePathPrefix(value, oldRoot, newRoot)
                  : value,
            )
            .toSet();
        result.putIfAbsent(nextKey, () => <String>{}).addAll(nextValues);
      }
      return result;
    }

    final nextFolderExclusions = retarget(_excludedLibraryFolders);
    final nextTrackExclusions = retarget(_excludedLibraryTracks);
    _excludedLibraryFolders
      ..clear()
      ..addAll(nextFolderExclusions);
    _excludedLibraryTracks
      ..clear()
      ..addAll(nextTrackExclusions);
  }

  List<LibraryEntry> _retargetLibraryEntries(
    String oldRoot,
    String newRoot,
    String folderName,
  ) {
    final existingEntries = _libraryService.libraryEntriesByLibrary.remove(
      oldRoot,
    );
    if (existingEntries == null || existingEntries.isEmpty) {
      return const <LibraryEntry>[];
    }

    final retargetedEntries = existingEntries.values
        .map(
          (entry) => _retargetLibraryEntry(
            entry,
            oldRoot: oldRoot,
            newRoot: newRoot,
            folderName: folderName,
          ),
        )
        .toList(growable: false);
    _libraryService.libraryEntriesByLibrary[newRoot] = {
      for (final entry in retargetedEntries) entry.path: entry,
    };
    _libraryService.markStructureChanged();
    _librarySnapshotCacheService.markStructureChanged();
    return retargetedEntries;
  }

  LibraryEntry _retargetLibraryEntry(
    LibraryEntry entry, {
    required String oldRoot,
    required String newRoot,
    required String folderName,
  }) {
    final nextPath = PathMatcher.isWithinOrEqual(entry.path, oldRoot)
        ? _replacePathPrefix(entry.path, oldRoot, newRoot)
        : entry.path;
    final nextParentPath =
        entry.parentPath != null &&
            PathMatcher.isWithinOrEqual(entry.parentPath!, oldRoot)
        ? _replacePathPrefix(entry.parentPath!, oldRoot, newRoot)
        : entry.parentPath;
    if (entry.isFolder) {
      return LibraryEntry.folder(
        libraryPath: newRoot,
        path: nextPath,
        parentPath: nextParentPath,
        state: entry.state,
        displayName: entry.displayName,
      );
    }

    final nextGroupKey = PathMatcher.isWithinOrEqual(entry.groupKey, oldRoot)
        ? _replacePathPrefix(entry.groupKey, oldRoot, newRoot)
        : entry.groupKey;
    final nextGroupTitle = PathMatcher.equalsNormalized(nextGroupKey, newRoot)
        ? folderName
        : PathDisplay.folderName(nextGroupKey);
    return LibraryEntry(
      libraryPath: newRoot,
      path: nextPath,
      kind: entry.kind,
      state: entry.state,
      parentPath: nextParentPath,
      displayName: entry.displayName,
      groupKey: nextGroupKey,
      groupTitle: nextGroupTitle,
      groupSubtitle: PathDisplay.displayPathFor(nextGroupKey),
      isSingle: entry.isSingle,
      isVideo: entry.isVideo,
      scannedAt: entry.scannedAt,
      fileSizeBytes: entry.fileSizeBytes,
      modifiedAt: entry.modifiedAt,
    );
  }

  Future<void> _retargetSingleTrack(
    String oldTrackPath,
    String newTrackPath,
    String displayName,
  ) async {
    _rememberRetargetedPath(oldTrackPath, newTrackPath);
    await _audioDatabaseRepository.retargetTimeSegmentLabels(
      oldTrackKey: PathMatcher.normalize(oldTrackPath),
      newTrackKey: PathMatcher.normalize(newTrackPath),
    );
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
      isVideo: track.isVideo,
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
