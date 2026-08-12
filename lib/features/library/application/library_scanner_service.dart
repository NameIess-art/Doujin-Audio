import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

export 'library_scan_data_source.dart' show scanFileSystemFolderPayloadForTest;

import '../../../core/media/music_track.dart';
import '../../../core/logging/app_log_service.dart';
import 'library_catalog.dart';
import 'library_state_models.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/media_file_support.dart';
import 'library_scan_data_source.dart';
import 'library_scan_models.dart';
import 'library_scan_rules.dart';
import 'library_refresh_chunk_planner.dart';
import 'library_scanner_isolate.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';

export 'library_scan_models.dart';
export 'library_refresh_chunk_planner.dart';

class LibraryScanMergeContext {
  LibraryScanMergeContext({
    required LibraryCatalogReader provider,
    required String libraryRoot,
  }) : exclusionMatcher = provider.libraryExclusionMatcherForLibrary(
         libraryRoot,
       ),
       entrySnapshot = provider.libraryEntrySnapshotForLibrary(libraryRoot);

  final LibraryExclusionMatcher exclusionMatcher;
  final LibraryEntrySnapshot entrySnapshot;

  bool isExcluded(String entityPath) => exclusionMatcher.isExcluded(entityPath);
}

class _IncrementalNativeImport {
  const _IncrementalNativeImport({required this.added, required this.result});

  final int added;
  final NativeScanResult result;
}

class _FolderImportOutcome {
  const _FolderImportOutcome({required this.added, required this.complete});

  final int added;
  final bool complete;
}

class LibraryScannerService {
  LibraryScannerService({
    LibraryScanDataSource? dataSource,
    FileCachePlatformGateway? platformGateway,
  }) : _dataSource =
           dataSource ??
           PlatformLibraryScanDataSource(platformGateway: platformGateway);

  final LibraryScanDataSource _dataSource;
  final LibraryScanRules _rules = const LibraryScanRules();

