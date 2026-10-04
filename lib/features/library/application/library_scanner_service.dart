import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as path;

export 'library_scan_data_source.dart' show scanFileSystemFolderPayloadForTest;

import '../../../core/media/music_track.dart';
import '../../../core/logging/app_log_service.dart';
import 'library_catalog.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/media_file_support.dart';
import 'library_scan_data_source.dart';
import 'library_scan_models.dart';
import 'library_scan_rules.dart';
import 'library_refresh_chunk_planner.dart';
import 'library_scan_importer.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';

export 'library_scan_models.dart';
export 'library_refresh_chunk_planner.dart';

class LibraryScannerService {
  LibraryScannerService({
    LibraryScanDataSource? dataSource,
    FileCachePlatformGateway? platformGateway,
  }) : _dataSource =
           dataSource ??
           PlatformLibraryScanDataSource(platformGateway: platformGateway);

  final LibraryScanDataSource _dataSource;
  late final LibraryRefreshChunkPlanner _refreshPlanner =
      LibraryRefreshChunkPlanner(dataSource: _dataSource);
  late final LibraryScanImporter _importer = LibraryScanImporter(
    dataSource: _dataSource,
  );
  final LibraryScanRules _rules = const LibraryScanRules();

  void _rollbackScanAdditions({
    required LibraryCatalog provider,
    required Set<String> existingTrackPaths,
    Map<String, MusicTrack> overwrittenTracks = const <String, MusicTrack>{},
    required Map<String, Set<String>> existingEntryPathsByRoot,
  }) {
    provider.removeTracksByPath(
      provider.library
          .where(
            (track) =>
                !existingTrackPaths.contains(PathMatcher.normalize(track.path)),
          )
          .map((track) => track.path),
    );
    final tracksToRestore = overwrittenTracks.values
        .where((track) => !identical(provider.trackByPath(track.path), track))
        .toList(growable: false);
    if (tracksToRestore.isNotEmpty) {
      provider.addOrReplaceTracks(
        tracksToRestore,
        notify: false,
        mergeExistingState: false,
      );
    }
    for (final entry in existingEntryPathsByRoot.entries) {
      provider.removeLibraryEntriesByPaths(
        entry.key,
        provider
            .libraryEntriesForLibrary(entry.key)
            .where(
              (candidate) =>
                  !entry.value.contains(PathMatcher.normalize(candidate.path)),
            )
            .map((candidate) => candidate.path),
      );
    }
  }

  Future<bool> _flushRefreshBatch(LibraryCatalogReader provider) async {
    await Future<void>.delayed(Duration.zero);
    return provider.isScanning;
  }

