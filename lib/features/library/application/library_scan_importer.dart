import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/media/music_track.dart';
import '../../../core/logging/app_log_service.dart';
import 'library_catalog.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/path_display.dart';
import 'library_scan_data_source.dart';
import 'library_scan_models.dart';
import 'library_scanner_isolate.dart';

class LibraryIncrementalNativeImport {
  const LibraryIncrementalNativeImport({
    required this.added,
    required this.result,
  });

  final int added;
  final NativeScanResult result;
}

class LibraryFolderImportOutcome {
  const LibraryFolderImportOutcome({
    required this.added,
    required this.complete,
  });

  final int added;
  final bool complete;
}

class LibraryScanImporter {
  LibraryScanImporter({required LibraryScanDataSource dataSource})
    : _dataSource = dataSource;
  final LibraryScanDataSource _dataSource;
  Future<int> mergeScannedTracks({
    required String sourceFolderPath,
    required LibraryCatalog provider,
    required List<ScannedTrack> scannedTracks,
    required String? libraryRoot,
    bool promoteRootTracksToSingles = false,
    required LibraryScanLabels labels,
    Future<bool> Function()? onChunkCommitted,
    int? generation,
    LibraryScanMergeContext? mergeContext,
  }) async {
    bool isActive() => generation == null
        ? provider.isScanning
        : provider.isScanGenerationActive(generation);
    if (scannedTracks.isEmpty || !isActive()) return 0;

    final baseFoundCount = provider.scanFoundCount;
    final baseDuplicateCount = provider.scanDuplicateCount;
    final baseFailureCount = provider.scanFailureCount;
    final context =
        mergeContext ??
        (libraryRoot == null
            ? null
            : LibraryScanMergeContext(
                provider: provider,
                libraryRoot: libraryRoot,
              ));
    final sourceName = _displaySourceName(sourceFolderPath);
    var added = 0;
    var duplicates = 0;

    // Bound both the isolate message and the catalog work on the UI isolate.
    const chunkSize = 120;
    for (var start = 0; start < scannedTracks.length; start += chunkSize) {
      if (!isActive()) break;
      final end = (start + chunkSize).clamp(0, scannedTracks.length);
      final scannedChunk = scannedTracks.sublist(start, end);
      final existingTracks = <MusicTrack>[];
      final existingPaths = <String>{};
      for (final scannedTrack in scannedChunk) {
        final existing = provider.trackByPath(scannedTrack.path);
        if (existing != null &&
            existingPaths.add(PathMatcher.equivalenceKey(existing.path))) {
          existingTracks.add(existing);
        }
      }
      final result = await compute(
        processScannedTracksInIsolate,
        ScanMergeIsolatePayload(
          scannedTracks: scannedChunk,
          library: existingTracks,
          libraryRoot: libraryRoot,
          promoteRootTracksToSingles: promoteRootTracksToSingles,
          i18nImportedFiles: labels.importedFiles,
          i18nManuallySelectedFiles: labels.manuallySelectedFiles,
          exclusionMatcher: context?.exclusionMatcher,
        ),
      );
      if (!isActive()) break;

      if (libraryRoot != null && result.entryBatch.isNotEmpty) {
        provider.recordLibraryEntriesForTracks(
          libraryRoot,
          result.entryBatch,
          exclusionMatcher: context?.exclusionMatcher,
          entrySnapshot: context?.entrySnapshot,
        );
      }
      if (result.trackBatch.isNotEmpty) {
        final beforeCount = provider.library.length;
        provider.addOrReplaceTracks(result.trackBatch, notify: false);
        added += provider.library.length - beforeCount;
      }
      duplicates += result.duplicatesCount;
      provider.setScanProgress(
        currentFolder: '[$end/${scannedTracks.length}] $sourceName',
        foundCount: baseFoundCount + added,
        duplicateCount: baseDuplicateCount + duplicates,
        failureCount: baseFailureCount,
        generation: generation,
        stage: FolderScanStage.merging,
      );
      // Even immediately completed callbacks only drain microtasks. Yield an
      // event turn so input, frames, and cancellation can run between chunks.
      await Future<void>.delayed(Duration.zero);
      if (!isActive()) break;
      if (onChunkCommitted != null && !await onChunkCommitted()) break;
    }
    return added;
  }

  Future<int> importFolder(
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
        added += await mergeScannedTracks(
          sourceFolderPath: folderPath,
          provider: provider,
          scannedTracks: chunk.tracks,
          libraryRoot: libraryRoot,
          promoteRootTracksToSingles: promoteRootTracksToSingles,
          labels: labels,
          onChunkCommitted: onChunkCommitted,
          generation: generation,
          mergeContext: mergeContext,
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

  Future<LibraryIncrementalNativeImport?> importNativeFolder({
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
    final mergeContext = libraryRoot == null
        ? null
        : LibraryScanMergeContext(provider: provider, libraryRoot: libraryRoot);
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
        added += await mergeScannedTracks(
          sourceFolderPath: sourceFolderPath,
          provider: provider,
          scannedTracks: chunk.tracks,
          libraryRoot: libraryRoot,
          promoteRootTracksToSingles: promoteRootTracksToSingles,
          labels: labels,
          onChunkCommitted: onChunkCommitted,
          generation: generation,
          mergeContext: mergeContext,
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
      return LibraryIncrementalNativeImport(added: 0, result: result);
    }
    if (!provider.isScanGenerationActive(generation)) {
      return LibraryIncrementalNativeImport(added: added, result: result);
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
    return LibraryIncrementalNativeImport(added: added, result: result);
  }

  Future<LibraryFolderImportOutcome> importLibrary(
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
    final chunkedAdded = await importNativeFolder(
      sourceFolderPath: libraryRoot,
      provider: provider,
      libraryRoot: libraryRoot,
      promoteRootTracksToSingles: true,
      labels: labels,
      onChunkCommitted: onChunkCommitted,
      generation: generation,
    );
    if (chunkedAdded != null) {
      return LibraryFolderImportOutcome(
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
        final added = await importFolder(
          libraryRoot,
          provider,
          libraryRoot,
          promoteRootTracksToSingles: true,
          labels: labels,
          onChunkCommitted: onChunkCommitted,
          generation: generation,
        );
        return LibraryFolderImportOutcome(
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
      return const LibraryFolderImportOutcome(added: 0, complete: false);
    }

    final added = await mergeScannedTracks(
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
    if (provider.isScanGenerationActive(generation) && nativeScan.isComplete) {
      provider.removeTracksDeletedFromFolder(libraryRoot, scannedPaths);
      provider.removeLibraryEntriesDeletedFromFolder(
        libraryRoot,
        libraryRoot,
        scannedPaths,
      );
    }
    return LibraryFolderImportOutcome(
      added: added,
      complete:
          provider.isScanGenerationActive(generation) && nativeScan.isComplete,
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
}