  void _rollbackScanAdditions({
    required LibraryCatalog provider,
    required Set<String> existingTrackPaths,
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
    final existingTrackPaths = provider.library
        .map((track) => PathMatcher.normalize(track.path))
        .toSet();
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
          await _scanLibraryRootForRefresh(
            libraryRoot: libraryRoot,
            provider: provider,
            labels: labels,
            generation: generation,
            onChunk: applyRefreshChunk,
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
          await _scanWatchedFolderForRefresh(
            folderPath: folderPath,
            effectiveLibraryRoot: libraryRoot.isEmpty
                ? folderPath
                : libraryRoot,
            provider: provider,
            labels: labels,
            progressPrefix: '[$processedFolders/$totalFolders]',
            generation: generation,
            onChunk: applyRefreshChunk,
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
          }
          await provider.finishStagedLibraryRefresh();
        }
      }
    } finally {
      wasCancelled = !provider.isScanGenerationActive(generation);
      if (wasCancelled) {
        provider.beginLibraryBatch();
        _rollbackScanAdditions(
          provider: provider,
          existingTrackPaths: existingTrackPaths,
          existingEntryPathsByRoot: existingEntryPathsByRoot,
        );
        await provider.endLibraryBatch();
      }
      provider.finishScan(generation);
    }
    if (wasCancelled) {
      return LibraryScanOutcome(
        code: LibraryScanOutcomeCode.cancelled,
        source: 'refresh',
      );
    }
    return LibraryScanOutcome(
      code: totalAdded > 0
          ? LibraryScanOutcomeCode.refreshAdded
          : LibraryScanOutcomeCode.refreshNoChanges,
      source: 'refresh',
      details: <String, Object?>{'count': totalAdded},
    );
  }

  Future<void> _scanLibraryRootForRefresh({
    required String libraryRoot,
    required LibraryCatalog provider,
    required LibraryScanLabels labels,
    required int generation,
    required Future<bool> Function(LibraryRefreshChunk chunk) onChunk,
  }) async {
    final childFolderResult = await _listImmediateChildFoldersResult(
      libraryRoot,
    );
    final childFolders = childFolderResult.folders;
    final visibleChildFolders = childFolders
        .where(
          (folderPath) =>
              !provider.isLibraryPathExcluded(libraryRoot, folderPath),
        )
        .toList(growable: false);
    await _scanFolderForRefresh(
      sourceFolderPath: libraryRoot,
      libraryRoot: libraryRoot,
      provider: provider,
      labels: labels,
      promoteRootTracksToSingles: true,
      folderPaths: childFolders,
      removeWatchedFolders: [libraryRoot],
      addWatchedFolders: visibleChildFolders,
      additionalFailureCount: childFolderResult.complete ? 0 : 1,
      progressPrefix: '',
      generation: generation,
      onChunk: onChunk,
    );
  }

  Future<void> _scanWatchedFolderForRefresh({
    required String folderPath,
    required String effectiveLibraryRoot,
    required LibraryCatalog provider,
    required LibraryScanLabels labels,
    required String progressPrefix,
    required int generation,
    required Future<bool> Function(LibraryRefreshChunk chunk) onChunk,
  }) async {
    await _scanFolderForRefresh(
      sourceFolderPath: folderPath,
      libraryRoot: effectiveLibraryRoot,
      provider: provider,
      labels: labels,
      progressPrefix: progressPrefix,
      generation: generation,
      onChunk: onChunk,
    );
  }

  Future<void> _scanFolderForRefresh({
    required String sourceFolderPath,
    required String libraryRoot,
    required LibraryCatalog provider,
    required LibraryScanLabels labels,
    bool promoteRootTracksToSingles = false,
    List<String> folderPaths = const <String>[],
    List<String> removeWatchedFolders = const <String>[],
    List<String> addWatchedFolders = const <String>[],
    int additionalFailureCount = 0,
    required String progressPrefix,
    required int generation,
    required Future<bool> Function(LibraryRefreshChunk chunk) onChunk,
  }) async {
    final mergeContext = LibraryScanMergeContext(
      provider: provider,
      libraryRoot: libraryRoot,
    );
    final retainedTrackPaths = <String>{};
    final retainedEntryPaths = <String>{};
    final allFolderPaths = LinkedHashSet<String>.from(folderPaths);
    retainedEntryPaths.addAll(allFolderPaths.map(PathMatcher.normalize));
    var processedTracks = 0;

    Future<bool> mergeChunk(FolderScanChunk chunk) async {
      if (!provider.isScanGenerationActive(generation)) return false;
      retainedTrackPaths.addAll(chunk.paths.map(PathMatcher.normalize));
      for (final track in chunk.tracks) {
        retainedTrackPaths.add(PathMatcher.normalize(track.path));
      }
      allFolderPaths.addAll(chunk.folders);
      retainedEntryPaths
        ..addAll(retainedTrackPaths)
        ..addAll(chunk.folders.map(PathMatcher.normalize));
      if (chunk.tracks.isEmpty) {
        return provider.isScanGenerationActive(generation);
      }

      final existingTracks = <MusicTrack>[];
      final existingPaths = <String>{};
      for (final scannedTrack in chunk.tracks) {
        final existing = provider.trackByPath(scannedTrack.path);
        if (existing != null &&
            existingPaths.add(PathMatcher.normalize(existing.path))) {
          existingTracks.add(existing);
        }
      }
      final result = await compute(
        processScannedTracksInIsolate,
        ScanMergeIsolatePayload(
          scannedTracks: chunk.tracks,
          library: existingTracks,
          libraryRoot: libraryRoot,
          promoteRootTracksToSingles: promoteRootTracksToSingles,
          i18nImportedFiles: labels.importedFiles,
          i18nManuallySelectedFiles: labels.manuallySelectedFiles,
          exclusionMatcher: mergeContext.exclusionMatcher,
        ),
      );
      if (!provider.isScanGenerationActive(generation)) return false;
      processedTracks += chunk.tracks.length;
      return onChunk(
        LibraryRefreshChunk(
          sourceFolderPath: sourceFolderPath,
          libraryRoot: libraryRoot,
          tracks: result.trackBatch,
          progressLabel: [
            if (progressPrefix.isNotEmpty) progressPrefix,
            '[$processedTracks]',
            _displaySourceName(sourceFolderPath),
          ].join(' '),
          duplicateCount: result.duplicatesCount,
        ),
      );
    }

    var scanResult = await _dataSource.scanFolderChunked(
      sourceFolderPath,
      mergeChunk,
      onProgress: (event) {
        if (!provider.isScanGenerationActive(generation)) return;
        provider.setScanProgress(
          generation: generation,
          stage: event.stage,
          processed: event.processed,
          total: event.total,
        );
      },
    );
    if (scanResult.notSupported) {
      if (PathMatcher.isContentUri(sourceFolderPath)) {
        final legacyScan = await _scanFolderViaNative(sourceFolderPath);
        if (!legacyScan.ok) {
          scanResult = legacyScan;
        } else {
          if (!await mergeChunk(
            FolderScanChunk(tracks: legacyScan.tracks, paths: legacyScan.paths),
          )) {
            return;
          }
          scanResult = NativeScanResult.success(
            const <ScannedTrack>[],
            legacyScan.paths,
            failureCount: legacyScan.failureCount,
            completenessKnown: legacyScan.completenessKnown,
            wasCancelled: legacyScan.wasCancelled,
          );
        }
      } else {
        scanResult = await _dataSource.scanFileSystemFolderChunked(
          sourceFolderPath,
          mergeChunk,
        );
      }
    }
    if (!provider.isScanGenerationActive(generation) ||
        scanResult.wasCancelled) {
      return;
    }

    final label = [
      if (progressPrefix.isNotEmpty) progressPrefix,
      _displaySourceName(sourceFolderPath),
    ].join(' ');
    if (!scanResult.ok) {
      AppLogService.warning(
        'library_refresh_scan_failed source=$sourceFolderPath '
        'code=${scanResult.errorCode}',
        error: scanResult.errorMessage,
      );
      await onChunk(
        LibraryRefreshChunk(
          sourceFolderPath: sourceFolderPath,
          libraryRoot: libraryRoot,
          progressLabel: label,
          failureCount: 1 + additionalFailureCount,
        ),
      );
      return;
    }

    retainedTrackPaths.addAll(scanResult.paths.map(PathMatcher.normalize));
    retainedEntryPaths.addAll(retainedTrackPaths);
    final allowRemoval = scanResult.isComplete && additionalFailureCount == 0;
    final removals = await _findRefreshRemovalPaths(
      sourceFolderPath: sourceFolderPath,
      provider: provider,
      entrySnapshot: mergeContext.entrySnapshot,
      retainedTrackPaths: retainedTrackPaths,
      retainedEntryPaths: retainedEntryPaths,
      allowRemoval: allowRemoval,
      generation: generation,
    );
    if (!provider.isScanGenerationActive(generation)) return;
    await onChunk(
      LibraryRefreshChunk(
        sourceFolderPath: sourceFolderPath,
        libraryRoot: libraryRoot,
        folderPaths: allFolderPaths.toList(growable: false),
        removeWatchedFolders: allowRemoval
            ? removeWatchedFolders
            : const <String>[],
        addWatchedFolders: addWatchedFolders,
        removeTrackPaths: removals.trackPaths,
        removeEntryPaths: removals.entryPaths,
        progressLabel: label,
        failureCount: scanResult.failureCount + additionalFailureCount,
      ),
    );
  }

  Future<({List<String> trackPaths, List<String> entryPaths})>
  _findRefreshRemovalPaths({
    required String sourceFolderPath,
    required LibraryCatalogReader provider,
    required LibraryEntrySnapshot entrySnapshot,
    required Set<String> retainedTrackPaths,
    required Set<String> retainedEntryPaths,
    required bool allowRemoval,
    required int generation,
  }) async {
    if (!allowRemoval) {
      return (trackPaths: const <String>[], entryPaths: const <String>[]);
    }
    final normalizedSource = PathMatcher.normalize(sourceFolderPath);
    final retainedTrackIndex = PathMembershipIndex(retainedTrackPaths);
    final removedTrackPaths = <String>[];
    var processed = 0;
    for (final track in provider.library) {
      if (PathMatcher.isWithinOrEqualNormalized(track.path, normalizedSource) &&
          !retainedTrackIndex.containsEquivalent(track.path)) {
        removedTrackPaths.add(track.path);
      }
      if (++processed % 200 == 0) {
        await Future<void>.delayed(Duration.zero);
        if (!provider.isScanGenerationActive(generation)) {
          return (trackPaths: const <String>[], entryPaths: const <String>[]);
        }
      }
    }

    final retainedEntryIndex = PathMembershipIndex(retainedEntryPaths);
    final removedEntryPaths = <String>[];
    for (final entry in entrySnapshot.entriesByPath.values) {
      if (!PathMatcher.isWithinOrEqualNormalized(
        entry.path,
        normalizedSource,
      )) {
        continue;
      }
      final retained = entry.isFolder
          ? retainedEntryIndex.containsDescendantOrEqual(entry.path)
          : retainedEntryIndex.containsEquivalent(entry.path);
      if (!retained) removedEntryPaths.add(entry.path);
      if (++processed % 200 == 0) {
        await Future<void>.delayed(Duration.zero);
        if (!provider.isScanGenerationActive(generation)) {
          return (trackPaths: const <String>[], entryPaths: const <String>[]);
        }
      }
    }
    return (trackPaths: removedTrackPaths, entryPaths: removedEntryPaths);
  }

  Future<int> _mergeScannedTracksIncrementally({
    required String sourceFolderPath,
    required LibraryCatalog provider,
    required List<ScannedTrack> scannedTracks,
    required String? libraryRoot,
    bool promoteRootTracksToSingles = false,
    required LibraryScanLabels labels,
    Future<bool> Function()? onChunkCommitted,
    int? generation,
  }) async {
    if (scannedTracks.isEmpty) {
      return 0;
    }

    final baseFoundCount = provider.scanFoundCount;
    final baseDuplicateCount = provider.scanDuplicateCount;
    final baseFailureCount = provider.scanFailureCount;

    final mergeContext = libraryRoot == null
        ? null
        : LibraryScanMergeContext(provider: provider, libraryRoot: libraryRoot);

    final existingTracks = <MusicTrack>[];
    final existingPaths = <String>{};
    for (final scannedTrack in scannedTracks) {
      final existing = provider.trackByPath(scannedTrack.path);
      if (existing != null &&
          existingPaths.add(PathMatcher.normalize(existing.path))) {
        existingTracks.add(existing);
      }
    }

    final payload = ScanMergeIsolatePayload(
      scannedTracks: scannedTracks,
      library: existingTracks,
      libraryRoot: libraryRoot,
      promoteRootTracksToSingles: promoteRootTracksToSingles,
      i18nImportedFiles: labels.importedFiles,
      i18nManuallySelectedFiles: labels.manuallySelectedFiles,
      exclusionMatcher: mergeContext?.exclusionMatcher,
    );

    final result = await compute(processScannedTracksInIsolate, payload);

    bool isActive() => generation == null
        ? provider.isScanning
        : provider.isScanGenerationActive(generation);

    if (!isActive()) return 0;

    var added = 0;
    final trackBatch = result.trackBatch;
    final entryBatch = result.entryBatch;
    final duplicates = result.duplicatesCount;

    if (libraryRoot != null && entryBatch.isNotEmpty) {
      provider.recordLibraryEntriesForTracks(
        libraryRoot,
        entryBatch,
        exclusionMatcher: mergeContext?.exclusionMatcher,
        entrySnapshot: mergeContext?.entrySnapshot,
      );
    }

    if (trackBatch.isNotEmpty) {
      const chunkSize = 200;
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < trackBatch.length; i += chunkSize) {
        if (!isActive()) break;
        final end = (i + chunkSize < trackBatch.length)
            ? i + chunkSize
            : trackBatch.length;
        final chunk = trackBatch.sublist(i, end);

        final beforeCount = provider.library.length;
        provider.addOrReplaceTracks(chunk, notify: false);
        added += provider.library.length - beforeCount;

        provider.setScanProgress(
          currentFolder:
              '[$end/${scannedTracks.length}] ${_displaySourceName(sourceFolderPath)}',
          foundCount: baseFoundCount + added,
          duplicateCount: baseDuplicateCount + duplicates,
          failureCount: baseFailureCount,
          generation: generation,
          stage: FolderScanStage.merging,
        );

        if (onChunkCommitted != null) {
          final keepGoing = await onChunkCommitted();
          if (!keepGoing) break;
        } else if (stopwatch.elapsedMilliseconds > 10) {
          await Future<void>.delayed(Duration.zero);
          stopwatch.reset();
        }
      }
    } else {
      provider.setScanProgress(
        currentFolder:
            '[${scannedTracks.length}/${scannedTracks.length}] ${_displaySourceName(sourceFolderPath)}',
        foundCount: baseFoundCount,
        duplicateCount: baseDuplicateCount + duplicates,
        failureCount: baseFailureCount,
        generation: generation,
        stage: FolderScanStage.merging,
      );
    }

    return added;
  }

  Future<int> _importFolderIncrementally(
    String folderPath,
    LibraryCatalog provider,
    String? libraryRoot, {
    bool promoteRootTracksToSingles = false,
    required LibraryScanLabels labels,
    Future<bool> Function()? onChunkCommitted,
    int? generation,
  }) async {
    bool isActive() => generation == null
        ? provider.isScanning
        : provider.isScanGenerationActive(generation);
    if (PathMatcher.isContentUri(folderPath)) {
      provider.setScanProgress(
        failureCount: provider.scanFailureCount + 1,
        generation: generation,
      );
      return 0;
    }
    final baseFoundCount = provider.scanFoundCount;
    final baseFailureCount = provider.scanFailureCount;
    var added = 0;
    final discoveredFolders = <String>{};
    final mergeContext = libraryRoot == null
        ? null
        : LibraryScanMergeContext(provider: provider, libraryRoot: libraryRoot);
    final scanResult = await _dataSource.scanFileSystemFolderChunked(
      folderPath,
      (chunk) async {
        if (!isActive()) return false;
        discoveredFolders.addAll(chunk.folders);
        if (libraryRoot != null && chunk.folders.isNotEmpty) {
          provider.recordLibraryEntriesForTracks(
            libraryRoot,
            const <MusicTrack>[],
            folderPaths: chunk.folders,
            exclusionMatcher: mergeContext?.exclusionMatcher,
            entrySnapshot: mergeContext?.entrySnapshot,
          );
        }
        added += await _mergeScannedTracksIncrementally(
          sourceFolderPath: folderPath,
          provider: provider,
          scannedTracks: chunk.tracks,
          libraryRoot: libraryRoot,
          promoteRootTracksToSingles: promoteRootTracksToSingles,
          labels: labels,
          onChunkCommitted: onChunkCommitted,
          generation: generation,
        );
        return isActive();
      },
    );
    if (!isActive()) return added;
    final failures = scanResult.ok ? scanResult.failureCount : 1;
    provider.setScanProgress(
      foundCount: baseFoundCount + added,
      failureCount: baseFailureCount + failures,
      generation: generation,
    );
    if (!scanResult.ok) {
      AppLogService.warning(
        'library_filesystem_scan_failed source=$folderPath '
        'code=${scanResult.errorCode}',
        error: scanResult.errorMessage,
      );
      return added;
    }

    if (scanResult.isComplete) {
      provider.removeTracksDeletedFromFolder(folderPath, scanResult.paths);
      if (libraryRoot != null) {
        provider.removeLibraryEntriesDeletedFromFolder(
          libraryRoot,
          folderPath,
          <String>{...scanResult.paths, ...discoveredFolders},
        );
      }
    }
    return added;
  }

  Future<NativeScanResult> _scanFolderViaNative(String folderPath) async {
    return _dataSource.scanFolder(folderPath);
  }

  Future<_IncrementalNativeImport?> _importNativeFolderChunkedIncrementally({
    required String sourceFolderPath,
    required LibraryCatalog provider,
    required String? libraryRoot,
    required LibraryScanLabels labels,
    bool promoteRootTracksToSingles = false,
    Future<bool> Function()? onChunkCommitted,
    required int generation,
  }) async {
    var added = 0;
    var failures = 0;
    final baseFailureCount = provider.scanFailureCount;
    final result = await _dataSource.scanFolderChunked(
      sourceFolderPath,
      (chunk) async {
        if (!provider.isScanGenerationActive(generation)) return false;
        failures += chunk.failureCount;
        if (chunk.tracks.isEmpty) {
          if (failures > 0) {
            provider.setScanProgress(
              failureCount: baseFailureCount + failures,
              generation: generation,
            );
          }
          return provider.isScanGenerationActive(generation);
        }
        added += await _mergeScannedTracksIncrementally(
          sourceFolderPath: sourceFolderPath,
          provider: provider,
          scannedTracks: chunk.tracks,
          libraryRoot: libraryRoot,
          promoteRootTracksToSingles: promoteRootTracksToSingles,
          labels: labels,
          onChunkCommitted: onChunkCommitted,
          generation: generation,
        );
        if (failures > 0) {
          provider.setScanProgress(
            failureCount: baseFailureCount + failures,
            generation: generation,
          );
        }
        return provider.isScanGenerationActive(generation);
      },
      onProgress: (event) {
        if (!provider.isScanGenerationActive(generation)) return;
        provider.setScanProgress(
          generation: generation,
          stage: event.stage,
          processed: event.processed,
          total: event.total,
        );
      },
    );
    if (result.notSupported) return null;
    if (!result.ok) {
      provider.setScanProgress(
        failureCount: provider.scanFailureCount + 1,
        generation: generation,
      );
      AppLogService.warning(
        'library_native_chunked_scan_failed '
        'source=$sourceFolderPath code=${result.errorCode}',
        error: result.errorMessage,
      );
      return _IncrementalNativeImport(added: 0, result: result);
    }
    if (!provider.isScanGenerationActive(generation)) {
      return _IncrementalNativeImport(added: added, result: result);
    }
    if (result.isComplete) {
      provider.removeTracksDeletedFromFolder(sourceFolderPath, result.paths);
      if (libraryRoot != null) {
        provider.removeLibraryEntriesDeletedFromFolder(
          libraryRoot,
          sourceFolderPath,
          result.paths,
        );
      }
    }
    return _IncrementalNativeImport(added: added, result: result);
  }

  Future<_FolderImportOutcome> _importLibraryWithSingleScan(
    String libraryRoot,
    LibraryCatalog provider,
    LibraryScanLabels labels, {
    Future<bool> Function()? onChunkCommitted,
    required int generation,
  }) async {
    provider.setScanProgress(
      currentFolder: _displaySourceName(libraryRoot),
      generation: generation,
    );
    final chunkedAdded = await _importNativeFolderChunkedIncrementally(
      sourceFolderPath: libraryRoot,
      provider: provider,
      libraryRoot: libraryRoot,
      promoteRootTracksToSingles: true,
      labels: labels,
      onChunkCommitted: onChunkCommitted,
      generation: generation,
    );
    if (chunkedAdded != null) {
      return _FolderImportOutcome(
        added: chunkedAdded.added,
        complete:
            provider.isScanGenerationActive(generation) &&
            chunkedAdded.result.isComplete,
      );
    }

    final nativeScan = await _scanFolderViaNative(libraryRoot);
    if (!nativeScan.ok) {
      if (nativeScan.notSupported || !PathMatcher.isContentUri(libraryRoot)) {
        final failuresBefore = provider.scanFailureCount;
        final added = await _importFolderIncrementally(
          libraryRoot,
          provider,
          libraryRoot,
          promoteRootTracksToSingles: true,
          labels: labels,
          onChunkCommitted: onChunkCommitted,
          generation: generation,
        );
        return _FolderImportOutcome(
          added: added,
          complete:
              provider.isScanGenerationActive(generation) &&
              provider.scanFailureCount == failuresBefore,
        );
      }
      provider.setScanProgress(
        failureCount: provider.scanFailureCount + 1,
        generation: generation,
      );
      AppLogService.warning(
        'library_native_scan_failed source=$libraryRoot '
        'code=${nativeScan.errorCode}',
        error: nativeScan.errorMessage,
      );
      return const _FolderImportOutcome(added: 0, complete: false);
    }

    final added = await _mergeScannedTracksIncrementally(
      sourceFolderPath: libraryRoot,
      provider: provider,
      scannedTracks: nativeScan.tracks,
      libraryRoot: libraryRoot,
      promoteRootTracksToSingles: true,
      labels: labels,
      onChunkCommitted: onChunkCommitted,
      generation: generation,
    );
    final scannedPaths = nativeScan.paths;
    if (nativeScan.isComplete) {
      provider.removeTracksDeletedFromFolder(libraryRoot, scannedPaths);
      provider.removeLibraryEntriesDeletedFromFolder(
        libraryRoot,
        libraryRoot,
        scannedPaths,
      );
    }
    return _FolderImportOutcome(
      added: added,
      complete:
          provider.isScanGenerationActive(generation) && nativeScan.isComplete,
    );
  }

  Future<List<String>> _listImmediateChildFolders(String folderPath) async {
    return (await _dataSource.listImmediateChildFolders(folderPath)).folders;
  }

  Future<LibraryChildFolderListing> _listImmediateChildFoldersResult(
    String folderPath,
  ) {
    return _dataSource.listImmediateChildFolders(folderPath);
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
    final existingTrackPaths = provider.library
        .map((track) => PathMatcher.normalize(track.path))
        .toSet();
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
      final chunkedImport = await _importNativeFolderChunkedIncrementally(
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
        final nativeScan = await _scanFolderViaNative(folderPath);
        if (nativeScan.ok) {
          added = await _mergeScannedTracksIncrementally(
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
          added = await _importFolderIncrementally(
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
      if (!completed) {
        _rollbackScanAdditions(
          provider: provider,
          existingTrackPaths: existingTrackPaths,
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
      try {
        await provider.endLibraryBatch();
      } finally {
        provider.finishScan(generation);
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
    final childFolders = await _listImmediateChildFolders(normalizedFolderPath);
    final importTargets = childFolders;
    final existingTrackPaths = provider.library
        .map((track) => PathMatcher.normalize(track.path))
        .toSet();
    final existingEntryPaths = provider
        .libraryEntriesForLibrary(normalizedFolderPath)
        .map((entry) => PathMatcher.normalize(entry.path))
        .toSet();
    provider.beginLibraryBatch();
    var added = 0;
    var completed = false;
    var wasCancelled = false;
    try {
      final outcome = await _importLibraryWithSingleScan(
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
      completed = outcome.complete;
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
        for (final childFolder in importTargets) {
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
      if (!completed) {
        _rollbackScanAdditions(
          provider: provider,
          existingTrackPaths: existingTrackPaths,
          existingEntryPathsByRoot: <String, Set<String>>{
            normalizedFolderPath: existingEntryPaths,
          },
        );
      }
      try {
        await provider.endLibraryBatch();
      } finally {
        provider.finishScan(generation);
      }
      if (completed) {
        for (final childFolder in importTargets) {
          if (!provider.isLibraryPathExcluded(
            normalizedFolderPath,
            childFolder,
          )) {
            unawaited(_prefillRjDetailForFolder(provider, childFolder));
          }
        }
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
        'folderCount': importTargets.length,
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
      if (candidates.any(
        (track) => _rules.isTrackAlreadyInLibrary(
          trackPath: track.path,
          watchedFolders: provider.watchedFolders,
          watchedLibraries: provider.watchedLibraries,
          tracks: provider.library,
        ),
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
