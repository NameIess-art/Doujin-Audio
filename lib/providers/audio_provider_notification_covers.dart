part of 'audio_provider.dart';

const List<String> _preferredCoverBasenames = <String>[
  'cover',
  'folder',
  'front',
  'album',
  'artwork',
  'poster',
];

String? _mostSpecificContainingRoot(Iterable<String> roots, String value) {
  String? bestMatch;
  for (final root in roots) {
    if (!PathMatcher.isWithinOrEqual(value, root)) {
      continue;
    }
    if (bestMatch == null || root.length > bestMatch.length) {
      bestMatch = root;
    }
  }
  return bestMatch;
}

String? _libraryWorkScopeFolderPath(String libraryRoot, String groupKey) {
  final relativePath = PathMatcher.relativeWithin(groupKey, libraryRoot);
  if (relativePath == null || relativePath.isEmpty) {
    return null;
  }

  final firstSegment = relativePath
      .split(RegExp(r'[\\/]+'))
      .firstWhere((segment) => segment.isNotEmpty, orElse: () => '');
  if (firstSegment.isEmpty) {
    return null;
  }

  final normalizedRoot = PathMatcher.normalize(libraryRoot);
  if (PathMatcher.isContentUri(normalizedRoot)) {
    return '$normalizedRoot::$firstSegment';
  }

  return path.normalize(path.join(normalizedRoot, firstSegment));
}

String? _resolveCoverScopeFolderPath(
  AudioProvider provider,
  MusicTrack? track, {
  String? trackPath,
}) {
  final pathValue = track?.path ?? trackPath;
  if (pathValue == null || pathValue.isEmpty) {
    return null;
  }

  final groupKey = track?.groupKey.trim() ?? '';

  final watchedFolder =
      _mostSpecificContainingRoot(provider._watchedFolders, pathValue) ??
      (groupKey.isEmpty
          ? null
          : _mostSpecificContainingRoot(provider._watchedFolders, groupKey));
  if (watchedFolder != null && watchedFolder.isNotEmpty) {
    return watchedFolder;
  }

  final watchedLibrary =
      (groupKey.isEmpty
          ? null
          : _mostSpecificContainingRoot(
              provider._watchedLibraries,
              groupKey,
            )) ??
      _mostSpecificContainingRoot(provider._watchedLibraries, pathValue);
  if (watchedLibrary != null && watchedLibrary.isNotEmpty) {
    final workScope = groupKey.isEmpty
        ? null
        : _libraryWorkScopeFolderPath(watchedLibrary, groupKey);
    return workScope ?? watchedLibrary;
  }

  if (groupKey.isNotEmpty) {
    return PathMatcher.normalize(groupKey);
  }

  if (PathMatcher.isContentUri(pathValue)) {
    return null;
  }

  final directoryPath = path.dirname(pathValue);
  if (directoryPath.isEmpty || directoryPath == '.') {
    return null;
  }
  return directoryPath;
}

int _coverPriority(String baseName) {
  final exactMatchIndex = _preferredCoverBasenames.indexOf(baseName);
  if (exactMatchIndex >= 0) {
    return exactMatchIndex;
  }
  for (var i = 0; i < _preferredCoverBasenames.length; i++) {
    if (baseName.contains(_preferredCoverBasenames[i])) {
      return 100 + i;
    }
  }
  return 200;
}

int _compareCoverPaths(String leftPath, String rightPath) {
  final leftName = path.basename(leftPath);
  final rightName = path.basename(rightPath);
  final leftBase = path.basenameWithoutExtension(leftName).toLowerCase();
  final rightBase = path.basenameWithoutExtension(rightName).toLowerCase();
  final scoreCompare = _coverPriority(
    leftBase,
  ).compareTo(_coverPriority(rightBase));
  if (scoreCompare != 0) {
    return scoreCompare;
  }
  final nameCompare = leftBase.compareTo(rightBase);
  if (nameCompare != 0) {
    return nameCompare;
  }
  return leftPath.toLowerCase().compareTo(rightPath.toLowerCase());
}

extension AudioProviderNotificationCovers on AudioProvider {
  Future<void> _resumeNotificationSession(PlaybackSession session) async {
    if (session.isLoading || session.state.playing) return;
    _notificationFocusSessionId = session.id;
    if (session.state.processingState == ProcessingState.completed) {
      await _prepareAndPlay(session, nextPath: session.currentTrackPath);
      return;
    }
    await _startSessionPlayback(session, shouldStartTriggerCountdown: true);
  }

  String _notificationTitleForSession(PlaybackSession session) {
    final trackPath = session.currentTrackPath;
    final track = trackByPath(trackPath);
    final artPath = coverPathForTrack(track, trackPath: trackPath);
    if (artPath == null) {
      unawaited(
        _resolveNotificationCoverPathForTrack(track, trackPath: trackPath),
      );
    }
    return track?.displayName ??
        path.basenameWithoutExtension(session.currentTrackPath);
  }

