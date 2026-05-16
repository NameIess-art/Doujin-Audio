part of 'library_tab.dart';

extension _LibraryTabFolderImportActions on _LibraryTabState {
  Future<String?> _pickAudioFolderViaNative() async {
    final raw = await _LibraryTabState._fileCacheChannel
        .invokeMapMethod<String, Object?>(FileCacheMethod.pickAudioFolder);
    final pathValue = raw?['path']?.toString().trim();
    if (pathValue == null || pathValue.isEmpty) {
      return null;
    }
    return pathValue;
  }

  Future<List<_PickedAudioFile>?> _pickAudioFilesViaNative() async {
    final raw = await _LibraryTabState._fileCacheChannel
        .invokeMapMethod<String, Object?>(FileCacheMethod.pickAudioFiles);
    final items = raw?['files'];
    if (items is! List) {
      return null;
    }
    final files = <_PickedAudioFile>[];
    for (final item in items) {
      if (item is! Map) continue;
      final map = item.cast<Object?, Object?>();
      final uri = map['uri']?.toString().trim();
      final name = map['name']?.toString().trim();
      final audioTypeHint = name == null || name.isEmpty
          ? (uri ?? '')
          : path.normalize(name);
      if (uri == null || uri.isEmpty || !isSupportedMediaFile(audioTypeHint)) {
        continue;
      }
      files.add(
        _PickedAudioFile(
          uri: uri,
          name: name == null || name.isEmpty ? _displayTrackName(uri) : name,
        ),
      );
    }
    return files;
  }

  List<MusicTrack> _tracksFromPickedAudioFiles(
    List<_PickedAudioFile> files,
    AppLanguageProvider i18n,
  ) {
    return files
        .map(
          (file) => MusicTrack(
            path: file.uri,
            displayName: path.basenameWithoutExtension(file.name),
            groupKey: '__single_files__',
            groupTitle: i18n.tr('imported_files'),
            groupSubtitle: i18n.tr('manually_selected_files'),
            isSingle: true,
            isVideo: isVideoMediaFile(file.name),
            scannedAt: DateTime.now(),
          ),
        )
        .toList(growable: false);
  }

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

