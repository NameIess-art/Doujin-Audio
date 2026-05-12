part of 'audio_provider.dart';

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
      unawaited(_resolveNotificationCoverPathForTrack(track, trackPath: trackPath));
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
    final coverSearchKey = _notificationCoverSearchKey(track, trackPath: pathValue);
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

  String? _notificationCoverSearchKey(MusicTrack? track, {String? trackPath}) {
    final pathValue = track?.path ?? trackPath;
    if (pathValue == null || pathValue.isEmpty) {
      return null;
    }
    if (pathValue.startsWith('content://')) {
      final groupKey = track?.groupKey.trim() ?? '';
      if (groupKey.isNotEmpty) {
        return 'content:$groupKey';
      }
      return 'content:$pathValue';
    }
    final directoryPath = path.dirname(pathValue);
    if (directoryPath.isEmpty || directoryPath == '.') {
      return null;
    }
    return path.normalize(directoryPath);
  }

  Future<String?> _resolveNotificationCoverPathForTrack(MusicTrack? track, {String? trackPath}) {
    final pathValue = track?.path ?? trackPath;
    final coverSearchKey = _notificationCoverSearchKey(track, trackPath: pathValue);
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
        if (pathValue.startsWith('content://')) {
          if (track != null) {
            coverPath = await _resolveContentCoverPathForTrack(track);
          } else {
            coverPath = await _resolveContentCoverPathForFolder(pathValue);
          }
        } else {
          final candidateDirectories = track != null
              ? _notificationCoverCandidateDirectories(track)
              : [coverSearchKey];
          for (final candidateDirectory in candidateDirectories) {
            coverPath = await _findNotificationCoverPath(candidateDirectory);
            if (coverPath != null) {
              break;
            }
          }
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

  Future<String?> _resolveContentCoverPathForTrack(MusicTrack track) async {
    try {
      return await AudioProvider._fileCacheChannel.invokeMethod<String>(
        'resolveTrackCover',
        <String, dynamic>{'path': track.path, 'groupKey': track.groupKey},
      );
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('AudioProvider._resolveContentCoverPathForTrack error: $e');
      return null;
    }
  }

  List<String> _notificationCoverCandidateDirectories(MusicTrack track) {
    final coverSearchKey = _notificationCoverSearchKey(track);
    if (coverSearchKey == null) {
      return const <String>[];
    }

    final directories = <String>[coverSearchKey];
    for (final watchedFolder in _watchedFolders) {
      if (watchedFolder.startsWith('content://')) {
        continue;
      }
      final normalizedRoot = path.normalize(watchedFolder);
      if (!PathMatcher.isWithinOrEqual(coverSearchKey, normalizedRoot)) {
        continue;
      }

      var current = coverSearchKey;
      while (!path.equals(current, normalizedRoot)) {
        final parent = path.dirname(current);
        if (parent == current || directories.contains(parent)) {
          break;
        }
        directories.add(parent);
        current = parent;
      }
    }
    return directories;
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

      for (final track in _library) {
        final manualCoverPath = track.manualCoverPath;
        if (manualCoverPath == null) {
          continue;
        }
        if (PathMatcher.isWithinOrEqual(track.path, normalizedFolderPath) ||
            PathMatcher.isWithinOrEqual(track.groupKey, normalizedFolderPath)) {
          coverPath = manualCoverPath;
          break;
        }
      }

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
      final raw = await AudioProvider._fileCacheChannel
          .invokeMethod<List<dynamic>>('discoverRootImages', {
            'path': firstTrack?.path ?? folderPath,
            'groupKey': firstTrack?.groupKey,
            'rootFolder': folderPath,
          });
      if (raw == null) return null;
      for (final item in raw) {
        final value = item?.toString().trim() ?? '';
        if (value.isNotEmpty) return value;
      }
      return null;
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
      final shallowList = directory.list(followLinks: false);
      String? firstImage;
      await for (final entity in shallowList) {
        if (entity is! File) continue;
        final extension = path.extension(entity.path).toLowerCase();
        if (!AudioProvider._supportedImageExtensions.contains(extension)) {
          continue;
        }
        firstImage ??= entity.path;
        final basename = path
            .basenameWithoutExtension(entity.path)
            .toLowerCase();
        if (basename == 'cover' ||
            basename == 'folder' ||
            basename == 'album' ||
            basename == 'albumart' ||
            basename == 'front' ||
            basename == 'artwork') {
          _notificationCoverSearchMisses.remove(normalizedFolderPath);
          return entity.path;
        }
      }
      if (firstImage != null) {
        _notificationCoverSearchMisses.remove(normalizedFolderPath);
        return firstImage;
      }
    } catch (_) {
      // Shallow pass failed — fall through to recursive search.
    }

    // Second pass: recursive search with early exit on first image found.
    try {
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final extension = path.extension(entity.path).toLowerCase();
        if (AudioProvider._supportedImageExtensions.contains(extension)) {
          _notificationCoverSearchMisses.remove(normalizedFolderPath);
          return entity.path;
        }
      }
    } catch (_) {
      _notificationCoverSearchMisses.add(normalizedFolderPath);
      return null;
    }

    _notificationCoverSearchMisses.add(normalizedFolderPath);
    return null;
  }
}
