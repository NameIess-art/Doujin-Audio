import 'dart:async';
import 'dart:io';

import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/features/library/application/library_catalog.dart';
import 'package:doujin_audio/features/library/application/library_scan_data_source.dart';
import 'package:doujin_audio/features/library/application/library_scan_importer.dart';
import 'package:doujin_audio/features/library/application/library_scan_models.dart';
import 'package:doujin_audio/features/library/application/library_state_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _labels = LibraryScanLabels(
  chooseMusicFolder: 'Folder',
  chooseLibraryFolder: 'Library',
  chooseAudioFiles: 'Files',
  importedFiles: 'Imported',
  manuallySelectedFiles: 'Selected',
);

ScannedTrack _track(int index) => ScannedTrack(
  path: 'C:/music/$index.mp3',
  groupKey: 'C:/music',
  groupTitle: 'Music',
  groupSubtitle: '',
  isSingle: false,
  isVideo: false,
);

void main() {
  test('large import bounds entry writes and yields to cancellation', () async {
    final catalog = _Catalog();
    catalog.onTracksAdded = () => Timer.run(() => catalog.isScanning = false);
    final added = await LibraryScanImporter(dataSource: _Source())
        .mergeScannedTracks(
          sourceFolderPath: 'C:/music',
          provider: catalog,
          scannedTracks: List.generate(1000, _track),
          libraryRoot: 'C:/music',
          labels: _labels,
          generation: 1,
          onChunkCommitted: () async => true,
        );
    expect(added, 120);
    expect(catalog.entryBatchSizes, [120]);
    expect(catalog.library, hasLength(120));
  });

  test('native chunks reuse the same entry snapshot', () async {
    final catalog = _Catalog();
    final source = _Source(
      chunks: [
        [_track(1)],
        [_track(2)],
        [_track(3)],
      ],
    );
    final result = await LibraryScanImporter(dataSource: source)
        .importNativeFolder(
          sourceFolderPath: 'C:/music',
          provider: catalog,
          libraryRoot: 'C:/music',
          labels: _labels,
          generation: 1,
        );
    expect(result!.added, 3);
    expect(catalog.sourceLabels, ['music', 'music', 'music']);
    expect(catalog.foundCounts, [1, 2, 3]);
    expect(catalog.snapshotReads, 1);
    expect(
      catalog.entrySnapshots.every(
        (value) => identical(value, catalog.entrySnapshots.first),
      ),
      isTrue,
    );
  });

  test(
    'legacy native completion cannot delete entries after cancellation',
    () async {
      final catalog = _Catalog();
      final importer = LibraryScanImporter(
        dataSource: _Source(legacyTracks: [_track(1)]),
      );
      final result = await importer.importLibrary(
        'C:/music',
        catalog,
        _labels,
        generation: 1,
        onChunkCommitted: () async {
          catalog.isScanning = false;
          return false;
        },
      );
      expect(result.complete, isFalse);
      expect(catalog.cleanupCalls, 0);
    },
  );

  test(
    'filesystem worker waits for a committed chunk before reading metadata',
    () async {
      final root = await Directory.systemTemp.createTemp('scan_backpressure_');
      try {
        final files = <File>[];
        for (var index = 0; index < 250; index++) {
          files.add(await File('${root.path}/$index.mp3').writeAsString('a'));
        }
        final seen = <String>{};
        var chunks = 0;
        final result =
            await PlatformLibraryScanDataSource(
              isAndroid: () => false,
            ).scanFileSystemFolderChunked(root.path, (chunk) async {
              chunks++;
              if (chunks == 1) {
                expect(chunk.tracks, hasLength(120));
                expect(
                  chunk.tracks.every((track) => track.fileSizeBytes == 1),
                  isTrue,
                );
                seen.addAll(
                  chunk.tracks.map(
                    (track) => PathMatcher.equivalenceKey(track.path),
                  ),
                );
                // Leave the worker enough time to run ahead if no ACK is required.
                await Future<void>.delayed(const Duration(milliseconds: 20));
                for (final file in files) {
                  if (!seen.contains(PathMatcher.equivalenceKey(file.path))) {
                    await file.writeAsString('updated');
                  }
                }
              } else {
                expect(
                  chunk.tracks.every((track) => track.fileSizeBytes == 7),
                  isTrue,
                );
              }
              return true;
            });
        expect(result.isComplete, isTrue);
        expect(result.paths, hasLength(250));
        expect(chunks, 3);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'filesystem cancellation stops at the current chunk and skips cleanup',
    () async {
      final root = await Directory.systemTemp.createTemp('scan_cancel_');
      try {
        for (var index = 0; index < 130; index++) {
          await File('${root.path}/$index.mp3').writeAsString('a');
        }
        var callbacks = 0;
        final result =
            await PlatformLibraryScanDataSource(
              isAndroid: () => false,
            ).scanFileSystemFolderChunked(root.path, (chunk) async {
              callbacks++;
              return false;
            });
        expect(result.wasCancelled, isTrue);
        expect(result.isComplete, isFalse);
        expect(result.paths, hasLength(120));
        expect(callbacks, 1);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}

class _Catalog implements LibraryCatalog {
  @override
  final library = <MusicTrack>[];
  @override
  bool isScanning = true;
  @override
  int scanFoundCount = 0;
  @override
  int scanDuplicateCount = 0;
  @override
  int scanFailureCount = 0;
  final entryBatchSizes = <int>[];
  final entrySnapshots = <LibraryEntrySnapshot?>[];
  final sourceLabels = <String>[];
  final foundCounts = <int>[];
  var snapshotReads = 0;
  var cleanupCalls = 0;
  void Function()? onTracksAdded;

  @override
  bool isScanGenerationActive(int generation) => generation == 1 && isScanning;
  @override
  MusicTrack? trackByPath(String trackPath) => null;
  @override
  LibraryExclusionMatcher libraryExclusionMatcherForLibrary(
    String libraryPath,
  ) => LibraryExclusionMatcher(libraryPath: libraryPath);
  @override
  LibraryEntrySnapshot libraryEntrySnapshotForLibrary(String libraryPath) {
    snapshotReads++;
    return LibraryEntrySnapshot(libraryPath: libraryPath);
  }

  @override
  void recordLibraryEntriesForTracks(
    String libraryPath,
    List<MusicTrack> tracks, {
    Iterable<String> folderPaths = const [],
    bool persist = true,
    LibraryExclusionMatcher? exclusionMatcher,
    LibraryEntrySnapshot? entrySnapshot,
  }) {
    entryBatchSizes.add(tracks.length);
    entrySnapshots.add(entrySnapshot);
  }

  @override
  void addOrReplaceTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
    bool mergeExistingState = true,
  }) {
    library.addAll(tracks);
    onTracksAdded?.call();
  }

  @override
  void setScanProgress({
    String? currentFolder,
    int? foundCount,
    int? duplicateCount,
    int? failureCount,
    int? generation,
    FolderScanStage? stage,
    int? processed,
    int? total,
  }) {
    if (currentFolder != null) sourceLabels.add(currentFolder);
    if (foundCount != null) foundCounts.add(foundCount);
    scanFoundCount = foundCount ?? scanFoundCount;
    scanDuplicateCount = duplicateCount ?? scanDuplicateCount;
    scanFailureCount = failureCount ?? scanFailureCount;
  }

  @override
  void removeTracksDeletedFromFolder(
    String folderPath,
    Set<String> scannedPaths,
  ) {
    cleanupCalls++;
  }

  @override
  void removeLibraryEntriesDeletedFromFolder(
    String libraryPath,
    String folderPath,
    Set<String> retainedPaths,
  ) {
    cleanupCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Source implements LibraryScanDataSource {
  _Source({this.chunks, this.legacyTracks = const []});
  final List<List<ScannedTrack>>? chunks;
  final List<ScannedTrack> legacyTracks;
  @override
  Future<NativeScanResult> scanFolderChunked(
    String folderPath,
    FutureOr<bool> Function(FolderScanChunk) onChunk, {
    FutureOr<void> Function(FolderScanSessionEvent)? onProgress,
  }) async {
    if (chunks == null) return NativeScanResult.notSupported();
    final paths = <String>{};
    for (final tracks in chunks!) {
      paths.addAll(tracks.map((track) => track.path));
      if (!await onChunk(FolderScanChunk(tracks: tracks))) {
        return NativeScanResult.success(
          [],
          paths,
          completenessKnown: true,
          wasCancelled: true,
        );
      }
    }
    return NativeScanResult.success([], paths, completenessKnown: true);
  }

  @override
  Future<NativeScanResult> scanFolder(String folderPath) async =>
      NativeScanResult.success(
        legacyTracks,
        legacyTracks.map((track) => track.path).toSet(),
        completenessKnown: true,
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
