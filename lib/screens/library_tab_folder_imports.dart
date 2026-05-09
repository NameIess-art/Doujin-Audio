part of 'library_tab.dart';

extension _LibraryTabFolderImportActions on _LibraryTabState {
  Future<String?> _cachePickedFile(PlatformFile file, int index) async {
    final stream = file.readStream;
    final identifier = file.identifier;

    if (stream != null) {
      try {
        final cacheDir = await _persistentImportDirectory();
        if (!await cacheDir.exists()) await cacheDir.create(recursive: true);

        final extension = path.extension(file.name);
        final outPath = path.join(
          cacheDir.path,
          '${DateTime.now().microsecondsSinceEpoch}_$index${extension.isEmpty ? '.bin' : extension}',
        );

        final sink = File(outPath).openWrite();
        await stream.pipe(sink);
        await sink.close();
        return outPath;
      } catch (_) {}
    }

    if (Platform.isAndroid &&
        identifier != null &&
        identifier.startsWith('content://')) {
      try {
        return await _LibraryTabState._fileCacheChannel.invokeMethod<String>(
          'cacheFromUri',
          {'uri': identifier, 'name': file.name, 'index': index},
        );
      } catch (_) {}
    }
    return null;
  }

  Future<Directory> _persistentImportDirectory() async {
    final supportDir = await getApplicationSupportDirectory();
    return Directory(path.join(supportDir.path, 'nameless_audio_imports'));
  }

  Future<List<_ScannedTrack>?> _scanFolderViaNative(String folderPath) async {
    if (!Platform.isAndroid) return null;
    try {
      final data = await _LibraryTabState._fileCacheChannel
          .invokeMethod<List<dynamic>>('scanFolder', {'folder': folderPath});
      if (data == null) return null;

      final scanned = <_ScannedTrack>[];
      for (final item in data) {
        if (item is! Map) continue;
        final map = item.cast<Object?, Object?>();
        final scannedPath = map['path']?.toString().trim();
        if (scannedPath == null ||
            scannedPath.isEmpty ||
            !_isSupportedAudioFile(scannedPath)) {
          continue;
        }

        final nativeGroupKey = map['groupKey']?.toString().trim();
        final nativeGroupTitle = map['groupTitle']?.toString().trim();
        final nativeGroupSubtitle = map['groupSubtitle']?.toString().trim();

        final groupKey = (nativeGroupKey?.isNotEmpty ?? false)
            ? nativeGroupKey!
            : path.dirname(scannedPath);
        final groupTitle = (nativeGroupTitle?.isNotEmpty ?? false)
            ? nativeGroupTitle!
            : path.basename(groupKey);
        final groupSubtitle = (nativeGroupSubtitle?.isNotEmpty ?? false)
            ? nativeGroupSubtitle!
            : groupKey;
        final displayName = map['title']?.toString().trim();
        final resolvedPath = scannedPath.startsWith('content://')
            ? scannedPath
            : path.normalize(scannedPath);
        final scannedAtMs = map['scannedAtMs'] as num?;
        final modifiedAtMs = map['modifiedAtMs'] as num?;

        scanned.add(
          _ScannedTrack(
            path: resolvedPath,
            groupKey: groupKey,
            groupTitle: groupTitle,
            groupSubtitle: groupSubtitle,
            isSingle: false,
            displayName: displayName?.isEmpty ?? true ? null : displayName,
            scannedAt: scannedAtMs == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(scannedAtMs.toInt()),
            fileSizeBytes: (map['fileSizeBytes'] as num?)?.toInt(),
            modifiedAt: modifiedAtMs == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(modifiedAtMs.toInt()),
          ),
        );
      }
      return scanned;
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _listImmediateChildFolders(String folderPath) async {
    if (Platform.isAndroid) {
      try {
        final data = await _LibraryTabState._fileCacheChannel
            .invokeMethod<List<dynamic>>('listChildFolders', {
              'folder': folderPath,
            });
        if (data != null) {
          final folders = data
              .map((item) => item?.toString().trim() ?? '')
              .where((item) => item.isNotEmpty)
              .toList(growable: false);
          if (folders.isNotEmpty) {
            return folders;
          }
        }
      } catch (_) {}
    }

    final directory = Directory(folderPath);
    if (!await directory.exists()) return const <String>[];

    final childFolders = <String>[];
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! Directory) continue;
        childFolders.add(path.normalize(entity.path));
      }
    } catch (_) {
      return const <String>[];
    }

