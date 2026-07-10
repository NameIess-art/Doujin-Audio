import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../providers/audio_provider.dart';
import '../i18n/app_language_provider.dart';
import 'audio_state_services.dart';
import 'path_matcher.dart';
import 'path_display.dart';
import 'media_file_support.dart';
import 'library_scan_models.dart';
import 'library_refresh_chunk_planner.dart';
import 'library_scanner_isolate.dart';
import 'file_cache_platform_gateway.dart';

export 'library_scan_models.dart';
export 'library_refresh_chunk_planner.dart';

class LibraryScanMergeContext {
  LibraryScanMergeContext({
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
  LibraryScannerService({FileCachePlatformGateway? platformGateway})
    : _platformGateway = platformGateway ?? FileCachePlatformGateway.instance;

  static const Duration _foregroundRefreshCommitInterval = Duration(
    milliseconds: 400,
  );

  final FileCachePlatformGateway _platformGateway;
  DateTime? _lastBatchFlushTime;

  void _rollbackScanAdditions({
    required AudioProvider provider,
    required Set<String> existingTrackPaths,
    required Map<String, Set<String>> existingEntryPathsByRoot,
  }) {
    provider.removeTracksByPath(
      provider.library
          .where(
            (track) => !existingTrackPaths.contains(
              PathMatcher.normalize(track.path),
            ),
          )
          .map((track) => track.path),
    );
    for (final entry in existingEntryPathsByRoot.entries) {
      provider.removeLibraryEntriesByPaths(
        entry.key,
        provider
            .libraryEntriesForLibrary(entry.key)
            .where(
              (candidate) => !entry.value.contains(
                PathMatcher.normalize(candidate.path),
              ),
            )
            .map((candidate) => candidate.path),
      );
    }
  }

  bool _pathsOverlap(String first, String second) {
    return PathMatcher.isWithinOrEqual(first, second) ||
        PathMatcher.isWithinOrEqual(second, first);
  }

  Future<bool> _flushRefreshBatch(AudioProvider provider) async {
    final now = DateTime.now();
    final lastFlush = _lastBatchFlushTime;
    if (lastFlush != null &&
        now.difference(lastFlush) < _foregroundRefreshCommitInterval) {
      await Future<void>.delayed(Duration.zero);
      if (!provider.isScanning) {
        await provider.endLibraryBatch();
        return false;
      }
      return true;
    }
    _lastBatchFlushTime = now;
    await provider.endLibraryBatch();
    await Future<void>.delayed(Duration.zero);
    if (!provider.isScanning) {
      return false;
    }
    provider.beginLibraryBatch();

    return true;
  }

  Future<bool> _ensureReadPermissionForSources(Iterable<String> sources) async {
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

  Future<void> refreshWatchedFolders({
    required AudioProvider provider,
    required AppLanguageProvider i18n,
    required void Function(String) showSnack,
    bool silent = false,
    bool forceShowResult = false,
  }) async {
    final watchedFolders = provider.watchedFolders;
    final watchedLibraries = provider.watchedLibraries;
    if (watchedFolders.isEmpty && watchedLibraries.isEmpty) return;

    final permissionGranted = await _ensureReadPermissionForSources([
      ...watchedFolders,
      ...watchedLibraries,
    ]);
    if (!permissionGranted) {
      if (!silent) showSnack(i18n.tr('need_storage_permission_scan_folder'));
      return;
    }

    final generation = provider.tryBeginScan(
      source: _displaySourceName(
        watchedLibraries.isNotEmpty
            ? watchedLibraries.first
            : watchedFolders.first,
      ),
      background: true,
    );
    if (generation == 0) return;
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
    final deferredCleanupChunks = <LibraryRefreshChunk>[];

    Future<void> applyFolderResult(LibraryRefreshFolderResult result) async {
      if (!provider.isScanGenerationActive(generation) ||
          !batchOpen ||
          result.chunks.isEmpty) {
        return;
      }
      if (!batchStarted) {
        provider.beginStagedLibraryRefresh();
        batchStarted = true;
      }
      for (final chunk in result.chunks) {
        if (!provider.isScanGenerationActive(generation) || !batchOpen) break;
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
          batchOpen = await provider.flushStagedLibraryRefreshChunk();
        }
      }
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
          await applyFolderResult(
            await _scanLibraryRootForRefresh(
              libraryRoot: libraryRoot,
              provider: provider,
              i18n: i18n,
              generation: generation,
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
          await applyFolderResult(
            await _scanWatchedFolderForRefresh(
              folderPath: folderPath,
              effectiveLibraryRoot: libraryRoot.isEmpty
                  ? folderPath
                  : libraryRoot,
              provider: provider,
              i18n: i18n,
              progressPrefix: '[$processedFolders/$totalFolders]',
              generation: generation,
            ),
          );
        }
      } finally {
        if (batchStarted && batchOpen) {
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
      final wasCancelled = !provider.isScanGenerationActive(generation);
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

      if (!silent || forceShowResult || totalAdded > 0) {
        showSnack(
          totalAdded > 0
              ? i18n.tr('refresh_done_added', {'count': totalAdded})
              : i18n.tr('refresh_done_no_new'),
        );
      }
    }
  }

  Future<LibraryRefreshFolderResult> _scanLibraryRootForRefresh({
    required String libraryRoot,
    required AudioProvider provider,
    required AppLanguageProvider i18n,
    required int generation,
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
    return _scanFolderForRefresh(
      sourceFolderPath: libraryRoot,
      libraryRoot: libraryRoot,
      provider: provider,
      i18n: i18n,
      promoteRootTracksToSingles: true,
      folderPaths: childFolders,
      removeWatchedFolders: [libraryRoot],
      addWatchedFolders: visibleChildFolders,
      additionalFailureCount: childFolderResult.complete ? 0 : 1,
      progressPrefix: '',
      generation: generation,
    );
  }

  Future<LibraryRefreshFolderResult> _scanWatchedFolderForRefresh({
    required String folderPath,
    required String effectiveLibraryRoot,
    required AudioProvider provider,
    required AppLanguageProvider i18n,
    required String progressPrefix,
    required int generation,
  }) {
    return _scanFolderForRefresh(
      sourceFolderPath: folderPath,
      libraryRoot: effectiveLibraryRoot,
      provider: provider,
      i18n: i18n,
      progressPrefix: progressPrefix,
      generation: generation,
    );
  }

  Future<LibraryRefreshFolderResult> _scanFolderForRefresh({
    required String sourceFolderPath,
    required String libraryRoot,
    required AudioProvider provider,
    required AppLanguageProvider i18n,
    bool promoteRootTracksToSingles = false,
    List<String> folderPaths = const <String>[],
    List<String> removeWatchedFolders = const <String>[],
    List<String> addWatchedFolders = const <String>[],
    int additionalFailureCount = 0,
    required String progressPrefix,
    required int generation,
  }) async {
    final nativeScan = await _scanFolderViaNative(sourceFolderPath);
    if (nativeScan.ok) {
      return _buildFolderRefreshResult(
        sourceFolderPath: sourceFolderPath,
        libraryRoot: libraryRoot,
        provider: provider,
        i18n: i18n,
        scannedTracks: nativeScan.tracks,
        retainedTrackPaths: nativeScan.paths,
        retainedEntryPaths: nativeScan.paths,
        folderPaths: folderPaths,
        removeWatchedFolders: removeWatchedFolders,
        addWatchedFolders: addWatchedFolders,
        promoteRootTracksToSingles: promoteRootTracksToSingles,
        allowRemoval: nativeScan.isComplete && additionalFailureCount == 0,
        failureCount: nativeScan.failureCount + additionalFailureCount,
        progressPrefix: progressPrefix,
        generation: generation,
      );
    }

    if (nativeScan.notSupported ||
        !PathMatcher.isContentUri(sourceFolderPath)) {
      final payload = await Isolate.run(
        () => _scanFileSystemFolderPayload(sourceFolderPath),
      );
      if (!provider.isScanGenerationActive(generation)) {
        return LibraryRefreshFolderResult(
          sourceFolderPath: sourceFolderPath,
          libraryRoot: libraryRoot,
        );
      }
      final scannedTracks =
          ((payload['tracks'] as List<Object?>?) ?? const <Object?>[])
              .whereType<Map<Object?, Object?>>()
              .map(ScannedTrack.fromPayload)
              .toList(growable: false);
      final discoveredPaths = stringSetFromPayload(payload['discoveredPaths']);
      final discoveredFolders =
          ((payload['folderPaths'] as List<Object?>?) ?? const <Object?>[])
              .whereType<String>()
              .toList(growable: false);
      final allFolderPaths = LinkedHashSet<String>.from(folderPaths)
        ..addAll(discoveredFolders);
      final failureCount =
          ((payload['failureCount'] as int?) ?? 0) + additionalFailureCount;
      final retainedEntryPaths = <String>{
        ...discoveredPaths,
        ...allFolderPaths,
      };
      return _buildFolderRefreshResult(
        sourceFolderPath: sourceFolderPath,
        libraryRoot: libraryRoot,
        provider: provider,
        i18n: i18n,
        scannedTracks: scannedTracks,
        retainedTrackPaths: discoveredPaths,
        retainedEntryPaths: retainedEntryPaths,
        folderPaths: allFolderPaths.toList(growable: false),
        removeWatchedFolders: removeWatchedFolders,
        addWatchedFolders: addWatchedFolders,
        promoteRootTracksToSingles: promoteRootTracksToSingles,
        allowRemoval: failureCount == 0,
        failureCount: failureCount,
        progressPrefix: progressPrefix,
        generation: generation,
      );
    }

    final label = [
      if (progressPrefix.isNotEmpty) progressPrefix,
      _displaySourceName(sourceFolderPath),
    ].join(' ');
    return LibraryRefreshFolderResult(
      sourceFolderPath: sourceFolderPath,
      libraryRoot: libraryRoot,
      chunks: <LibraryRefreshChunk>[
        LibraryRefreshChunk(
          sourceFolderPath: sourceFolderPath,
          libraryRoot: libraryRoot,
          progressLabel: label,
          failureCount: 1 + additionalFailureCount,
        ),
      ],
      failureCount: 1 + additionalFailureCount,
    );
  }

  Future<LibraryRefreshFolderResult> _buildFolderRefreshResult({
    required String sourceFolderPath,
    required String libraryRoot,
    required AudioProvider provider,
    required AppLanguageProvider i18n,
    required List<ScannedTrack> scannedTracks,
    required Set<String> retainedTrackPaths,
    required Set<String> retainedEntryPaths,
    required List<String> folderPaths,
    required List<String> removeWatchedFolders,
    required List<String> addWatchedFolders,
    required bool promoteRootTracksToSingles,
    required bool allowRemoval,
    required String progressPrefix,
    required int generation,
    int failureCount = 0,
  }) async {
    final mergeContext = LibraryScanMergeContext(
      provider: provider,
      libraryRoot: libraryRoot,
    );
    final payload = ScanMergeIsolatePayload(
      scannedTracks: scannedTracks,
      library: provider.library,
      libraryRoot: libraryRoot,
      promoteRootTracksToSingles: promoteRootTracksToSingles,
      i18nImportedFiles: i18n.tr('imported_files'),
      i18nManuallySelectedFiles: i18n.tr('manually_selected_files'),
      exclusionMatcher: mergeContext.exclusionMatcher,
      sourceFolderPath: sourceFolderPath,
      allowRemoval: allowRemoval,
      retainedTrackPaths: retainedTrackPaths,
      retainedEntryPaths: retainedEntryPaths,
      entrySnapshot: mergeContext.entrySnapshot,
    );
    final result = await compute(processScannedTracksInIsolate, payload);
    if (!provider.isScanGenerationActive(generation)) {
      return LibraryRefreshFolderResult(
        sourceFolderPath: sourceFolderPath,
        libraryRoot: libraryRoot,
      );
    }

    final existingPaths = provider.library
        .map((track) => PathMatcher.normalize(track.path))
        .toSet();
    final addedCount = result.trackBatch.fold<int>(
      0,
      (sum, track) =>
          sum +
          (existingPaths.contains(PathMatcher.normalize(track.path)) ? 0 : 1),
    );
    final chunks = buildLibraryRefreshChunks(
      sourceFolderPath: sourceFolderPath,
      libraryRoot: libraryRoot,
      sourceLabel: _displaySourceName(sourceFolderPath),
      tracks: result.trackBatch,
      folderPaths: folderPaths,
      removeWatchedFolders: allowRemoval
          ? removeWatchedFolders
          : const <String>[],
      addWatchedFolders: addWatchedFolders,
      removeTrackPaths: result.removedTrackPaths,
      removeEntryPaths: result.removedEntryPaths,
      duplicateCount: result.duplicatesCount,
      failureCount: failureCount,
      progressPrefix: progressPrefix,
    );
    return LibraryRefreshFolderResult(
      sourceFolderPath: sourceFolderPath,
      libraryRoot: libraryRoot,
      chunks: chunks,
      addedCount: addedCount,
      duplicateCount: result.duplicatesCount,
      failureCount: failureCount,
    );
  }

  Future<int> _mergeScannedTracksIncrementally({
    required String sourceFolderPath,
    required AudioProvider provider,
    required List<ScannedTrack> scannedTracks,
    required String? libraryRoot,
    bool promoteRootTracksToSingles = false,
    AppLanguageProvider? i18n,
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

    final payload = ScanMergeIsolatePayload(
      scannedTracks: scannedTracks,
      library: provider.library,
      libraryRoot: libraryRoot,
      promoteRootTracksToSingles: promoteRootTracksToSingles,
      i18nImportedFiles: i18n?.tr('imported_files') ?? 'Imported Files',
      i18nManuallySelectedFiles:
          i18n?.tr('manually_selected_files') ?? 'Manually Selected Files',
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
    AudioProvider provider,
    String? libraryRoot, {
    bool promoteRootTracksToSingles = false,
    AppLanguageProvider? i18n,
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
    final folder = Directory(folderPath);
    if (!await folder.exists()) {
      provider.setScanProgress(
        failureCount: provider.scanFailureCount + 1,
        generation: generation,
      );
      return 0;
    }

    final payload = await Isolate.run(
      () => _scanFileSystemFolderPayload(folderPath),
    );
    if (!isActive()) return 0;

    final scannedTracks =
        ((payload['tracks'] as List<Object?>?) ?? const <Object?>[])
            .whereType<Map<Object?, Object?>>()
            .map(ScannedTrack.fromPayload)
            .toList(growable: false);
    final discoveredPaths = stringSetFromPayload(payload['discoveredPaths']);
    final discoveredFolders =
        ((payload['folderPaths'] as List<Object?>?) ?? const <Object?>[])
            .whereType<String>()
            .toList(growable: false);

    final baseFoundCount = provider.scanFoundCount;
    final baseDuplicateCount = provider.scanDuplicateCount;
    final baseFailureCount = provider.scanFailureCount;
    var added = 0;
    final failures = (payload['failureCount'] as int?) ?? 0;
    final mergeContext = libraryRoot == null
        ? null
        : LibraryScanMergeContext(provider: provider, libraryRoot: libraryRoot);

    if (libraryRoot != null && discoveredFolders.isNotEmpty) {
      provider.recordLibraryEntriesForTracks(
        libraryRoot,
        const <MusicTrack>[],
        folderPaths: discoveredFolders,
        exclusionMatcher: mergeContext?.exclusionMatcher,
        entrySnapshot: mergeContext?.entrySnapshot,
      );
    }

    final isolatePayload = ScanMergeIsolatePayload(
      scannedTracks: scannedTracks,
      library: provider.library,
      libraryRoot: libraryRoot,
      promoteRootTracksToSingles: promoteRootTracksToSingles,
      i18nImportedFiles: i18n?.tr('imported_files') ?? 'Imported Files',
      i18nManuallySelectedFiles:
          i18n?.tr('manually_selected_files') ?? 'Manually Selected Files',
      exclusionMatcher: mergeContext?.exclusionMatcher,
    );

    final result = await compute(
      processScannedTracksInIsolate,
      isolatePayload,
    );

    if (!isActive()) return 0;

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

        final before = provider.library.length;
        provider.addOrReplaceTracks(chunk, notify: false);
        added += provider.library.length - before;

        provider.setScanProgress(
          currentFolder:
              '[$end/${scannedTracks.length}] ${_displaySourceName(folderPath)}',
          foundCount: baseFoundCount + added,
          duplicateCount: baseDuplicateCount + duplicates,
          failureCount: baseFailureCount + failures,
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
            '[${scannedTracks.length}/${scannedTracks.length}] ${_displaySourceName(folderPath)}',
        foundCount: baseFoundCount,
        duplicateCount: baseDuplicateCount + duplicates,
        failureCount: baseFailureCount + failures,
        generation: generation,
        stage: FolderScanStage.merging,
      );
    }

    if (isActive() && failures == 0) {
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
        generation: generation,
      );
    }
    return added;
  }

  Future<NativeScanResult> _scanFolderViaNative(String folderPath) async {
    return _platformGateway.scanFolder(folderPath);
  }

  Future<_IncrementalNativeImport?> _importNativeFolderChunkedIncrementally({
    required String sourceFolderPath,
    required AudioProvider provider,
    required String? libraryRoot,
    required AppLanguageProvider i18n,
    bool promoteRootTracksToSingles = false,
    Future<bool> Function()? onChunkCommitted,
    required int generation,
  }) async {
    var added = 0;
    var failures = 0;
    final baseFailureCount = provider.scanFailureCount;
    final result = await _platformGateway.scanFolderChunked(
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
          i18n: i18n,
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
      debugPrint(
        '[library-import] native chunked scan failed for $sourceFolderPath '
        'code=${result.errorCode} message=${result.errorMessage}',
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
    AudioProvider provider,
    AppLanguageProvider i18n, {
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
      i18n: i18n,
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
          i18n: i18n,
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
      debugPrint(
        '[library-import] native scan failed for content uri: $libraryRoot '
        'code=${nativeScan.errorCode} message=${nativeScan.errorMessage}',
      );
      return const _FolderImportOutcome(added: 0, complete: false);
    }

    final added = await _mergeScannedTracksIncrementally(
      sourceFolderPath: libraryRoot,
      provider: provider,
      scannedTracks: nativeScan.tracks,
      libraryRoot: libraryRoot,
      promoteRootTracksToSingles: true,
      i18n: i18n,
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
    return (await _listImmediateChildFoldersResult(folderPath)).folders;
  }

  Future<({List<String> folders, bool complete})>
  _listImmediateChildFoldersResult(String folderPath) async {
    if (Platform.isAndroid) {
      final folders = await _platformGateway.listChildFolders(folderPath);
      if (folders != null) {
        return (folders: folders, complete: true);
      }
      if (PathMatcher.isContentUri(folderPath)) {
        return (folders: const <String>[], complete: false);
      }
    }

    final directory = Directory(folderPath);
    if (!await directory.exists()) {
      return (folders: const <String>[], complete: false);
    }

    final childFolders = <String>[];
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! Directory) continue;
        childFolders.add(path.normalize(entity.path));
      }
    } catch (_) {
      return (folders: const <String>[], complete: false);
    }

    childFolders.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return (folders: childFolders, complete: true);
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
    AudioProvider provider,
    String folderPath,
  ) async {
    try {
      await provider.prefillAudioDetailRjCodeFromText(
        AudioDetailTarget.libraryRootFolder(folderPath),
        _displaySourceName(folderPath),
      );
    } catch (_) {
      // Metadata prefill is optional and must not block adding the library.
    }
  }

  bool _isFolderAlreadyInLibrary(AudioProvider provider, String folderPath) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    if (provider.watchedFolders.any(
      (value) => _pathsOverlap(value, normalizedFolderPath),
    )) {
      return true;
    }
    if (provider.watchedLibraries.any(
      (value) => _pathsOverlap(value, normalizedFolderPath),
    )) {
      return true;
    }
    return provider.library.any(
      (track) =>
          _pathsOverlap(track.path, normalizedFolderPath) ||
          (track.groupKey != '__single_files__' &&
              _pathsOverlap(track.groupKey, normalizedFolderPath)),
    );
  }

  bool _isTrackAlreadyInLibrary(AudioProvider provider, String trackPath) {
    final normalizedTrackPath = PathMatcher.normalize(trackPath);
    if (provider.trackByPath(normalizedTrackPath) != null) {
      return true;
    }
    if (provider.watchedFolders.any(
      (value) => PathMatcher.isWithinOrEqual(normalizedTrackPath, value),
    )) {
      return true;
    }
    if (provider.watchedLibraries.any(
      (value) => PathMatcher.isWithinOrEqual(normalizedTrackPath, value),
    )) {
      return true;
    }
    return provider.library.any(
      (track) =>
          PathMatcher.equalsNormalized(track.path, normalizedTrackPath) ||
          (track.groupKey != '__single_files__' &&
              PathMatcher.isWithinOrEqual(normalizedTrackPath, track.groupKey)),
    );
  }

  bool _hasWatchedLibraryOverlap(
    AudioProvider provider,
    String normalizedFolderPath,
  ) {
    return provider.watchedLibraries.any(
      (value) => _pathsOverlap(value, normalizedFolderPath),
    );
  }

  bool _isNestedInsideStandaloneFolder(
    AudioProvider provider,
    String normalizedFolderPath,
  ) {
    return provider.watchedFolders.any(
      (value) =>
          PathMatcher.isWithinOrEqual(normalizedFolderPath, value) &&
          !PathMatcher.equalsNormalized(value, normalizedFolderPath),
    );
  }

  List<String> _watchedFoldersToPromote(
    AudioProvider provider,
    String normalizedFolderPath,
  ) {
    return provider.watchedFolders
        .where(
          (value) => PathMatcher.isWithinOrEqual(value, normalizedFolderPath),
        )
        .toList(growable: false);
  }

  bool _hasUnmanagedLibraryContentOverlap(
    AudioProvider provider,
    String normalizedFolderPath,
    List<String> promotedFolders,
  ) {
    return provider.library.any((track) {
      final belongsToPromotedFolder = promotedFolders.any(
        (folderPath) =>
            PathMatcher.isWithinOrEqual(track.path, folderPath) ||
            (track.groupKey != '__single_files__' &&
                PathMatcher.isWithinOrEqual(track.groupKey, folderPath)),
      );
      if (belongsToPromotedFolder) return false;
      return _pathsOverlap(track.path, normalizedFolderPath) ||
          (track.groupKey != '__single_files__' &&
              _pathsOverlap(track.groupKey, normalizedFolderPath));
    });
  }

  Future<String?> _pickAudioFolderViaNative() async {
    return _platformGateway.pickAudioFolder();
  }

  Future<List<PickedAudioFile>?> _pickAudioFilesViaNative() async {
    return _platformGateway.pickAudioFiles();
  }

  List<MusicTrack> _tracksFromPickedAudioFiles(
    List<PickedAudioFile> files,
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

  Future<Directory> _persistentImportDirectory() async {
    final supportDir = await getApplicationSupportDirectory();
    return Directory(path.join(supportDir.path, 'nameless_audio_imports'));
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
      } catch (_) {
        // Failed archive extraction falls through to the next import strategy.
      }
    }

    if (Platform.isAndroid &&
        identifier != null &&
        identifier.startsWith('content://')) {
      try {
        return await _platformGateway.cacheFromUri(
          uri: identifier,
          name: file.name,
          index: index,
        );
      } catch (_) {
        // Failed native import falls through to the remaining import strategy.
      }
    }
    return null;
  }

  Future<void> addFolder({
    required AudioProvider provider,
    required AppLanguageProvider i18n,
    required void Function(String) showSnack,
  }) async {
    if (Platform.isAndroid) {
      try {
        final folderPath = await _pickAudioFolderViaNative();
        if (folderPath == null || folderPath.isEmpty) return;
        await _addFolderFromPath(folderPath, provider, i18n, showSnack);
        return;
      } on PlatformException {
        // Fall back to the generic picker below.
      }
    }

    final folderPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: i18n.tr('choose_music_folder'),
    );
    if (folderPath == null || folderPath.isEmpty) return;
    await _addFolderFromPath(folderPath, provider, i18n, showSnack);
  }

  Future<void> _addFolderFromPath(
    String folderPath,
    AudioProvider provider,
    AppLanguageProvider i18n,
    void Function(String) showSnack,
  ) async {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    if (_isFolderAlreadyInLibrary(provider, folderPath)) {
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
        showSnack(i18n.tr('library_item_exists'));
        return;
      }
    }

    final generation = provider.tryBeginScan(
      source: _displaySourceName(folderPath),
    );
    if (generation == 0) {
      showSnack(i18n.tr('scanning_title'));
      return;
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

    try {
      provider.setScanProgress(
        currentFolder: _displaySourceName(folderPath),
        generation: generation,
      );
      final chunkedImport = await _importNativeFolderChunkedIncrementally(
        sourceFolderPath: folderPath,
        provider: provider,
        libraryRoot: normalizedFolderPath,
        i18n: i18n,
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
          debugPrint(
            '[library-import] native scan failed for content uri: $folderPath '
            'code=${nativeScan.errorCode} message=${nativeScan.errorMessage}',
          );
        }
      }
    } finally {
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
      await provider.endLibraryBatch();
      if (completed) {
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
      provider.finishScan(generation);
      if (completed) {
        unawaited(_prefillRjDetailForFolder(provider, normalizedFolderPath));
      }
    }
    showSnack(
      completed
          ? i18n.tr('import_done_added', {'count': added})
          : i18n.tr('scan_failed_next_step'),
    );
  }

  Future<void> addLibrary({
    required AudioProvider provider,
    required AppLanguageProvider i18n,
    required void Function(String) showSnack,
  }) async {
    if (Platform.isAndroid) {
      try {
        final folderPath = await _pickAudioFolderViaNative();
        if (folderPath == null || folderPath.isEmpty) return;
        await _addLibraryFromPath(folderPath, provider, i18n, showSnack);
        return;
      } on PlatformException {
        // Fall back to the generic picker below.
      }
    }

    final folderPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: i18n.tr('choose_library_folder'),
    );
    if (folderPath == null || folderPath.isEmpty) return;
    await _addLibraryFromPath(folderPath, provider, i18n, showSnack);
  }

  Future<void> _addLibraryFromPath(
    String folderPath,
    AudioProvider provider,
    AppLanguageProvider i18n,
    void Function(String) showSnack,
  ) async {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    final promotedFolders = _watchedFoldersToPromote(
      provider,
      normalizedFolderPath,
    );
    if (_hasWatchedLibraryOverlap(provider, normalizedFolderPath) ||
        _isNestedInsideStandaloneFolder(provider, normalizedFolderPath) ||
        _hasUnmanagedLibraryContentOverlap(
          provider,
          normalizedFolderPath,
          promotedFolders,
        )) {
      showSnack(i18n.tr('library_item_exists'));
      return;
    }
    final generation = provider.tryBeginScan(
      source: _displaySourceName(normalizedFolderPath),
    );
    if (generation == 0) {
      showSnack(i18n.tr('scanning_title'));
      return;
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
    try {
      final outcome = await _importLibraryWithSingleScan(
        normalizedFolderPath,
        provider,
        i18n,
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
      await provider.endLibraryBatch();
      provider.finishScan(generation);
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
    showSnack(
      completed
          ? i18n.tr('import_library_done', {
              'count': added,
              'folderCount': importTargets.length,
            })
          : i18n.tr('scan_failed_next_step'),
    );
  }

  Future<void> addFiles({
    required AudioProvider provider,
    required AppLanguageProvider i18n,
    required void Function(String) showSnack,
  }) async {
    if (Platform.isAndroid) {
      try {
        final pickedFiles = await _pickAudioFilesViaNative();
        if (pickedFiles == null || pickedFiles.isEmpty) return;

        final generation = provider.tryBeginScan(
          source: i18n.tr('imported_files'),
        );
        if (generation == 0) {
          showSnack(i18n.tr('scanning_title'));
          return;
        }
        provider.beginLibraryBatch();

        try {
          final candidates = _tracksFromPickedAudioFiles(pickedFiles, i18n);
          if (candidates.any(
            (track) => _isTrackAlreadyInLibrary(provider, track.path),
          )) {
            showSnack(i18n.tr('library_item_exists'));
            return;
          }
          final beforeCount = provider.library.length;
          provider.addTracks(candidates, notify: false);
          final added = provider.library.length - beforeCount;
          showSnack(i18n.tr('import_done_added', {'count': added}));
        } finally {
          await provider.endLibraryBatch();
          provider.finishScan(generation);
        }
        return;
      } on PlatformException {
        // Fall back to the generic picker below.
      }
    }

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withReadStream: true,
      dialogTitle: i18n.tr('choose_audio_files'),
    );
    if (result == null) return;

    final generation = provider.tryBeginScan(source: i18n.tr('imported_files'));
    if (generation == 0) {
      showSnack(i18n.tr('scanning_title'));
      return;
    }
    provider.beginLibraryBatch();

    try {
      final resolvedPaths = <String>[];
      for (var i = 0; i < result.files.length; i++) {
        final file = result.files[i];
        final rawPath = file.path;
        final needsCopy =
            rawPath == null ||
            rawPath.isEmpty ||
            rawPath.startsWith('content://');

        if (!needsCopy) {
          resolvedPaths.add(path.normalize(rawPath));
          continue;
        }

        final cachedPath = await _cachePickedFile(file, i);
        if (cachedPath != null) {
          resolvedPaths.add(path.normalize(cachedPath));
        }
      }

      if (resolvedPaths.any(
        (trackPath) => _isTrackAlreadyInLibrary(provider, trackPath),
      )) {
        showSnack(i18n.tr('library_item_exists'));
        return;
      }

      final candidates = <MusicTrack>[];
      for (final p in resolvedPaths.where(isSupportedMediaFile)) {
        final file = File(p);
        FileStat? fileStat;
        try {
          fileStat = await file.stat();
        } catch (_) {
          // File timestamps are optional scan metadata.
        }
        candidates.add(
          MusicTrack(
            path: p,
            displayName: PathDisplay.fileName(p, withoutExtension: true),
            groupKey: '__single_files__',
            groupTitle: i18n.tr('imported_files'),
            groupSubtitle: i18n.tr('manually_selected_files'),
            isSingle: true,
            isVideo: isVideoMediaFile(p),
            scannedAt: DateTime.now(),
            fileSizeBytes: fileStat?.size,
            modifiedAt: fileStat?.modified,
          ),
        );
      }

      final beforeCount = provider.library.length;
      provider.addTracks(candidates, notify: false);
      final added = provider.library.length - beforeCount;
      showSnack(i18n.tr('import_done_added', {'count': added}));
    } finally {
      await provider.endLibraryBatch();
      provider.finishScan(generation);
    }
  }
}

Map<String, Object?> _scanFileSystemFolderPayload(String folderPath) {
  final folder = Directory(folderPath);
  final normalizedRoot = path.normalize(folderPath);
  if (!folder.existsSync()) {
    return const <String, Object?>{
      'tracks': <Object?>[],
      'folderPaths': <Object?>[],
      'discoveredPaths': <String>{},
      'failureCount': 1,
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
      } catch (_) {
        // File timestamps are optional scan metadata.
      }

      final parentFolder = path.dirname(absolutePath);

      final relative = PathMatcher.relativeWithin(absolutePath, normalizedRoot);
      String groupKey = parentFolder;
      String groupTitle = path.basename(parentFolder);
      String groupSubtitle = parentFolder;

      if (relative != null) {
        final relativeDir = path.dirname(relative).replaceAll('\\', '/');
        if (relativeDir == '.' || relativeDir.isEmpty) {
          groupKey = normalizedRoot;
          groupTitle = path.basename(normalizedRoot);
          groupSubtitle = normalizedRoot;
        } else {
          final topLevel = relativeDir.split('/').first;
          groupKey = path.join(normalizedRoot, topLevel);
          groupTitle = topLevel;
          groupSubtitle = groupKey;
        }
      } else {
        final folderName = path.basename(parentFolder);
        groupTitle = folderName.isEmpty ? parentFolder : folderName;
      }

      tracks.add(<String, Object?>{
        'path': absolutePath,
        'displayName': path.basenameWithoutExtension(absolutePath),
        'groupKey': groupKey,
        'groupTitle': groupTitle,
        'groupSubtitle': groupSubtitle,
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

@visibleForTesting
Map<String, Object?> scanFileSystemFolderPayloadForTest(String folderPath) {
  return _scanFileSystemFolderPayload(folderPath);
}
