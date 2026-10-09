import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/media/music_track.dart';
import '../../../core/logging/app_log_service.dart';
import 'library_catalog.dart';
import 'library_state_models.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/path_display.dart';
import 'library_scan_data_source.dart';
import 'library_scan_models.dart';

import 'library_scanner_isolate.dart';

import '../../../core/immutable_collections.dart';

class LibraryRefreshChunk {
  LibraryRefreshChunk({
    required this.sourceFolderPath,
    required this.libraryRoot,
    List<MusicTrack> tracks = const <MusicTrack>[],
    List<MusicTrack> entryTracks = const <MusicTrack>[],
    List<String> folderPaths = const <String>[],
    List<String> removeWatchedFolders = const <String>[],
    List<String> addWatchedFolders = const <String>[],
    List<String> removeTrackPaths = const <String>[],
    List<String> removeEntryPaths = const <String>[],
    this.progressLabel = '',
    this.duplicateCount = 0,
    this.failureCount = 0,
    this.mergeContext,
  }) : tracks = immutableList(tracks),
       entryTracks = immutableList(entryTracks),
       folderPaths = immutableList(folderPaths),
       removeWatchedFolders = immutableList(removeWatchedFolders),
       addWatchedFolders = immutableList(addWatchedFolders),
       removeTrackPaths = immutableList(removeTrackPaths),
       removeEntryPaths = immutableList(removeEntryPaths);

  final String sourceFolderPath;
  final String libraryRoot;
  final List<MusicTrack> tracks;
  final List<MusicTrack> entryTracks;
  final LibraryScanMergeContext? mergeContext;
  final List<String> folderPaths;
  final List<String> removeWatchedFolders;
  final List<String> addWatchedFolders;
  final List<String> removeTrackPaths;
  final List<String> removeEntryPaths;
  final String progressLabel;
  final int duplicateCount;
  final int failureCount;
}

class LibraryRefreshChunkPlanner {
  LibraryRefreshChunkPlanner({required LibraryScanDataSource dataSource})
    : _dataSource = dataSource;
  final LibraryScanDataSource _dataSource;
  Future<void> scanLibraryRoot({
    required String libraryRoot,
    required LibraryCatalogReader provider,
    required LibraryScanLabels labels,
    required int generation,
    required Future<bool> Function(LibraryRefreshChunk chunk) onChunk,
    required void Function(FolderScanSessionEvent event) onProgress,
  }) async {
    final childFolderResult = await _dataSource.listImmediateChildFolders(
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
      onProgress: onProgress,
    );
  }

  Future<void> scanWatchedFolder({
    required String folderPath,
    required String effectiveLibraryRoot,
    required LibraryCatalogReader provider,
    required LibraryScanLabels labels,
    required String progressPrefix,
    required int generation,
    required Future<bool> Function(LibraryRefreshChunk chunk) onChunk,
    required void Function(FolderScanSessionEvent event) onProgress,
  }) async {
    await _scanFolderForRefresh(
      sourceFolderPath: folderPath,
      libraryRoot: effectiveLibraryRoot,
      provider: provider,
      labels: labels,
      progressPrefix: progressPrefix,
      generation: generation,
      onChunk: onChunk,
      onProgress: onProgress,
    );
  }

  Future<void> _scanFolderForRefresh({
    required String sourceFolderPath,
    required String libraryRoot,
    required LibraryCatalogReader provider,
    required LibraryScanLabels labels,
    bool promoteRootTracksToSingles = false,
    List<String> folderPaths = const <String>[],
    List<String> removeWatchedFolders = const <String>[],
    List<String> addWatchedFolders = const <String>[],
    int additionalFailureCount = 0,
    required String progressPrefix,
    required int generation,
    required Future<bool> Function(LibraryRefreshChunk chunk) onChunk,
    required void Function(FolderScanSessionEvent event) onProgress,
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
      retainedEntryPaths.addAll(chunk.folders.map(PathMatcher.normalize));
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
          entryTracks: result.entryBatch,
          mergeContext: mergeContext,
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
        onProgress(event);
      },
    );
    if (scanResult.notSupported) {
      if (PathMatcher.isContentUri(sourceFolderPath)) {
        final legacyScan = await _dataSource.scanFolder(sourceFolderPath);
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
        mergeContext: mergeContext,
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

  String _displaySourceName(String source) {
    if (PathMatcher.isContentUri(source)) {
      final decoded = Uri.decodeFull(source);
      final lastSegment = decoded.split('/').last;
      return lastSegment.split('%3A').last.split(':').last;
    }
    return PathDisplay.folderName(source);
  }
}