    childFolders.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return childFolders;
  }

  Future<List<String>> _listImmediateAudioFiles(String folderPath) async {
    final directory = Directory(folderPath);
    if (!await directory.exists()) return const <String>[];

    final audioFiles = <String>[];
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final normalizedPath = path.normalize(entity.path);
        if (_isSupportedAudioFile(normalizedPath)) {
          audioFiles.add(normalizedPath);
        }
      }
    } catch (_) {
      return const <String>[];
    }

    audioFiles.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return audioFiles;
  }

  Future<int> _importLibraryRootAudioFiles(
    String libraryRoot,
    AudioProvider provider,
    AppLanguageProvider i18n,
  ) async {
    final nativeTracks = await _scanFolderViaNative(libraryRoot);
    final candidates = nativeTracks == null
        ? await _singleTracksFromImmediateFiles(libraryRoot, provider, i18n)
        : nativeTracks
              .where((track) => _trackIsDirectlyInFolder(libraryRoot, track))
              .where(
                (track) =>
                    !provider.isLibraryPathExcluded(libraryRoot, track.path),
              )
              .map((track) => _singleTrackFromScanned(track, i18n))
              .toList(growable: false);

    if (candidates.isEmpty) return 0;
    final beforeCount = provider.library.length;
    provider.addOrReplaceTracks(candidates, notify: false);
    return provider.library.length - beforeCount;
  }

  Future<List<MusicTrack>> _singleTracksFromImmediateFiles(
    String libraryRoot,
    AudioProvider provider,
    AppLanguageProvider i18n,
  ) async {
    final rootAudioFiles = await _listImmediateAudioFiles(libraryRoot);
    final tracks = <MusicTrack>[];
    for (final filePath in rootAudioFiles) {
      if (provider.isLibraryPathExcluded(libraryRoot, filePath)) continue;
      tracks.add(await _singleTrackFromFilePath(filePath, i18n));
    }
    return tracks;
  }

  bool _trackIsDirectlyInFolder(String folderPath, _ScannedTrack track) {
    final normalizedFolderPath = path.normalize(folderPath);
    final normalizedGroupKey = path.normalize(track.groupKey);
    return path.equals(normalizedGroupKey, normalizedFolderPath) ||
        track.groupKey == folderPath;
  }

  Future<int> _importFolderIncrementally(
    String folderPath,
    AudioProvider provider,
    String? libraryRoot,
  ) async {
    final folder = Directory(folderPath);
    if (!await folder.exists()) return 0;

    final existingPaths = provider.library.map((t) => t.path).toSet();
    final pendingDirs = Queue<Directory>()..add(folder);
    final batch = <MusicTrack>[];
    const batchSize = 350;
    final baseFoundCount = provider.scanFoundCount;
    final baseDuplicateCount = provider.scanDuplicateCount;
    final baseFailureCount = provider.scanFailureCount;
    var added = 0;
    var duplicates = 0;
    var failures = 0;
    var dirsProcessed = 0;

    while (pendingDirs.isNotEmpty && mounted && provider.isScanning) {
      final currentDir = pendingDirs.removeFirst();
      late final Stream<FileSystemEntity> stream;
      try {
        stream = currentDir.list(followLinks: false);
      } catch (_) {
        failures++;
        continue;
      }

      dirsProcessed++;
      if (dirsProcessed % 8 == 0) {
        provider.setScanProgress(
          currentFolder: path.basename(currentDir.path),
          foundCount: baseFoundCount + added,
          duplicateCount: baseDuplicateCount + duplicates,
          failureCount: baseFailureCount + failures,
        );
      }

      try {
        await for (final entity in stream.handleError((_) {})) {
          if (!provider.isScanning) break;
          if (entity is Directory) {
            pendingDirs.add(entity);
            continue;
          }
          if (entity is! File) continue;

          final absolutePath = path.normalize(entity.path);
          if (!_isSupportedAudioFile(absolutePath)) continue;
          if (libraryRoot != null &&
              provider.isLibraryPathExcluded(libraryRoot, absolutePath)) {
            continue;
          }
          if (existingPaths.contains(absolutePath)) {
            duplicates++;
            continue;
          }
          existingPaths.add(absolutePath);

          final parentFolder = path.dirname(absolutePath);
          final folderName = path.basename(parentFolder);
          final fileStat = await entity.stat().catchError(
            (_) => FileStat.statSync(absolutePath),
          );

          batch.add(
            MusicTrack(
              path: absolutePath,
              displayName: path.basenameWithoutExtension(absolutePath),
              groupKey: parentFolder,
              groupTitle: folderName.isEmpty ? parentFolder : folderName,
              groupSubtitle: parentFolder,
              isSingle: false,
              scannedAt: DateTime.now(),
              fileSizeBytes: fileStat.size,
              modifiedAt: fileStat.modified,
            ),
          );
          added++;

          if (batch.length >= batchSize) {
            provider.addTracks(batch, notify: false);
            batch.clear();
            await Future<void>.delayed(Duration.zero);
          }
        }
      } catch (_) {
        failures++;
      }
    }
    provider.addTracks(batch, notify: false);
    provider.setScanProgress(
      foundCount: baseFoundCount + added,
      duplicateCount: baseDuplicateCount + duplicates,
      failureCount: baseFailureCount + failures,
    );
    return added;
  }

  bool _isSupportedAudioFile(String filePath) {
    if (filePath.toLowerCase().endsWith('.flac') ||
        filePath.toLowerCase().endsWith('.wav')) {
      return true;
    }
    final mimeType = lookupMimeType(filePath);
    if (mimeType == null) return true;
    return mimeType.startsWith('audio/') || mimeType == 'application/ogg';
  }

  MusicTrack _trackFromScanned(_ScannedTrack track) {
    return MusicTrack(
      path: track.path,
      displayName:
          track.displayName ?? path.basenameWithoutExtension(track.path),
      groupKey: track.groupKey,
      groupTitle: track.groupTitle,
      groupSubtitle: track.groupSubtitle,
      isSingle: track.isSingle,
      scannedAt: track.scannedAt ?? DateTime.now(),
      fileSizeBytes: track.fileSizeBytes,
      modifiedAt: track.modifiedAt,
    );
  }

  MusicTrack _singleTrackFromScanned(
    _ScannedTrack track,
    AppLanguageProvider i18n,
  ) {
    return MusicTrack(
      path: track.path,
      displayName:
          track.displayName ?? path.basenameWithoutExtension(track.path),
      groupKey: '__single_files__',
      groupTitle: i18n.tr('imported_files'),
      groupSubtitle: i18n.tr('manually_selected_files'),
      isSingle: true,
      scannedAt: track.scannedAt ?? DateTime.now(),
      fileSizeBytes: track.fileSizeBytes,
      modifiedAt: track.modifiedAt,
    );
  }

  Future<MusicTrack> _singleTrackFromFilePath(
    String filePath,
    AppLanguageProvider i18n,
  ) async {
    FileStat? fileStat;
    try {
      fileStat = await File(filePath).stat();
    } catch (_) {}
    return MusicTrack(
      path: filePath,
      displayName: path.basenameWithoutExtension(filePath),
      groupKey: '__single_files__',
      groupTitle: i18n.tr('imported_files'),
      groupSubtitle: i18n.tr('manually_selected_files'),
      isSingle: true,
      scannedAt: DateTime.now(),
      fileSizeBytes: fileStat?.size,
      modifiedAt: fileStat?.modified,
    );
  }

  List<_ScannedTrack> _filterExcludedScannedTracks(
    AudioProvider provider,
    String? libraryRoot,
    List<_ScannedTrack> tracks,
  ) {
    if (libraryRoot == null) return tracks;
    return tracks
        .where(
          (track) => !provider.isLibraryPathExcluded(libraryRoot, track.path),
        )
        .toList(growable: false);
  }

  Future<bool> _ensureReadPermission() async {
    if (!Platform.isAndroid) return true;
    final manageStatus = await Permission.manageExternalStorage.request();
    if (manageStatus.isGranted) return true;
    final statuses = await [Permission.audio, Permission.storage].request();
    return statuses.values.any(
      (status) => status.isGranted || status.isLimited,
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    showAppSnackBar(context, message);
  }

  List<LibraryNode> _filterTreeCached(List<LibraryNode> tree, String query) {
    if (identical(tree, _cachedFilterRawTree) && query == _cachedFilterQuery) {
      return _cachedFilteredTree!;
    }
    _cachedFilterRawTree = tree;
    _cachedFilterQuery = query;
    try {
      _cachedFilteredTree = _filterTree(tree, query);
    } catch (_) {
      _cachedFilteredTree = const <LibraryNode>[];
    }
    return _cachedFilteredTree!;
  }

  List<LibraryNode> _filterTree(List<LibraryNode> tree, String query) {
    if (query.isEmpty) return tree;
    final lowerQuery = query.toLowerCase();
    final result = <LibraryNode>[];

    for (final node in tree) {
      if (node is FolderNode) {
        final nameMatch = node.name.toLowerCase().contains(lowerQuery);
        final filteredChildren = _filterTree(node.children, query);

        if (nameMatch || filteredChildren.isNotEmpty) {
          final newNode = FolderNode(node.name, node.path, depth: node.depth);
          if (nameMatch) {
            newNode.children.addAll(node.children);
          } else {
            newNode.children.addAll(filteredChildren);
          }
          result.add(newNode);
        }
      } else if (node is TrackNode) {
        if (_trackMatchesQuery(node.track, lowerQuery)) {
          result.add(node);
        }
      }
    }
    return result;
  }

  bool _trackMatchesQuery(MusicTrack track, String lowerQuery) {
    return track.displayName.toLowerCase().contains(lowerQuery) ||
        path
            .basenameWithoutExtension(track.path)
            .toLowerCase()
            .contains(lowerQuery) ||
        track.groupTitle.toLowerCase().contains(lowerQuery) ||
        track.groupSubtitle.toLowerCase().contains(lowerQuery) ||
        track.path.toLowerCase().contains(lowerQuery);
  }

  int _countTrackNodes(List<LibraryNode> nodes) {
    var count = 0;
    for (final node in nodes) {
      if (node is TrackNode) {
        count++;
      } else if (node is FolderNode) {
        count += _countTrackNodes(node.children);
      }
    }
    return count;
  }
}
