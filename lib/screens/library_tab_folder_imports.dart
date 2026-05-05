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
    return Directory(path.join(supportDir.path, 'music_player_imports'));
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

        scanned.add(
          _ScannedTrack(
            path: resolvedPath,
            groupKey: groupKey,
            groupTitle: groupTitle,
            groupSubtitle: groupSubtitle,
            isSingle: false,
            displayName: displayName?.isEmpty ?? true ? null : displayName,
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

  Future<int> _importFolderIncrementally(
    String folderPath,
    AudioProvider provider,
  ) async {
    final folder = Directory(folderPath);
    if (!await folder.exists()) return 0;

    final existingPaths = provider.library.map((t) => t.path).toSet();
    final pendingDirs = Queue<Directory>()..add(folder);
    final batch = <MusicTrack>[];
    const batchSize = 350;
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
          foundCount: provider.scanFoundCount + added,
          duplicateCount: provider.scanDuplicateCount + duplicates,
          failureCount: provider.scanFailureCount + failures,
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
          if (existingPaths.contains(absolutePath)) {
            duplicates++;
            continue;
          }
          existingPaths.add(absolutePath);

          final parentFolder = path.dirname(absolutePath);
          final folderName = path.basename(parentFolder);

          batch.add(
            MusicTrack(
              path: absolutePath,
              displayName: path.basenameWithoutExtension(absolutePath),
              groupKey: parentFolder,
              groupTitle: folderName.isEmpty ? parentFolder : folderName,
              groupSubtitle: parentFolder,
              isSingle: false,
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
      foundCount: provider.scanFoundCount + added,
      duplicateCount: provider.scanDuplicateCount + duplicates,
      failureCount: provider.scanFailureCount + failures,
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
    _cachedFilteredTree = _filterTree(tree, query);
    return _cachedFilteredTree!;
  }

  List<LibraryNode> _filterTree(List<LibraryNode> tree, String query) {
    if (query.isEmpty) return tree;
    final lowerQuery = query.toLowerCase();
    final result = <LibraryNode>[];

    for (final node in tree) {
      final nameMatch = node.name.toLowerCase().contains(lowerQuery);
      if (node is FolderNode) {
        if (nameMatch) {
          result.add(node);
        } else {
          final filtered = _filterTree(node.children, query);
          if (filtered.isNotEmpty) {
            final copy = FolderNode(node.name, node.path, depth: node.depth);
            copy.children.addAll(filtered);
            result.add(copy);
          }
        }
      } else if (node is TrackNode) {
        if (nameMatch) result.add(node);
      }
    }
    return result;
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
