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

      final payload = await Isolate.run(() => _parseNativeScanPayload(data));
      return _NativeScanResult.success(payload.tracks, payload.paths);
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
    AppLanguageProvider i18n, {
    Future<bool> Function()? onChunkCommitted,
  }) async {
    provider.setScanProgress(currentFolder: _displaySourceName(libraryRoot));
    final nativeScan = await _scanFolderViaNative(libraryRoot);
    if (!nativeScan.ok) {
      if (nativeScan.notSupported || !PathMatcher.isContentUri(libraryRoot)) {
        final added = await _importFolderIncrementally(
          libraryRoot,
          provider,
          libraryRoot,
          promoteRootTracksToSingles: true,
          i18n: i18n,
          onChunkCommitted: onChunkCommitted,
        );
        final candidatePaths = provider.library
            .where(
              (track) =>
                  PathMatcher.isWithinOrEqual(track.path, libraryRoot) &&
                  !PathMatcher.isContentUri(track.path),
            )
            .map((track) => PathMatcher.normalize(track.path))
            .toList(growable: false);
        final existingPaths = candidatePaths.isEmpty
            ? const <String>{}
            : await Isolate.run(() => _checkExistingPaths(candidatePaths));
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

    final added = await _mergeScannedTracksIncrementally(
      sourceFolderPath: libraryRoot,
      provider: provider,
      scannedTracks: nativeScan.tracks,
      libraryRoot: libraryRoot,
      promoteRootTracksToSingles: true,
      i18n: i18n,
      onChunkCommitted: onChunkCommitted,
    );
    final scannedPaths = nativeScan.paths;
    provider.removeTracksDeletedFromFolder(libraryRoot, scannedPaths);
    provider.removeLibraryEntriesDeletedFromFolder(
      libraryRoot,
      libraryRoot,
      scannedPaths,
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
    String? libraryRoot, {
    bool promoteRootTracksToSingles = false,
    AppLanguageProvider? i18n,
    Future<bool> Function()? onChunkCommitted,
  }) async {
    if (PathMatcher.isContentUri(folderPath)) {
      provider.setScanProgress(failureCount: provider.scanFailureCount + 1);
      return 0;
    }
    final folder = Directory(folderPath);
    if (!await folder.exists()) return 0;

    final payload = await Isolate.run(
      () => _scanFileSystemFolderPayload(folderPath),
    );
    if (!mounted || !provider.isScanning) return 0;

    final scannedTracks =
        ((payload['tracks'] as List<Object?>?) ?? const <Object?>[])
            .whereType<Map<Object?, Object?>>()
            .map(_ScannedTrack.fromPayload)
            .toList(growable: false);
    final discoveredPaths = _stringSetFromPayload(payload['discoveredPaths']);
    final discoveredFolders =
        ((payload['folderPaths'] as List<Object?>?) ?? const <Object?>[])
            .whereType<String>()
            .toList(growable: false);
    const batchSize = 220;
    final baseFoundCount = provider.scanFoundCount;
    final baseDuplicateCount = provider.scanDuplicateCount;
    final baseFailureCount = provider.scanFailureCount;
    var added = 0;
    var duplicates = 0;
    final failures = (payload['failureCount'] as int?) ?? 0;
    final mergeContext = libraryRoot == null
        ? null
        : _LibraryScanMergeContext(
            provider: provider,
            libraryRoot: libraryRoot,
          );

    if (libraryRoot != null && discoveredFolders.isNotEmpty) {
      provider.recordLibraryEntriesForTracks(
        libraryRoot,
        const <MusicTrack>[],
        folderPaths: discoveredFolders,
        exclusionMatcher: mergeContext?.exclusionMatcher,
        entrySnapshot: mergeContext?.entrySnapshot,
      );
    }

    for (var index = 0; index < scannedTracks.length; index += batchSize) {
      if (!mounted || !provider.isScanning) break;
      final endIndex = index + batchSize < scannedTracks.length
          ? index + batchSize
          : scannedTracks.length;
      final entryBatch = <MusicTrack>[];
      final trackBatch = <MusicTrack>[];

      for (var scanIndex = index; scanIndex < endIndex; scanIndex++) {
        final scanned = scannedTracks[scanIndex];
        final converted = _convertScannedTrack(
          scanned,
          libraryRoot: libraryRoot,
          promoteRootTracksToSingles: promoteRootTracksToSingles,
          i18n: i18n,
        );
        if (libraryRoot != null) {
          entryBatch.add(converted);
          if (mergeContext!.isExcluded(scanned.path)) {
            continue;
          }
        }
        if (provider.trackByPath(scanned.path) != null) {
          duplicates++;
          continue;
        }
        trackBatch.add(converted);
      }

      if (libraryRoot != null && entryBatch.isNotEmpty) {
        provider.recordLibraryEntriesForTracks(
          libraryRoot,
          entryBatch,
          exclusionMatcher: mergeContext?.exclusionMatcher,
          entrySnapshot: mergeContext?.entrySnapshot,
        );
      }
      if (trackBatch.isNotEmpty) {
        final before = provider.library.length;
        provider.addTracks(trackBatch, notify: false);
        final batchAdded = provider.library.length - before;
        added += batchAdded;
        duplicates += trackBatch.length - batchAdded;
      }

      provider.setScanProgress(
        currentFolder:
            '[$endIndex/${scannedTracks.length}] '
            '${_displaySourceName(folderPath)}',
        foundCount: baseFoundCount + added,
        duplicateCount: baseDuplicateCount + duplicates,
        failureCount: baseFailureCount + failures,
      );
      if (onChunkCommitted != null) {
        final keepGoing = await onChunkCommitted();
        if (!keepGoing) {
          break;
        }
      } else {
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (mounted && provider.isScanning) {
      provider.removeTracksDeletedFromFolder(folderPath, discoveredPaths);
      if (libraryRoot != null) {
        provider.removeLibraryEntriesDeletedFromFolder(
          libraryRoot,
          folderPath,
          <String>{...discoveredPaths, ...discoveredFolders},
        );
      }
      provider.setScanProgress(
        foundCount: baseFoundCount + added,
        duplicateCount: baseDuplicateCount + duplicates,
        failureCount: baseFailureCount + failures,
      );
    }
    return added;
  }

  Future<int> _mergeScannedTracksIncrementally({
    required String sourceFolderPath,
    required AudioProvider provider,
    required List<_ScannedTrack> scannedTracks,
    required String? libraryRoot,
    bool promoteRootTracksToSingles = false,
    AppLanguageProvider? i18n,
    Future<bool> Function()? onChunkCommitted,
  }) async {
    if (scannedTracks.isEmpty) {
      return 0;
    }

    const chunkSize = 180;
    final baseFoundCount = provider.scanFoundCount;
    final baseDuplicateCount = provider.scanDuplicateCount;
    final baseFailureCount = provider.scanFailureCount;
    var added = 0;
    var duplicates = 0;
    final mergeContext = libraryRoot == null
        ? null
        : _LibraryScanMergeContext(
            provider: provider,
            libraryRoot: libraryRoot,
          );

    for (var index = 0; index < scannedTracks.length; index += chunkSize) {
      if (!mounted || !provider.isScanning) break;
      final endIndex = index + chunkSize < scannedTracks.length
          ? index + chunkSize
          : scannedTracks.length;
      final entryBatch = <MusicTrack>[];
      final trackBatch = <MusicTrack>[];

      for (var scanIndex = index; scanIndex < endIndex; scanIndex++) {
        final scanned = scannedTracks[scanIndex];
        final converted = _convertScannedTrack(
          scanned,
          libraryRoot: libraryRoot,
          promoteRootTracksToSingles: promoteRootTracksToSingles,
          i18n: i18n,
        );
        final needsRefresh = provider.libraryTrackNeedsRefresh(converted);
        if (libraryRoot != null) {
          entryBatch.add(converted);
          if (mergeContext!.isExcluded(scanned.path)) {
            continue;
          }
        }
        if (needsRefresh) {
          trackBatch.add(converted);
        } else {
          duplicates++;
        }
      }

      if (libraryRoot != null && entryBatch.isNotEmpty) {
        provider.recordLibraryEntriesForTracks(
          libraryRoot,
          entryBatch,
          exclusionMatcher: mergeContext?.exclusionMatcher,
          entrySnapshot: mergeContext?.entrySnapshot,
        );
      }
      if (trackBatch.isNotEmpty) {
        final beforeCount = provider.library.length;
        provider.addOrReplaceTracks(trackBatch, notify: false);
        final batchAdded = provider.library.length - beforeCount;
        added += batchAdded;
        duplicates += trackBatch.length - batchAdded;
      }

      provider.setScanProgress(
        currentFolder:
            '[$endIndex/${scannedTracks.length}] '
            '${_displaySourceName(sourceFolderPath)}',
        foundCount: baseFoundCount + added,
        duplicateCount: baseDuplicateCount + duplicates,
        failureCount: baseFailureCount,
      );

      if (onChunkCommitted != null) {
        final keepGoing = await onChunkCommitted();
        if (!keepGoing) {
          break;
        }
      } else {
        await Future<void>.delayed(Duration.zero);
      }
    }

    return added;
  }

  MusicTrack _convertScannedTrack(
    _ScannedTrack track, {
    required String? libraryRoot,
    required bool promoteRootTracksToSingles,
    AppLanguageProvider? i18n,
  }) {
    if (promoteRootTracksToSingles &&
        libraryRoot != null &&
        _trackIsDirectlyInFolder(libraryRoot, track)) {
      return _singleTrackFromScanned(track, i18n!);
    }
    return _trackFromScanned(track);
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
    this.paths = const <String>{},
    this.errorCode,
    this.errorMessage,
    this.notSupported = false,
  });

  const _NativeScanResult.success(List<_ScannedTrack> tracks, Set<String> paths)
    : this._(ok: true, tracks: tracks, paths: paths);

  const _NativeScanResult.failed({String? code, String? message})
    : this._(ok: false, errorCode: code, errorMessage: message);

  const _NativeScanResult.notSupported()
    : this._(ok: false, notSupported: true);

  final bool ok;
  final List<_ScannedTrack> tracks;
  final Set<String> paths;
  final String? errorCode;
  final String? errorMessage;
  final bool notSupported;
}

class _NativeScanPayload {
  const _NativeScanPayload({required this.tracks, required this.paths});

  final List<_ScannedTrack> tracks;
  final Set<String> paths;
}

class _LibraryScanMergeContext {
  _LibraryScanMergeContext({
    required AudioProvider provider,
    required String libraryRoot,
  }) : exclusionMatcher = provider.libraryExclusionMatcherForLibrary(
         libraryRoot,
       ),
       entrySnapshot = provider.libraryEntrySnapshotForLibrary(libraryRoot);

  final LibraryExclusionMatcher exclusionMatcher;
  final LibraryEntrySnapshot entrySnapshot;

  bool isExcluded(String entityPath) => exclusionMatcher.isExcluded(entityPath);
}

Map<String, Object?> _scanFileSystemFolderPayload(String folderPath) {
  final folder = Directory(folderPath);
  if (!folder.existsSync()) {
    return const <String, Object?>{
      'tracks': <Object?>[],
      'folderPaths': <Object?>[],
      'failureCount': 0,
    };
  }

  final pendingDirs = Queue<Directory>()..add(folder);
  final folderPaths = <String>[];
  final tracks = <Map<String, Object?>>[];
  final seenPaths = <String>{};
  var failures = 0;

  while (pendingDirs.isNotEmpty) {
    final currentDir = pendingDirs.removeFirst();
    List<FileSystemEntity> children;
    try {
      children = currentDir.listSync(followLinks: false);
    } catch (_) {
      failures++;
      continue;
    }

    for (final entity in children) {
      if (entity is Directory) {
        final directoryPath = path.normalize(entity.path);
        pendingDirs.add(Directory(directoryPath));
        folderPaths.add(directoryPath);
        continue;
      }
      if (entity is! File) continue;

      final absolutePath = path.normalize(entity.path);
      if (!isSupportedMediaFile(absolutePath) || !seenPaths.add(absolutePath)) {
        continue;
      }

      FileStat? fileStat;
      try {
        fileStat = entity.statSync();
      } catch (_) {}

      final parentFolder = path.dirname(absolutePath);
      final folderName = path.basename(parentFolder);
      tracks.add(<String, Object?>{
        'path': absolutePath,
        'displayName': path.basenameWithoutExtension(absolutePath),
        'groupKey': parentFolder,
        'groupTitle': folderName.isEmpty ? parentFolder : folderName,
        'groupSubtitle': parentFolder,
        'isSingle': false,
        'isVideo': isVideoMediaFile(absolutePath),
        'scannedAtMs': DateTime.now().millisecondsSinceEpoch,
        'fileSizeBytes': fileStat?.size,
        'modifiedAtMs': fileStat?.modified.millisecondsSinceEpoch,
      });
    }
  }

  return <String, Object?>{
    'tracks': tracks,
    'folderPaths': folderPaths,
    'discoveredPaths': Set<String>.unmodifiable(seenPaths),
    'failureCount': failures,
  };
}

Set<String> _stringSetFromPayload(Object? value) {
  if (value is Set<String>) {
    return value;
  }
  if (value is Iterable) {
    final result = <String>{};
    for (final item in value) {
      if (item is String) result.add(item);
    }
    return result;
  }
  return const <String>{};
}

_NativeScanPayload _parseNativeScanPayload(List<dynamic> data) {
  final scanned = <_ScannedTrack>[];
  final paths = <String>{};
  for (final item in data) {
    if (item is! Map) continue;
    final scannedPath = item['path']?.toString().trim();
    if (scannedPath == null ||
        scannedPath.isEmpty ||
        !isSupportedMediaFile(scannedPath)) {
      continue;
    }
    final resolvedPath = PathMatcher.isContentUri(scannedPath)
        ? scannedPath
        : path.normalize(scannedPath);
    final normalizedPath = PathMatcher.normalize(resolvedPath);

    final nativeGroupKey = item['groupKey']?.toString().trim();
    final nativeGroupTitle = item['groupTitle']?.toString().trim();
    final nativeGroupSubtitle = item['groupSubtitle']?.toString().trim();

    final groupKey = (nativeGroupKey?.isNotEmpty ?? false)
        ? nativeGroupKey!
        : path.dirname(resolvedPath);
    final groupTitle = (nativeGroupTitle?.isNotEmpty ?? false)
        ? nativeGroupTitle!
        : PathDisplay.folderName(groupKey);
    final groupSubtitle = (nativeGroupSubtitle?.isNotEmpty ?? false)
        ? nativeGroupSubtitle!
        : groupKey;
    final displayName = item['title']?.toString().trim();
    final isVideo =
        item['isVideo'] as bool? ??
        isVideoMediaFile(
          displayName?.isEmpty ?? true ? resolvedPath : displayName!,
        );
    final scannedAtMs = item['scannedAtMs'] as num?;
    final modifiedAtMs = item['modifiedAtMs'] as num?;

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
        fileSizeBytes: (item['fileSizeBytes'] as num?)?.toInt(),
        modifiedAt: modifiedAtMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(modifiedAtMs.toInt()),
      ),
    );
    paths.add(normalizedPath);
  }
  return _NativeScanPayload(
    tracks: List<_ScannedTrack>.unmodifiable(scanned),
    paths: Set<String>.unmodifiable(paths),
  );
}