  List<String> _notificationOverviewTitles(Iterable<PlaybackSession> sessions) {
    final uniqueTitles = <String>{};
    for (final session in sessions) {
      final title = _notificationTitleForSession(session);
      if (title.isNotEmpty) {
        uniqueTitles.add(title);
      }
    }
    return uniqueTitles.toList(growable: false);
  }

  String _notificationSummaryText(List<PlaybackSession> sessions) {
    final titles = _notificationOverviewTitles(sessions);
    if (titles.isEmpty) {
      return '${sessions.length} active sessions';
    }
    if (titles.length == 1) {
      return titles.first;
    }
    if (titles.length == 2) {
      return '${titles[0]} / ${titles[1]}';
    }
    return '${titles.first} +${titles.length - 1}';
  }

  String? coverPathForTrack(MusicTrack? track, {String? trackPath}) {
    if (track?.manualCoverPath != null) {
      return track!.manualCoverPath;
    }
    final pathValue = track?.path ?? trackPath;
    final coverSearchKey = _notificationCoverSearchKey(
      track,
      trackPath: pathValue,
    );
    if (coverSearchKey == null) {
      return null;
    }
    return _resolvedNotificationCoverPaths[coverSearchKey];
  }

  Future<String?> coverPathFutureForTrack(MusicTrack? track) {
    return _resolveNotificationCoverPathForTrack(track);
  }

  Future<String?> coverPathFutureForFolder(String folderPath) {
    return _resolveCoverPathForFolder(folderPath);
  }

  bool isCoverPathLoadingForFolder(String folderPath) {
    return _coverPathFutures.containsKey(PathMatcher.normalize(folderPath));
  }

  String? _notificationCoverSearchKey(MusicTrack? track, {String? trackPath}) {
    final pathValue = track?.path ?? trackPath;
    if (pathValue == null || pathValue.isEmpty) {
      return null;
    }
    if (track?.isSingle == true && track?.isVideo == true) {
      return PathMatcher.normalize(pathValue);
    }
    final scopedFolder = _resolveCoverScopeFolderPath(
      this,
      track,
      trackPath: pathValue,
    );
    if (scopedFolder != null && scopedFolder.isNotEmpty) {
      return PathMatcher.normalize(scopedFolder);
    }
    final directoryPath = path.dirname(pathValue);
    if (directoryPath.isEmpty || directoryPath == '.') {
      return null;
    }
    return PathMatcher.normalize(directoryPath);
  }

  Future<String?> _resolveNotificationCoverPathForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    final pathValue = track?.path ?? trackPath;
    final coverSearchKey = _notificationCoverSearchKey(
      track,
      trackPath: pathValue,
    );
    if (coverSearchKey == null) {
      return Future<String?>.value();
    }
    if (track?.manualCoverPath != null) {
      final manualPath = track!.manualCoverPath;
      _resolvedNotificationCoverPaths[coverSearchKey] = manualPath;
      return _resolvedNotificationCoverPathFutures.putIfAbsent(
        coverSearchKey,
        () => SynchronousFuture<String?>(manualPath),
      );
    }

    if (_resolvedNotificationCoverPaths.containsKey(coverSearchKey)) {
      return _resolvedNotificationCoverPathFutures.putIfAbsent(
        coverSearchKey,
        () => SynchronousFuture<String?>(
          _resolvedNotificationCoverPaths[coverSearchKey],
        ),
      );
    }