  Future<LibraryScanOutcome> refreshWatchedFolders({
    required LibraryCatalog provider,
    required LibraryScanLabels labels,
    void Function(int generation)? onScanStarted,
  }) async {
    final watchedFolders = provider.watchedFolders;
    final watchedLibraries = provider.watchedLibraries;
    if (watchedFolders.isEmpty && watchedLibraries.isEmpty) {
      return LibraryScanOutcome(
        code: LibraryScanOutcomeCode.noSources,
        source: 'refresh',
      );
    }

    final permissionGranted = await _dataSource.ensureReadPermissionForSources([
      ...watchedFolders,
      ...watchedLibraries,
    ]);
    if (!permissionGranted) {
      return LibraryScanOutcome(
        code: LibraryScanOutcomeCode.permissionDenied,
        source: 'refresh',
      );
    }

    final generation = provider.tryBeginScan(
      source: _displaySourceName(
        watchedLibraries.isNotEmpty
            ? watchedLibraries.first
            : watchedFolders.first,
      ),
      background: true,
    );
    if (generation == 0) {
      return LibraryScanOutcome(
        code: LibraryScanOutcomeCode.alreadyRunning,
        source: 'refresh',
      );
    }
    final initialTracksByPath = <String, MusicTrack>{
      for (final track in provider.library)
        PathMatcher.normalize(track.path): track,
    };
    final existingTrackPaths = initialTracksByPath.keys.toSet();
    final overwrittenTracks = <String, MusicTrack>{};
    final rollbackRoots = <String>{...watchedLibraries, ...watchedFolders};
    final existingEntryPathsByRoot = <String, Set<String>>{
      for (final root in rollbackRoots)
        root: provider
            .libraryEntriesForLibrary(root)
            .map((entry) => PathMatcher.normalize(entry.path))
            .toSet(),
    };
    var totalAdded = 0;
    var chunkDuplicateCount = 0;
    var chunkFailureCount = 0;
    var chunkIndex = 0;
    var batchOpen = true;
    var batchStarted = false;
    var wasCancelled = false;
    final deferredCleanupChunks = <LibraryRefreshChunk>[];

    Future<bool> applyRefreshChunk(LibraryRefreshChunk chunk) async {
      if (!provider.isScanGenerationActive(generation) || !batchOpen) {
        return false;
      }
      if (!batchStarted) {
        provider.beginStagedLibraryRefresh();
        batchStarted = true;
      }
      if (chunk.removeWatchedFolders.isNotEmpty ||
          chunk.addWatchedFolders.isNotEmpty ||
          chunk.removeTrackPaths.isNotEmpty ||
          chunk.removeEntryPaths.isNotEmpty) {
        deferredCleanupChunks.add(chunk);
      }
      totalAdded += provider.applyStagedLibraryRefreshChunk(
        sourceFolderPath: chunk.sourceFolderPath,
        libraryRoot: chunk.libraryRoot,
        tracks: chunk.tracks,
        folderPaths: chunk.folderPaths,
      );
      for (final track in chunk.tracks) {
        final key = PathMatcher.normalize(track.path);
        final initial = initialTracksByPath[key];
        if (initial != null &&
            !identical(provider.trackByPath(track.path), initial)) {
          overwrittenTracks.putIfAbsent(key, () => initial);
        }
      }
      chunkDuplicateCount += chunk.duplicateCount;
      chunkFailureCount += chunk.failureCount;
      chunkIndex++;
      provider.setScanProgress(
        currentFolder: chunk.progressLabel,
        foundCount: totalAdded,
        duplicateCount: chunkDuplicateCount,
        failureCount: chunkFailureCount,
        generation: generation,
      );
      if (chunkIndex % 2 == 0) {
        await Future<void>.delayed(Duration.zero);
        batchOpen = provider.isScanGenerationActive(generation);
      }
      return provider.isScanGenerationActive(generation) && batchOpen;
    }

    try {
      onScanStarted?.call(generation);
      if (!provider.isScanGenerationActive(generation)) {
        return LibraryScanOutcome(
          code: LibraryScanOutcomeCode.cancelled,
          source: 'refresh',
        );
      }
      final foldersToRefresh = LinkedHashSet<String>.from(watchedFolders);
      try {
        for (final libraryRoot in watchedLibraries) {
          if (!provider.isScanGenerationActive(generation) || !batchOpen) {
            break;
          }
          foldersToRefresh.removeWhere(
            (folderPath) =>
                PathMatcher.isWithinOrEqual(folderPath, libraryRoot),
          );
          await _refreshPlanner.scanLibraryRoot(
            libraryRoot: libraryRoot,
            provider: provider,
            labels: labels,
            generation: generation,
            onChunk: applyRefreshChunk,
            onProgress: (event) => provider.setScanProgress(
              generation: generation,
              stage: event.stage,
              processed: event.processed,
              total: event.total,
            ),
          );
        }

        final totalFolders = foldersToRefresh.length;
        var processedFolders = 0;
        for (final folderPath in foldersToRefresh) {
          if (!provider.isScanGenerationActive(generation) || !batchOpen) {
            break;
          }
          processedFolders++;
          final libraryRoot = watchedLibraries.firstWhere(
            (root) => PathMatcher.isWithinOrEqual(folderPath, root),
            orElse: () => '',
          );
          await _refreshPlanner.scanWatchedFolder(
            folderPath: folderPath,
            effectiveLibraryRoot: libraryRoot.isEmpty
                ? folderPath
                : libraryRoot,
            provider: provider,
            labels: labels,
            progressPrefix: '[$processedFolders/$totalFolders]',
            generation: generation,
            onChunk: applyRefreshChunk,
            onProgress: (event) => provider.setScanProgress(
              generation: generation,
              stage: event.stage,
              processed: event.processed,
              total: event.total,
            ),
          );
        }
      } finally {
        if (batchStarted) {
          if (provider.isScanGenerationActive(generation)) {
            for (final chunk in deferredCleanupChunks) {
              provider.applyStagedLibraryRefreshChunk(
                sourceFolderPath: chunk.sourceFolderPath,
                libraryRoot: chunk.libraryRoot,
                removeWatchedFolders: chunk.removeWatchedFolders,
                addWatchedFolders: chunk.addWatchedFolders,
                removeTrackPaths: chunk.removeTrackPaths,
                removeEntryPaths: chunk.removeEntryPaths,
              );
              for (final childFolder in chunk.addWatchedFolders) {
                unawaited(_prefillRjDetailForFolder(provider, childFolder));
              }
            }
          } else {
            _rollbackScanAdditions(
              provider: provider,
              existingTrackPaths: existingTrackPaths,
              overwrittenTracks: overwrittenTracks,
              existingEntryPathsByRoot: existingEntryPathsByRoot,
            );
          }
          await provider.finishStagedLibraryRefresh();
        }
      }
    } finally {
      wasCancelled = !provider.isScanGenerationActive(generation);
      provider.finishScan(generation);
    }
    if (wasCancelled) {
      return LibraryScanOutcome(
        code: LibraryScanOutcomeCode.cancelled,
        source: 'refresh',
      );
    }
    return LibraryScanOutcome(
      code: chunkFailureCount > 0
          ? LibraryScanOutcomeCode.failed
          : totalAdded > 0
          ? LibraryScanOutcomeCode.refreshAdded
          : LibraryScanOutcomeCode.refreshNoChanges,
      source: 'refresh',
      details: <String, Object?>{
        'count': totalAdded,
        'failureCount': chunkFailureCount,
      },
    );
  }

