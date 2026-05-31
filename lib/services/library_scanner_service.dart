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
import 'platform_channels.dart';
import 'media_file_support.dart';
import 'library_scanner_isolate.dart';

class PickedAudioFile {
  const PickedAudioFile({required this.uri, required this.name});
  final String uri;
  final String name;
}

class ScannedTrack {
  const ScannedTrack({
    required this.path,
    required this.groupKey,
    required this.groupTitle,
    required this.groupSubtitle,
    required this.isSingle,
    required this.isVideo,
    this.displayName,
    this.scannedAt,
    this.fileSizeBytes,
    this.modifiedAt,
  });

  final String path;
  final String groupKey;
  final String groupTitle;
  final String groupSubtitle;
  final bool isSingle;
  final bool isVideo;
  final String? displayName;
  final DateTime? scannedAt;
  final int? fileSizeBytes;
  final DateTime? modifiedAt;

  factory ScannedTrack.fromPayload(Map<Object?, Object?> payload) {
    final scannedAtMs = payload['scannedAtMs'] as num?;
    final modifiedAtMs = payload['modifiedAtMs'] as num?;
    return ScannedTrack(
      path: payload['path']?.toString() ?? '',
      displayName: payload['displayName']?.toString(),
      groupKey: payload['groupKey']?.toString() ?? '',
      groupTitle: payload['groupTitle']?.toString() ?? '',
      groupSubtitle: payload['groupSubtitle']?.toString() ?? '',
      isSingle: payload['isSingle'] as bool? ?? false,
      isVideo: payload['isVideo'] as bool? ?? false,
      scannedAt: scannedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(scannedAtMs.toInt()),
      fileSizeBytes: (payload['fileSizeBytes'] as num?)?.toInt(),
      modifiedAt: modifiedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(modifiedAtMs.toInt()),
    );
  }
}

class NativeScanResult {
  const NativeScanResult._({
    required this.ok,
    this.tracks = const <ScannedTrack>[],
    this.paths = const <String>{},
    this.errorCode,
    this.errorMessage,
    this.notSupported = false,
  });

  const NativeScanResult.success(List<ScannedTrack> tracks, Set<String> paths)
    : this._(ok: true, tracks: tracks, paths: paths);

  const NativeScanResult.failed({String? code, String? message})
    : this._(ok: false, errorCode: code, errorMessage: message);

  const NativeScanResult.notSupported() : this._(ok: false, notSupported: true);

  final bool ok;
  final List<ScannedTrack> tracks;
  final Set<String> paths;
  final String? errorCode;
  final String? errorMessage;
  final bool notSupported;
}

class NativeScanPayload {
  const NativeScanPayload({required this.tracks, required this.paths});
  final List<ScannedTrack> tracks;
  final Set<String> paths;
}

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

class LibraryRefreshChunk {
  const LibraryRefreshChunk({
    required this.sourceFolderPath,
    required this.libraryRoot,
    this.tracks = const <MusicTrack>[],
    this.folderPaths = const <String>[],
    this.removeWatchedFolders = const <String>[],
    this.addWatchedFolders = const <String>[],
    this.removeTrackPaths = const <String>[],
    this.removeEntryPaths = const <String>[],
    this.progressLabel = '',
    this.duplicateCount = 0,
    this.failureCount = 0,
  });

  final String sourceFolderPath;
  final String libraryRoot;
  final List<MusicTrack> tracks;
  final List<String> folderPaths;
  final List<String> removeWatchedFolders;
  final List<String> addWatchedFolders;
  final List<String> removeTrackPaths;
  final List<String> removeEntryPaths;
  final String progressLabel;
  final int duplicateCount;
  final int failureCount;
}

class LibraryRefreshFolderResult {
  const LibraryRefreshFolderResult({
    required this.sourceFolderPath,
    required this.libraryRoot,
    this.chunks = const <LibraryRefreshChunk>[],
    this.addedCount = 0,
    this.duplicateCount = 0,
    this.failureCount = 0,
  });

  final String sourceFolderPath;
  final String libraryRoot;
  final List<LibraryRefreshChunk> chunks;
  final int addedCount;
  final int duplicateCount;
  final int failureCount;
}

class LibraryScannerService {
  LibraryScannerService();

  static const MethodChannel _fileCacheChannel = MethodChannel(
    FileCacheChannel.name,
  );

  static const Duration _foregroundRefreshCommitInterval = Duration(
    milliseconds: 400,
  );

  DateTime? _lastBatchFlushTime;

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

    provider.setScanning(true, background: true, notify: false);
    var totalAdded = 0;
    var chunkDuplicateCount = 0;
    var chunkFailureCount = 0;
    var chunkIndex = 0;
    var batchOpen = true;
    var batchStarted = false;