  Future<_NativeScanResult> _scanFolderViaNative(String folderPath) async {
    if (!Platform.isAndroid) {
      return const _NativeScanResult.notSupported();
    }
    try {
      final data = await _LibraryTabState._fileCacheChannel
          .invokeMethod<List<dynamic>>('scanFolder', {'folder': folderPath});
      if (data == null) {
        return const _NativeScanResult.failed(
          code: 'scan_empty_response',
          message: 'Native scan returned null data.',
        );
      }

      final scanned = <_ScannedTrack>[];
      for (final item in data) {
        if (item is! Map) continue;
        final map = item.cast<Object?, Object?>();
        final scannedPath = map['path']?.toString().trim();
        if (scannedPath == null ||
            scannedPath.isEmpty ||
            !isSupportedMediaFile(scannedPath)) {
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
            : PathDisplay.folderName(groupKey);
        final groupSubtitle = (nativeGroupSubtitle?.isNotEmpty ?? false)
            ? nativeGroupSubtitle!
            : groupKey;
        final displayName = map['title']?.toString().trim();
        final isVideo =
            map['isVideo'] as bool? ??
            isVideoMediaFile(
              displayName?.isEmpty ?? true ? scannedPath : displayName!,
            );
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
            isVideo: isVideo,
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
      return _NativeScanResult.success(scanned);
    } on PlatformException catch (error) {
      return _NativeScanResult.failed(code: error.code, message: error.message);
    } catch (error) {
      return _NativeScanResult.failed(
        code: 'scan_unknown_error',
        message: error.toString(),
      );
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

  Future<int> _importLibraryWithSingleScan(
    String libraryRoot,
    AudioProvider provider,
    AppLanguageProvider i18n,
  ) async {
    provider.setScanProgress(currentFolder: _displaySourceName(libraryRoot));
    final nativeScan = await _scanFolderViaNative(libraryRoot);
    if (!nativeScan.ok) {
      if (nativeScan.notSupported || !PathMatcher.isContentUri(libraryRoot)) {
        final added = await _importFolderIncrementally(
          libraryRoot,
          provider,
          libraryRoot,
        );
        final existingPaths = provider.library
            .where(
              (track) =>
                  PathMatcher.isWithinOrEqual(track.path, libraryRoot) &&
                  !PathMatcher.isContentUri(track.path) &&
                  File(track.path).existsSync(),
            )
            .map((track) => PathMatcher.normalize(track.path))
            .toSet();
        provider.removeTracksDeletedFromFolder(libraryRoot, existingPaths);
        provider.removeLibraryEntriesDeletedFromFolder(
          libraryRoot,
          libraryRoot,
          existingPaths,
        );
        return added;
      }
      provider.setScanProgress(failureCount: provider.scanFailureCount + 1);
      debugPrint(
        '[library-import] native scan failed for content uri: $libraryRoot '
        'code=${nativeScan.errorCode} message=${nativeScan.errorMessage}',
      );
      return 0;
    }

    final candidates =
        _filterExcludedScannedTracks(provider, libraryRoot, nativeScan.tracks)
            .map((track) {
              if (_trackIsDirectlyInFolder(libraryRoot, track)) {
                return _singleTrackFromScanned(track, i18n);
              }
              return _trackFromScanned(track);
            })
            .toList(growable: false);
    final entryTracks = nativeScan.tracks
        .map((track) {
          if (_trackIsDirectlyInFolder(libraryRoot, track)) {
            return _singleTrackFromScanned(track, i18n);
          }
          return _trackFromScanned(track);
        })
        .toList(growable: false);
    provider.recordLibraryEntriesForTracks(libraryRoot, entryTracks);
    final scannedPaths = nativeScan.tracks
        .map((track) => PathMatcher.normalize(track.path))
        .toSet();
    provider.removeTracksDeletedFromFolder(libraryRoot, scannedPaths);
    provider.removeLibraryEntriesDeletedFromFolder(
      libraryRoot,
      libraryRoot,
      scannedPaths,
    );
    if (candidates.isEmpty) return 0;
    final beforeCount = provider.library.length;
    provider.addOrReplaceTracks(candidates, notify: false);
    final added = provider.library.length - beforeCount;
    provider.setScanProgress(
      foundCount: provider.scanFoundCount + added,
      duplicateCount: provider.scanDuplicateCount + (candidates.length - added),
    );
    return added;
  }

  bool _trackIsDirectlyInFolder(String folderPath, _ScannedTrack track) {
    return PathMatcher.equalsNormalized(track.groupKey, folderPath) ||
        track.groupKey == folderPath;
  }

  Future<int> _importFolderIncrementally(
    String folderPath,
    AudioProvider provider,
    String? libraryRoot,
  ) async {
    if (PathMatcher.isContentUri(folderPath)) {
      provider.setScanProgress(failureCount: provider.scanFailureCount + 1);
      return 0;
    }
    final folder = Directory(folderPath);
    if (!await folder.exists()) return 0;

    final discoveredPaths = <String>{};
    final pendingDirs = Queue<Directory>()..add(folder);
    final batch = <MusicTrack>[];
    final entryBatch = <MusicTrack>[];
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
            final directoryPath = path.normalize(entity.path);
            pendingDirs.add(Directory(directoryPath));
            if (libraryRoot != null) {
              provider.recordLibraryEntriesForTracks(
                libraryRoot,
                const <MusicTrack>[],
                folderPaths: [directoryPath],
              );
            }
            continue;
          }
          if (entity is! File) continue;

          final absolutePath = path.normalize(entity.path);
          if (!isSupportedMediaFile(absolutePath)) continue;
          if (provider.trackByPath(absolutePath) != null ||
              discoveredPaths.contains(absolutePath)) {
            duplicates++;
            continue;
          }
          discoveredPaths.add(absolutePath);

          final parentFolder = path.dirname(absolutePath);
          final folderName = path.basename(parentFolder);
          final fileStat = await entity.stat().catchError(
            (_) => FileStat.statSync(absolutePath),
          );

          final scannedTrack = MusicTrack(
            path: absolutePath,
            displayName: path.basenameWithoutExtension(absolutePath),
            groupKey: parentFolder,
            groupTitle: folderName.isEmpty ? parentFolder : folderName,
            groupSubtitle: parentFolder,
            isSingle: false,
            isVideo: isVideoMediaFile(absolutePath),
            scannedAt: DateTime.now(),
            fileSizeBytes: fileStat.size,
            modifiedAt: fileStat.modified,
          );
          if (libraryRoot != null) {
            entryBatch.add(scannedTrack);
          }
          if (libraryRoot != null &&
              provider.isLibraryPathExcluded(libraryRoot, absolutePath)) {
            if (entryBatch.length >= batchSize) {
              provider.recordLibraryEntriesForTracks(libraryRoot, entryBatch);
              entryBatch.clear();
            }
            continue;
          }

          batch.add(scannedTrack);
          added++;

          if (batch.length >= batchSize) {
            provider.addTracks(batch, notify: false);
            batch.clear();
            if (libraryRoot != null && entryBatch.isNotEmpty) {
              provider.recordLibraryEntriesForTracks(libraryRoot, entryBatch);
              entryBatch.clear();
            }
            await Future<void>.delayed(Duration.zero);
          }
        }
      } catch (_) {
        failures++;
      }
    }
    if (libraryRoot != null && entryBatch.isNotEmpty) {
      provider.recordLibraryEntriesForTracks(libraryRoot, entryBatch);
    }
    provider.addTracks(batch, notify: false);
    provider.setScanProgress(
      foundCount: baseFoundCount + added,
      duplicateCount: baseDuplicateCount + duplicates,
      failureCount: baseFailureCount + failures,
    );
    return added;
  }