    return _notificationCoverPathFutures.putIfAbsent(coverSearchKey, () async {
      String? coverPath;
      if (pathValue != null) {
        final coverScopeFolder = _resolveCoverScopeFolderPath(
          this,
          track,
          trackPath: pathValue,
        );
        if (pathValue.startsWith('content://')) {
          if (track != null) {
            coverPath = await _resolveContentCoverPathForTrack(
              track,
              rootFolder: coverScopeFolder,
            );
          } else {
            coverPath = await _resolveContentCoverPathForFolder(
              coverScopeFolder ?? pathValue,
            );
          }
        } else {
          final candidateDirectories = <String>[
            coverScopeFolder ?? coverSearchKey,
          ];
          for (final candidateDirectory in candidateDirectories) {
            coverPath = await _findNotificationCoverPath(candidateDirectory);
            if (coverPath != null) {
              break;
            }
          }
        }
        if (coverPath == null &&
            track?.isSingle == true &&
            track?.isVideo == true) {
          coverPath = await _resolveVideoFramePathForTrack(track!);
        }
      }

      unawaited(
        _notificationCoverPathFutures.remove(coverSearchKey) ??
            Future<String?>.value(),
      );
      final previous = _resolvedNotificationCoverPaths[coverSearchKey];
      _resolvedNotificationCoverPaths[coverSearchKey] = coverPath;
      _resolvedNotificationCoverPathFutures[coverSearchKey] =
          SynchronousFuture<String?>(coverPath);

      if (previous != coverPath) {
        final anySessionUsesCover = activeSessions.any((s) {
          final t = trackByPath(s.currentTrackPath);
          return _notificationCoverSearchKey(t) == coverSearchKey;
        });
        if (anySessionUsesCover) {
          _syncNotificationState();
          _notifyListeners();
        }
      }

      return coverPath;
    });
  }

  Future<String?> _resolveVideoFramePathForTrack(MusicTrack track) async {
    try {
      return await AudioProvider._fileCacheChannel.invokeMethod<String>(
        FileCacheMethod.resolveVideoFrame,
        <String, dynamic>{
          'path': track.path,
          if (track.modifiedAt != null)
            'modifiedAtMs': track.modifiedAt!.millisecondsSinceEpoch,
        },
      );
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('AudioProvider._resolveVideoFramePathForTrack error: $e');
      return null;
    }
  }

  Future<String?> _resolveContentCoverPathForTrack(
    MusicTrack track, {
    String? rootFolder,
  }) async {
    try {
      return await AudioProvider._fileCacheChannel.invokeMethod<String>(
        'resolveTrackCover',
        <String, dynamic>{
          'path': track.path,
          'groupKey': track.groupKey,
          'rootFolder': rootFolder,
        },
      );
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('AudioProvider._resolveContentCoverPathForTrack error: $e');
      return null;
    }
  }

  Future<String?> _resolveCoverPathForFolder(String folderPath) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);

    if (_resolvedCoverPaths.containsKey(normalizedFolderPath)) {
      return _resolvedCoverPathFutures.putIfAbsent(
        normalizedFolderPath,
        () => SynchronousFuture<String?>(
          _resolvedCoverPaths[normalizedFolderPath],
        ),
      );
    }

    return _coverPathFutures.putIfAbsent(normalizedFolderPath, () async {
      String? coverPath;

      if (_manualCoverByScopeCache.isEmpty) {
        _rebuildManualCoverByScopeCache();
      }
      coverPath = _manualCoverByScopeCache[normalizedFolderPath];

      coverPath ??= PathMatcher.isContentUri(normalizedFolderPath)
          ? await _resolveContentCoverPathForFolder(normalizedFolderPath)
          : await _findNotificationCoverPath(normalizedFolderPath);
      unawaited(
        _coverPathFutures.remove(normalizedFolderPath) ??
            Future<String?>.value(),
      );

      final previous = _resolvedCoverPaths[normalizedFolderPath];
      _resolvedCoverPaths[normalizedFolderPath] = coverPath;
      _resolvedCoverPathFutures[normalizedFolderPath] =
          SynchronousFuture<String?>(coverPath);

      if (previous != coverPath) {
        _notifyListeners();
      }

      return coverPath;
    });
  }

  Future<String?> _resolveContentCoverPathForFolder(String folderPath) async {
    MusicTrack? firstTrack;
    for (final track in _library) {
      if (PathMatcher.isWithinOrEqual(track.path, folderPath) ||
          PathMatcher.isWithinOrEqual(track.groupKey, folderPath)) {
        firstTrack = track;
        break;
      }
    }

    try {
      return await AudioProvider._fileCacheChannel
          .invokeMethod<String>('resolveTrackCover', <String, dynamic>{
            'path': firstTrack?.path ?? folderPath,
            'groupKey': firstTrack?.groupKey,
            'rootFolder': folderPath,
          });
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('AudioProvider._resolveContentCoverPathForFolder error: $e');
      return null;
    }
  }

  Future<String?> _findNotificationCoverPath(String folderPath) async {
    final normalizedFolderPath = path.normalize(folderPath);
    if (_notificationCoverSearchMisses.contains(normalizedFolderPath)) {
      return null;
    }
    if (_resolvedCoverPaths.containsKey(normalizedFolderPath)) {
      return _resolvedCoverPaths[normalizedFolderPath];
    }
    if (_resolvedNotificationCoverPaths.containsKey(normalizedFolderPath)) {
      return _resolvedNotificationCoverPaths[normalizedFolderPath];
    }

    final directory = Directory(folderPath);
    if (!await directory.exists()) {
      _notificationCoverSearchMisses.add(normalizedFolderPath);
      return null;
    }

    try {
      // First pass: check common cover file names in the top-level directory
      // (non-recursive) — this covers the vast majority of cases.
      final candidates = <String>[];
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final extension = path.extension(entity.path).toLowerCase();
        if (!AudioProvider._supportedImageExtensions.contains(extension)) {
          continue;
        }
        candidates.add(entity.path);
      }
      if (candidates.isNotEmpty) {
        candidates.sort(_compareCoverPaths);
        _notificationCoverSearchMisses.remove(normalizedFolderPath);
        return candidates.first;
      }
    } catch (_) {
      // Recursive scan failed.
    }

    // Recursive search is disabled here to avoid sibling/unrelated child cover pollution.
    // The miss is cached so repeated lookups stay cheap.
    _notificationCoverSearchMisses.add(normalizedFolderPath);
    return null;
  }
}