    Future<void> applyFolderResult(LibraryRefreshFolderResult result) async {
      if (!provider.isScanning || !batchOpen || result.chunks.isEmpty) {
        return;
      }
      if (!batchStarted) {
        provider.beginStagedLibraryRefresh();
        batchStarted = true;
      }
      for (final chunk in result.chunks) {
        if (!provider.isScanning || !batchOpen) break;
        totalAdded += provider.applyStagedLibraryRefreshChunk(
          sourceFolderPath: chunk.sourceFolderPath,
          libraryRoot: chunk.libraryRoot,
          tracks: chunk.tracks,
          folderPaths: chunk.folderPaths,
          removeWatchedFolders: chunk.removeWatchedFolders,
          addWatchedFolders: chunk.addWatchedFolders,
          removeTrackPaths: chunk.removeTrackPaths,
          removeEntryPaths: chunk.removeEntryPaths,
        );
        for (final childFolder in chunk.addWatchedFolders) {
          unawaited(_prefillRjDetailForFolder(provider, childFolder));
        }
        chunkDuplicateCount += chunk.duplicateCount;
        chunkFailureCount += chunk.failureCount;
        chunkIndex++;
        provider.setScanProgress(
          currentFolder: chunk.progressLabel,
          foundCount: totalAdded,
          duplicateCount: chunkDuplicateCount,
          failureCount: chunkFailureCount,
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
          if (!provider.isScanning || !batchOpen) break;
          foldersToRefresh.removeWhere(
            (folderPath) =>
                PathMatcher.isWithinOrEqual(folderPath, libraryRoot),
          );
          await applyFolderResult(
            await _scanLibraryRootForRefresh(
              libraryRoot: libraryRoot,
              provider: provider,
              i18n: i18n,
            ),
          );
        }

        final totalFolders = foldersToRefresh.length;
        var processedFolders = 0;
        for (final folderPath in foldersToRefresh) {
          if (!provider.isScanning || !batchOpen) break;
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
            ),
          );
        }
      } finally {
        if (batchStarted && batchOpen) {
          await provider.finishStagedLibraryRefresh();
        }
      }
    } finally {
      provider.setScanning(false, notify: false);

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
  }) async {
    final childFolders = await _listImmediateChildFolders(libraryRoot);
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
      progressPrefix: '',
    );
  }

  Future<LibraryRefreshFolderResult> _scanWatchedFolderForRefresh({
    required String folderPath,
    required String effectiveLibraryRoot,
    required AudioProvider provider,
    required AppLanguageProvider i18n,
    required String progressPrefix,
  }) {
    return _scanFolderForRefresh(
      sourceFolderPath: folderPath,
      libraryRoot: effectiveLibraryRoot,
      provider: provider,
      i18n: i18n,
      progressPrefix: progressPrefix,
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
    required String progressPrefix,
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
        progressPrefix: progressPrefix,
      );
    }

    if (nativeScan.notSupported ||
        !PathMatcher.isContentUri(sourceFolderPath)) {
      final payload = await Isolate.run(
        () => _scanFileSystemFolderPayload(sourceFolderPath),
      );
      if (!provider.isScanning) {
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
      final discoveredPaths = _stringSetFromPayload(payload['discoveredPaths']);
      final discoveredFolders =
          ((payload['folderPaths'] as List<Object?>?) ?? const <Object?>[])
              .whereType<String>()
              .toList(growable: false);
      final allFolderPaths = LinkedHashSet<String>.from(folderPaths)
        ..addAll(discoveredFolders);
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
        failureCount: (payload['failureCount'] as int?) ?? 0,
        progressPrefix: progressPrefix,
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
          failureCount: 1,
        ),
      ],
      failureCount: 1,
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
    required String progressPrefix,
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
      retainedTrackPaths: retainedTrackPaths,
      retainedEntryPaths: retainedEntryPaths,
      entrySnapshot: mergeContext.entrySnapshot,
    );
    final result = await Isolate.run(
      () => processScannedTracksInIsolate(payload),
    );
    if (!provider.isScanning) {
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
    final chunks = _buildRefreshChunks(
      sourceFolderPath: sourceFolderPath,
      libraryRoot: libraryRoot,
      tracks: result.trackBatch,
      folderPaths: folderPaths,
      removeWatchedFolders: removeWatchedFolders,
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

  List<LibraryRefreshChunk> _buildRefreshChunks({
    required String sourceFolderPath,
    required String libraryRoot,
    required List<MusicTrack> tracks,
    required List<String> folderPaths,
    required List<String> removeWatchedFolders,
    required List<String> addWatchedFolders,
    required List<String> removeTrackPaths,
    required List<String> removeEntryPaths,
    required int duplicateCount,
    required int failureCount,
    required String progressPrefix,
  }) {
    const chunkSize = 120;
    final sourceLabel = _displaySourceName(sourceFolderPath);
    final chunks = <LibraryRefreshChunk>[];
    if (tracks.isEmpty) {
      final label = [
        if (progressPrefix.isNotEmpty) progressPrefix,
        sourceLabel,
      ].join(' ');
      return <LibraryRefreshChunk>[
        LibraryRefreshChunk(
          sourceFolderPath: sourceFolderPath,
          libraryRoot: libraryRoot,
          folderPaths: folderPaths,
          removeWatchedFolders: removeWatchedFolders,
          addWatchedFolders: addWatchedFolders,
          removeTrackPaths: removeTrackPaths,
          removeEntryPaths: removeEntryPaths,
          progressLabel: label,
          duplicateCount: duplicateCount,
          failureCount: failureCount,
        ),
      ];
    }

    for (var i = 0; i < tracks.length; i += chunkSize) {
      final end = (i + chunkSize < tracks.length)
          ? i + chunkSize
          : tracks.length;
      final isLast = end == tracks.length;
      final label = [
        if (progressPrefix.isNotEmpty) progressPrefix,
        '[$end/${tracks.length}]',
        sourceLabel,
      ].join(' ');
      chunks.add(
        LibraryRefreshChunk(
          sourceFolderPath: sourceFolderPath,
          libraryRoot: libraryRoot,
          tracks: tracks.sublist(i, end),
          folderPaths: isLast ? folderPaths : const <String>[],
          removeWatchedFolders: isLast
              ? removeWatchedFolders
              : const <String>[],
          addWatchedFolders: isLast ? addWatchedFolders : const <String>[],
          removeTrackPaths: isLast ? removeTrackPaths : const <String>[],
          removeEntryPaths: isLast ? removeEntryPaths : const <String>[],
          progressLabel: label,
          duplicateCount: isLast ? duplicateCount : 0,
          failureCount: isLast ? failureCount : 0,
        ),
      );
    }
    return chunks;
  }

  Future<int> _mergeScannedTracksIncrementally({
    required String sourceFolderPath,
    required AudioProvider provider,
    required List<ScannedTrack> scannedTracks,
    required String? libraryRoot,
    bool promoteRootTracksToSingles = false,
    AppLanguageProvider? i18n,
    Future<bool> Function()? onChunkCommitted,
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

    final result = await Isolate.run(
      () => processScannedTracksInIsolate(payload),
    );

    if (!provider.isScanning) return 0;

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
        if (!provider.isScanning) break;
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
    if (!provider.isScanning) return 0;

    final scannedTracks =
        ((payload['tracks'] as List<Object?>?) ?? const <Object?>[])
            .whereType<Map<Object?, Object?>>()
            .map(ScannedTrack.fromPayload)
            .toList(growable: false);
    final discoveredPaths = _stringSetFromPayload(payload['discoveredPaths']);
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

    final result = await Isolate.run(
      () => processScannedTracksInIsolate(isolatePayload),
    );

    if (!provider.isScanning) return 0;

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
        if (!provider.isScanning) break;
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
      );
    }

    if (provider.isScanning) {
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

  Future<NativeScanResult> _scanFolderViaNative(String folderPath) async {
    if (!Platform.isAndroid) {
      return const NativeScanResult.notSupported();
    }
    try {
      final data = await _fileCacheChannel.invokeMethod<List<dynamic>>(
        'scanFolder',
        {'folder': folderPath},
      );
      if (data == null) {
        return const NativeScanResult.failed(
          code: 'scan_empty_response',
          message: 'Native scan returned null data.',
        );
      }

      final payload = await Isolate.run(() => _parseNativeScanPayload(data));
      return NativeScanResult.success(payload.tracks, payload.paths);
    } on PlatformException catch (error) {
      return NativeScanResult.failed(code: error.code, message: error.message);
    } catch (error) {
      return NativeScanResult.failed(
        code: 'scan_unknown_error',
        message: error.toString(),
      );
    }
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

  Future<List<String>> _listImmediateChildFolders(String folderPath) async {
    if (Platform.isAndroid) {
      try {
        final data = await _fileCacheChannel.invokeMethod<List<dynamic>>(
          'listChildFolders',
          {'folder': folderPath},
        );
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
    } catch (_) {}
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
    final raw = await _fileCacheChannel.invokeMapMethod<String, Object?>(
      FileCacheMethod.pickAudioFolder,
    );
    final pathValue = raw?['path']?.toString().trim();
    if (pathValue == null || pathValue.isEmpty) {
      return null;
    }
    return pathValue;
  }

  Future<List<PickedAudioFile>?> _pickAudioFilesViaNative() async {
    final raw = await _fileCacheChannel.invokeMapMethod<String, Object?>(
      FileCacheMethod.pickAudioFiles,
    );
    final items = raw?['files'];
    if (items is! List) {
      return null;
    }
    final files = <PickedAudioFile>[];
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
        PickedAudioFile(
          uri: uri,
          name: name == null || name.isEmpty
              ? PathDisplay.fileName(uri, withoutExtension: true)
              : name,
        ),
      );
    }
    return files;
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
      } catch (_) {}
    }

    if (Platform.isAndroid &&
        identifier != null &&
        identifier.startsWith('content://')) {
      try {
        return await _fileCacheChannel.invokeMethod<String>('cacheFromUri', {
          'uri': identifier,
          'name': file.name,
          'index': index,
        });
      } catch (_) {}
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

    provider.setScanning(true);
    provider.beginLibraryBatch();

    var added = 0;

    try {
      provider.setScanProgress(currentFolder: _displaySourceName(folderPath));
      final nativeScan = await _scanFolderViaNative(folderPath);
      if (nativeScan.ok) {
        added = await _mergeScannedTracksIncrementally(
          sourceFolderPath: folderPath,
          provider: provider,
          scannedTracks: nativeScan.tracks,
          libraryRoot: normalizedFolderPath,
          onChunkCommitted: () => _flushRefreshBatch(provider),
        );
      } else if (nativeScan.notSupported ||
          !PathMatcher.isContentUri(folderPath)) {
        added = await _importFolderIncrementally(
          folderPath,
          provider,
          normalizedFolderPath,
          onChunkCommitted: () => _flushRefreshBatch(provider),
        );
      } else {
        provider.setScanProgress(failureCount: provider.scanFailureCount + 1);
        debugPrint(
          '[library-import] native scan failed for content uri: $folderPath '
          'code=${nativeScan.errorCode} message=${nativeScan.errorMessage}',
        );
      }
    } finally {
      await provider.endLibraryBatch();
      provider.addWatchedFolder(normalizedFolderPath, notify: false);
      provider.recordLibraryEntriesForTracks(
        normalizedFolderPath,
        const <MusicTrack>[],
      );
      await _prefillRjDetailForFolder(provider, normalizedFolderPath);
      provider.setScanning(false);

      showSnack(i18n.tr('import_done_added', {'count': added}));
    }
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
    final childFolders = await _listImmediateChildFolders(normalizedFolderPath);
    final importTargets = childFolders;

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
    for (final folderPath in promotedFolders) {
      provider.removeWatchedFolder(folderPath, notify: false);
    }

    provider.addWatchedLibrary(normalizedFolderPath, notify: false);
    provider.recordLibraryEntriesForTracks(
      normalizedFolderPath,
      const <MusicTrack>[],
      folderPaths: childFolders,
    );
    provider.setScanning(true);
    provider.beginLibraryBatch();
    var added = 0;
    try {
      added = await _importLibraryWithSingleScan(
        normalizedFolderPath,
        provider,
        i18n,
        onChunkCommitted: () => _flushRefreshBatch(provider),
      );
      for (final childFolder in importTargets) {
        if (provider.isLibraryPathExcluded(normalizedFolderPath, childFolder)) {
          continue;
        }
        provider.addWatchedFolder(childFolder, notify: false);
        await _prefillRjDetailForFolder(provider, childFolder);
      }
    } finally {
      await provider.endLibraryBatch();
      provider.setScanning(false);

      showSnack(
        i18n.tr('import_library_done', {
          'count': added,
          'folderCount': importTargets.length,
        }),
      );
    }
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

        provider.setScanning(true);
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
          provider.setScanning(false);
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

    provider.setScanning(true);
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
        } catch (_) {}
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
      provider.setScanning(false);
    }
  }
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

NativeScanPayload _parseNativeScanPayload(List<dynamic> data) {
  final scanned = <ScannedTrack>[];
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
      ScannedTrack(
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
  return NativeScanPayload(
    tracks: List<ScannedTrack>.unmodifiable(scanned),
    paths: Set<String>.unmodifiable(paths),
  );
}

Set<String> _checkExistingPaths(List<String> paths) {
  final existing = <String>{};
  for (final p in paths) {
    if (File(p).existsSync()) existing.add(p);
  }
  return existing;
}