  MusicTrack _trackFromScanned(_ScannedTrack track) {
    return MusicTrack(
      path: track.path,
      displayName:
          track.displayName ??
          PathDisplay.fileName(track.path, withoutExtension: true),
      groupKey: track.groupKey,
      groupTitle: track.groupTitle,
      groupSubtitle: track.groupSubtitle,
      isSingle: track.isSingle,
      isVideo: track.isVideo,
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
          track.displayName ??
          PathDisplay.fileName(track.path, withoutExtension: true),
      groupKey: '__single_files__',
      groupTitle: i18n.tr('imported_files'),
      groupSubtitle: i18n.tr('manually_selected_files'),
      isSingle: true,
      isVideo: track.isVideo,
      scannedAt: track.scannedAt ?? DateTime.now(),
      fileSizeBytes: track.fileSizeBytes,
      modifiedAt: track.modifiedAt,
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

  Future<bool> _ensureReadPermissionForSources({
    required Iterable<String> sources,
  }) async {
    if (!Platform.isAndroid) return true;
    final sourceList = sources
        .where((source) => source.trim().isNotEmpty)
        .toList(growable: false);
    if (sourceList.isNotEmpty && sourceList.every(PathMatcher.isContentUri)) {
      return true;
    }
    final manageStatus = await Permission.manageExternalStorage.request();
    if (manageStatus.isGranted) return true;
    final statuses = await [
      Permission.audio,
      Permission.videos,
      Permission.storage,
    ].request();
    return statuses.values.any(
      (status) => status.isGranted || status.isLimited,
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    showAppSnackBar(context, message);
  }
}

class _PickedAudioFile {
  const _PickedAudioFile({required this.uri, required this.name});

  final String uri;
  final String name;
}

class _NativeScanResult {
  const _NativeScanResult._({
    required this.ok,
    this.tracks = const <_ScannedTrack>[],
    this.errorCode,
    this.errorMessage,
    this.notSupported = false,
  });

  const _NativeScanResult.success(List<_ScannedTrack> tracks)
    : this._(ok: true, tracks: tracks);

  const _NativeScanResult.failed({String? code, String? message})
    : this._(ok: false, errorCode: code, errorMessage: message);

  const _NativeScanResult.notSupported()
    : this._(ok: false, notSupported: true);

  final bool ok;
  final List<_ScannedTrack> tracks;
  final String? errorCode;
  final String? errorMessage;
  final bool notSupported;
}
