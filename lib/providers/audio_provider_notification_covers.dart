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
    final track = trackByPath(session.currentTrackPath);
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

  String? coverPathForTrack(MusicTrack? track) {
    final coverSearchKey = _notificationCoverSearchKey(track);
    if (coverSearchKey == null) {
      return null;
    }
    return _resolvedNotificationCoverPaths[coverSearchKey];
  }

  Future<String?> coverPathFutureForTrack(MusicTrack? track) {
    return _resolveNotificationCoverPathForTrack(track);
  }

  Future<String?> coverPathFutureForFolder(String folderPath) {
    if (folderPath.startsWith('content://')) {
      return Future<String?>.value();
    }
    return _resolveCoverPathForFolder(folderPath);
  }

  String? _notificationCoverSearchKey(MusicTrack? track) {
    if (track == null) {
      return null;
    }
    if (track.path.startsWith('content://')) {
      final groupKey = track.groupKey.trim();
      if (groupKey.isNotEmpty) {
        return 'content:$groupKey';
      }
      return 'content:${track.path}';
    }
    final directoryPath = path.dirname(track.path);
    if (directoryPath.isEmpty || directoryPath == '.') {
      return null;
    }
    return path.normalize(directoryPath);
  }

  Future<String?> _resolveNotificationCoverPathForTrack(MusicTrack? track) {
    final coverSearchKey = _notificationCoverSearchKey(track);
    if (coverSearchKey == null) {
      return Future<String?>.value();
    }
    if (track?.manualCoverPath != null) {
      return Future<String?>.value(track!.manualCoverPath);
    }

    if (_resolvedNotificationCoverPaths.containsKey(coverSearchKey)) {
      return Future<String?>.value(
        _resolvedNotificationCoverPaths[coverSearchKey],
      );
    }

    return _notificationCoverPathFutures.putIfAbsent(coverSearchKey, () async {
      String? coverPath;
      if (track != null) {
        if (track.path.startsWith('content://')) {
          coverPath = await _resolveContentCoverPathForTrack(track);
        } else {
          for (final candidateDirectory
              in _notificationCoverCandidateDirectories(track)) {
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

      if (previous != coverPath) {
        final focusedTrack = trackByPath(
          _notificationFocusedSession?.currentTrackPath ?? '',
        );
        if (_notificationCoverSearchKey(focusedTrack) == coverSearchKey) {
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
    final normalizedFolderPath = path.normalize(folderPath);

    if (_resolvedCoverPaths.containsKey(normalizedFolderPath)) {
      return Future<String?>.value(_resolvedCoverPaths[normalizedFolderPath]);
    }

    return _coverPathFutures.putIfAbsent(normalizedFolderPath, () async {
      String? coverPath;

      for (final track in _library) {
        final manualCoverPath = track.manualCoverPath;
        if (manualCoverPath == null) {
          continue;
        }
        if (PathMatcher.isWithinOrEqual(track.path, normalizedFolderPath)) {
          coverPath = manualCoverPath;
          break;
        }
      }

      coverPath ??= await _findNotificationCoverPath(normalizedFolderPath);
      unawaited(
        _coverPathFutures.remove(normalizedFolderPath) ?? Future<String?>.value(),
      );

      final previous = _resolvedCoverPaths[normalizedFolderPath];
      _resolvedCoverPaths[normalizedFolderPath] = coverPath;

      if (previous != coverPath) {
        _notifyListeners();
      }

      return coverPath;
    });
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