  String _displaySourceName(String source) {
    if (PathMatcher.isContentUri(source)) {
      final decoded = Uri.decodeFull(source);
      final lastSegment = decoded.split('/').last;
      return lastSegment.split('%3A').last.split(':').last;
    }
    return PathDisplay.folderName(source);
  }

  Future<void> _prefillRjDetailForFolder(
    LibraryCatalog provider,
    String folderPath,
  ) async {
    try {
      await provider.prefillAudioDetailRjCodeFromText(
        folderPath,
        _displaySourceName(folderPath),
      );
    } catch (_) {
      // Metadata prefill is optional and must not block adding the library.
    }
  }

  Future<void> _prefillRjDetailsForFolders(
    LibraryCatalog provider,
    Iterable<String> folders,
  ) async {
    for (final folder in folders) {
      await _prefillRjDetailForFolder(provider, folder);
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<List<MusicTrack>> _tracksFromPickedAudioFiles(
    List<PickedAudioFile> files,
    LibraryScanLabels labels,
  ) async {
    final tracks = <MusicTrack>[];
    for (final pickedFile in files) {
      if (!isSupportedMediaFile(pickedFile.name) &&
          !isSupportedMediaFile(pickedFile.uri)) {
        continue;
      }

      FileStat? fileStat;
      if (!PathMatcher.isContentUri(pickedFile.uri)) {
        try {
          fileStat = await File(pickedFile.uri).stat();
        } catch (_) {
          // File timestamps are optional scan metadata.
        }
      }
      tracks.add(
        MusicTrack(
          path: pickedFile.uri,
          displayName: path.basenameWithoutExtension(pickedFile.name),
          groupKey: '__single_files__',
          groupTitle: labels.importedFiles,
          groupSubtitle: labels.manuallySelectedFiles,
          isSingle: true,
          isVideo:
              isVideoMediaFile(pickedFile.name) ||
              isVideoMediaFile(pickedFile.uri),
          scannedAt: DateTime.now(),
          fileSizeBytes: fileStat?.size,
          modifiedAt: fileStat?.modified,
        ),
      );
    }
    return tracks;
  }

  List<String> _distinctSourcePaths(Iterable<String> values) {
    final paths = <String>[];
    final seen = <String>{};
    for (final raw in values) {
      final value = raw.trim();
      if (value.isEmpty || !seen.add(PathMatcher.equivalenceKey(value))) {
        continue;
      }
      paths.add(value);
    }
    return List<String>.unmodifiable(paths);
  }

  Future<LibraryScanOutcome?> addFolder({
    required LibraryCatalog provider,
    required LibraryScanLabels labels,
  }) async {
    final selectedPath = await _dataSource.pickAudioFolder(
      dialogTitle: labels.chooseMusicFolder,
    );
    if (selectedPath == null || selectedPath.isEmpty) return null;
    final folderPath = await _resolvePickedFolderSource(selectedPath);
    return _addFolderFromPath(folderPath, provider, labels);
  }

  Future<String> _resolvePickedFolderSource(String source) async {
    final resolved = await _dataSource.resolveRestorablePath(source);
    if (resolved.isEmpty ||
        PathMatcher.equalsNormalized(resolved, source) ||
        PathMatcher.isContentUri(resolved)) {
      return source;
    }
    final permissionGranted = await _dataSource.ensureReadPermissionForSources(
      <String>[resolved],
    );
    if (!permissionGranted || !await _dataSource.sourceExists(resolved)) {
      return source;
    }
    return resolved;
  }

  Future<LibraryScanOutcome> _addFolderFromPath(
    String folderPath,
    LibraryCatalog provider,
    LibraryScanLabels labels,
  ) async {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    if (_rules.isFolderAlreadyInLibrary(
      folderPath: folderPath,
      watchedFolders: provider.watchedFolders,
      watchedLibraries: provider.watchedLibraries,
      tracks: provider.library,
    )) {
      final isExistingStandaloneFolder = provider.watchedFolders.any(
        (value) => PathMatcher.equalsNormalized(value, normalizedFolderPath),
      );
      final isManagedByWatchedLibrary = provider.watchedLibraries.any(
        (value) => PathMatcher.isWithinOrEqual(normalizedFolderPath, value),
      );
      if (isExistingStandaloneFolder &&
          !isManagedByWatchedLibrary &&
          provider.hasLibraryExclusions(normalizedFolderPath)) {
        provider.clearLibraryExclusions(normalizedFolderPath);
      } else {
        return LibraryScanOutcome(
          code: LibraryScanOutcomeCode.folderExists,
          source: 'import_folder',
        );
      }
    }

    final generation = provider.tryBeginScan(
      source: _displaySourceName(folderPath),
    );
    if (generation == 0) {
      return LibraryScanOutcome(
        code: LibraryScanOutcomeCode.alreadyRunning,
        source: 'import_folder',
      );
    }
    final initialTracksByPath = <String, MusicTrack>{
      for (final track in provider.library)
        PathMatcher.normalize(track.path): track,
    };
    final existingTrackPaths = initialTracksByPath.keys.toSet();
    final existingEntryPaths = provider
        .libraryEntriesForLibrary(normalizedFolderPath)
        .map((entry) => PathMatcher.normalize(entry.path))
        .toSet();
    provider.beginLibraryBatch();

    var added = 0;
    var completed = false;
    var wasCancelled = false;

    try {
      provider.setScanProgress(
        currentFolder: _displaySourceName(folderPath),
        generation: generation,
      );
      final chunkedImport = await _importer.importNativeFolder(
        sourceFolderPath: folderPath,
        provider: provider,
        libraryRoot: normalizedFolderPath,
        labels: labels,
        onChunkCommitted: () async {
          if (!provider.isScanGenerationActive(generation)) return false;
          return _flushRefreshBatch(provider);
        },
        generation: generation,
      );
      if (chunkedImport != null) {
        added = chunkedImport.added;
        completed =
            provider.isScanGenerationActive(generation) &&
            chunkedImport.result.isComplete;
      } else {
        final nativeScan = await _dataSource.scanFolder(folderPath);
        if (nativeScan.ok) {
          added = await _importer.mergeScannedTracks(
            sourceFolderPath: folderPath,
            provider: provider,
            scannedTracks: nativeScan.tracks,
            libraryRoot: normalizedFolderPath,
            labels: labels,
            onChunkCommitted: () async {
              if (!provider.isScanGenerationActive(generation)) return false;
              return _flushRefreshBatch(provider);
            },
            generation: generation,
          );
          completed =
              provider.isScanGenerationActive(generation) &&
              nativeScan.isComplete;
        } else if (nativeScan.notSupported ||
            !PathMatcher.isContentUri(folderPath)) {
          final failuresBefore = provider.scanFailureCount;
          added = await _importer.importFolder(
            folderPath,
            provider,
            normalizedFolderPath,
            labels: labels,
            onChunkCommitted: () async {
              if (!provider.isScanGenerationActive(generation)) return false;
              return _flushRefreshBatch(provider);
            },
            generation: generation,
          );
          completed =
              provider.isScanGenerationActive(generation) &&
              provider.scanFailureCount == failuresBefore;
        } else {
          provider.setScanProgress(
            failureCount: provider.scanFailureCount + 1,
            generation: generation,
          );
          AppLogService.warning(
            'library_native_scan_failed source=$folderPath '
            'code=${nativeScan.errorCode}',
            error: nativeScan.errorMessage,
          );
        }
      }
    } finally {
      wasCancelled = !provider.isScanGenerationActive(generation);
      completed = completed && provider.isScanGenerationActive(generation);
      try {
        if (!completed) {
          _rollbackScanAdditions(
            provider: provider,
            existingTrackPaths: existingTrackPaths,
            overwrittenTracks: initialTracksByPath,
            existingEntryPathsByRoot: <String, Set<String>>{
              normalizedFolderPath: existingEntryPaths,
            },
          );
        } else {
          provider.setScanProgress(
            generation: generation,
            stage: FolderScanStage.saving,
          );
          provider.addWatchedFolder(normalizedFolderPath, notify: false);
          provider.recordLibraryEntriesForTracks(
            normalizedFolderPath,
            const <MusicTrack>[],
          );
        }
      } finally {
        try {
          await provider.endLibraryBatch();
        } finally {
          provider.finishScan(generation);
        }
      }
      if (completed) {
        unawaited(_prefillRjDetailForFolder(provider, normalizedFolderPath));
      }
    }
    if (wasCancelled) {
      return LibraryScanOutcome(
        code: LibraryScanOutcomeCode.cancelled,
        source: 'import_folder',
      );
    }
    if (!completed) {
      return LibraryScanOutcome(
        code: LibraryScanOutcomeCode.failed,
        source: 'import_folder',
      );
    }
    if (added == 0) {
      return LibraryScanOutcome(
        code: LibraryScanOutcomeCode.noAudio,
        source: 'import_folder',
      );
    }
    return LibraryScanOutcome(
      code: LibraryScanOutcomeCode.importAdded,
      source: 'import_folder',
      details: <String, Object?>{'count': added},
    );
  }

  Future<LibraryScanOutcome?> addLibrary({
    required LibraryCatalog provider,
    required LibraryScanLabels labels,
  }) async {
    final selectedPath = await _dataSource.pickAudioFolder(
      dialogTitle: labels.chooseLibraryFolder,
    );
    if (selectedPath == null || selectedPath.isEmpty) return null;
    final folderPath = await _resolvePickedFolderSource(selectedPath);
    return _addLibraryFromPath(folderPath, provider, labels);
  }

  Future<LibraryScanOutcome> _addLibraryFromPath(
    String folderPath,
    LibraryCatalog provider,
    LibraryScanLabels labels,
  ) async {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    final promotedFolders = _rules.watchedFoldersToPromote(
      folderPath: normalizedFolderPath,
      watchedFolders: provider.watchedFolders,
    );
    if (_rules.hasWatchedLibraryOverlap(
          folderPath: normalizedFolderPath,
          watchedLibraries: provider.watchedLibraries,
        ) ||
        _rules.isNestedInsideStandaloneFolder(
          folderPath: normalizedFolderPath,
          watchedFolders: provider.watchedFolders,
        ) ||
        _rules.hasUnmanagedLibraryContentOverlap(
          folderPath: normalizedFolderPath,
          promotedFolders: promotedFolders,
          tracks: provider.library,
        )) {
      return LibraryScanOutcome(
        code: LibraryScanOutcomeCode.libraryExists,
        source: 'import_library',
      );
    }
    final generation = provider.tryBeginScan(
      source: _displaySourceName(normalizedFolderPath),
    );
    if (generation == 0) {
      return LibraryScanOutcome(
        code: LibraryScanOutcomeCode.alreadyRunning,
        source: 'import_library',
      );
    }
    var childFolders = const <String>[];
    final initialTracksByPath = <String, MusicTrack>{
      for (final track in provider.library)
        PathMatcher.normalize(track.path): track,
    };
    final existingTrackPaths = initialTracksByPath.keys.toSet();
    final existingEntryPaths = provider
        .libraryEntriesForLibrary(normalizedFolderPath)
        .map((entry) => PathMatcher.normalize(entry.path))
        .toSet();
    provider.beginLibraryBatch();
    var added = 0;
    var completed = false;
    var wasCancelled = false;
    try {
      final listing = await _dataSource.listImmediateChildFolders(
        normalizedFolderPath,
      );
      if (!listing.complete || !provider.isScanGenerationActive(generation)) {
        return LibraryScanOutcome(
          code: provider.isScanGenerationActive(generation)
              ? LibraryScanOutcomeCode.failed
              : LibraryScanOutcomeCode.cancelled,
          source: 'import_library',
        );
      }
      childFolders = listing.folders;
      final outcome = await _importer.importLibrary(
        normalizedFolderPath,
        provider,
        labels,
        onChunkCommitted: () async {
          if (!provider.isScanGenerationActive(generation)) return false;
          return _flushRefreshBatch(provider);
        },
        generation: generation,
      );
      added = outcome.added;
      completed =
          outcome.complete && provider.isScanGenerationActive(generation);
      if (completed) {
        provider.setScanProgress(
          generation: generation,
          stage: FolderScanStage.saving,
        );
        for (final folderPath in promotedFolders) {
          provider.removeWatchedFolder(folderPath, notify: false);
        }
        provider.addWatchedLibrary(normalizedFolderPath, notify: false);
        provider.recordLibraryEntriesForTracks(
          normalizedFolderPath,
          const <MusicTrack>[],
          folderPaths: childFolders,
        );
        for (final childFolder in childFolders) {
          if (provider.isLibraryPathExcluded(
            normalizedFolderPath,
            childFolder,
          )) {
            continue;
          }
          provider.addWatchedFolder(childFolder, notify: false);
        }
      }
    } finally {
      wasCancelled = !provider.isScanGenerationActive(generation);
      completed = completed && provider.isScanGenerationActive(generation);
      try {
        if (!completed) {
          _rollbackScanAdditions(
            provider: provider,
            existingTrackPaths: existingTrackPaths,
            overwrittenTracks: initialTracksByPath,
            existingEntryPathsByRoot: <String, Set<String>>{
              normalizedFolderPath: existingEntryPaths,
            },
          );
        }
      } finally {
        try {
          await provider.endLibraryBatch();
        } finally {
          provider.finishScan(generation);
        }
      }
      if (completed) {
        unawaited(
          _prefillRjDetailsForFolders(
            provider,
            childFolders.where(
              (folder) =>
                  !provider.isLibraryPathExcluded(normalizedFolderPath, folder),
            ),
          ),
        );
      }
    }
    if (!completed) {
      return LibraryScanOutcome(
        code: wasCancelled
            ? LibraryScanOutcomeCode.cancelled
            : LibraryScanOutcomeCode.failed,
        source: 'import_library',
      );
    }
    return LibraryScanOutcome(
      code: LibraryScanOutcomeCode.libraryImported,
      source: 'import_library',
      details: <String, Object?>{
        'count': added,
        'folderCount': childFolders.length,
      },
    );
  }

  Future<LibraryScanOutcome?> addFiles({
    required LibraryCatalog provider,
    required LibraryScanLabels labels,
  }) async {
    final pickedFiles = await _dataSource.pickAudioFiles(
      dialogTitle: labels.chooseAudioFiles,
    );
    if (pickedFiles == null || pickedFiles.isEmpty) return null;
    return _addPickedFiles(pickedFiles, provider, labels);
  }

  Future<LibraryScanOutcome> addFilePaths(
    Iterable<String> paths, {
    required LibraryCatalog provider,
    required LibraryScanLabels labels,
  }) {
    final pickedFiles = _distinctSourcePaths(paths)
        .map(
          (filePath) => PickedAudioFile(
            uri: filePath,
            name: PathDisplay.fileName(filePath),
          ),
        )
        .toList(growable: false);
    return _addPickedFiles(pickedFiles, provider, labels);
  }

  Future<LibraryScanOutcome> _addPickedFiles(
    List<PickedAudioFile> pickedFiles,
    LibraryCatalog provider,
    LibraryScanLabels labels,
  ) async {
    final generation = provider.tryBeginScan(source: labels.importedFiles);
    if (generation == 0) {
      return LibraryScanOutcome(
        code: LibraryScanOutcomeCode.alreadyRunning,
        source: 'import_files',
      );
    }
    provider.beginLibraryBatch();

    var added = 0;
    var fileExists = false;
    try {
      final candidates = await _tracksFromPickedAudioFiles(pickedFiles, labels);
      if (_rules.areAnyTracksAlreadyInLibrary(
        trackPaths: candidates.map((track) => track.path),
        watchedFolders: provider.watchedFolders,
        watchedLibraries: provider.watchedLibraries,
        tracks: provider.library,
      )) {
        fileExists = true;
      } else {
        final beforeCount = provider.library.length;
        provider.addTracks(candidates, notify: false);
        added = provider.library.length - beforeCount;
      }
    } finally {
      try {
        await provider.endLibraryBatch();
      } finally {
        provider.finishScan(generation);
      }
    }
    if (fileExists) {
      return LibraryScanOutcome(
        code: LibraryScanOutcomeCode.fileExists,
        source: 'import_files',
      );
    }
    return LibraryScanOutcome(
      code: LibraryScanOutcomeCode.importAdded,
      source: 'import_files',
      details: <String, Object?>{'count': added},
    );
  }
}
