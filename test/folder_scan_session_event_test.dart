import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/library_scan_data_source.dart';
import 'package:doujin_audio/features/library/application/library_scanner_isolate.dart';
import 'package:doujin_audio/features/library/application/library_scanner_service.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';

void main() {
  test('parses Android folder scan chunk events', () {
    final event = FolderScanSessionEvent.fromPayload(<Object?, Object?>{
      'taskId': 'scan-1',
      'generationId': 'generation-1',
      'eventType': 'chunk',
      'tracks': <Object?>[
        <Object?, Object?>{
          'path': '/music/work/01.mp3',
          'title': '01',
          'groupKey': '/music/work',
          'groupTitle': 'work',
          'groupSubtitle': '/music/work',
          'isVideo': false,
          'scannedAtMs': 1000,
          'fileSizeBytes': 42,
          'modifiedAtMs': 2000,
        },
      ],
      'paths': <Object?>['/music/work/01.mp3'],
      'folders': <Object?>['/music/work'],
      'failureCount': 2,
    });

    expect(event.taskId, 'scan-1');
    expect(event.isChunk, isTrue);
    expect(event.chunk.tracks, hasLength(1));
    expect(event.chunk.tracks.single.displayName, '01');
    expect(
      event.chunk.paths,
      contains(PathMatcher.normalize('/music/work/01.mp3')),
    );
    expect(event.chunk.folders, contains(PathMatcher.normalize('/music/work')));
    expect(event.chunk.failureCount, 2);
  });

  test('parses Android folder scan error events', () {
    final event = FolderScanSessionEvent.fromPayload(<Object?, Object?>{
      'taskId': 'scan-2',
      'generationId': 'generation-2',
      'eventType': 'failed',
      'errorCode': 'scan_provider_error',
      'error': 'provider failed',
      'failureCount': 1,
    });

    expect(event.isError, isTrue);
    expect(event.errorCode, 'scan_provider_error');
    expect(event.errorMessage, 'provider failed');
    expect(event.chunk.failureCount, 1);
  });

  test('parses staged scan progress with a nullable total', () {
    final known = FolderScanSessionEvent.fromPayload(<Object?, Object?>{
      'taskId': 'scan-3',
      'generationId': 'scan-3',
      'eventType': 'progress',
      'stage': 'enumerating',
      'processed': 120,
      'total': 500,
    });
    final unknown = FolderScanSessionEvent.fromPayload(<Object?, Object?>{
      'taskId': 'scan-3',
      'generationId': 'scan-3',
      'eventType': 'stageChanged',
      'stage': 'preparing',
      'processed': 0,
    });

    expect(known.isProgress, isTrue);
    expect(known.generationId, 'scan-3');
    expect(known.stage, FolderScanStage.enumerating);
    expect(known.processed, 120);
    expect(known.total, 500);
    expect(unknown.isStageChanged, isTrue);
    expect(unknown.total, isNull);
  });

  test('recognizes explicit completed cancelled and failed terminals', () {
    FolderScanSessionEvent event(String type) =>
        FolderScanSessionEvent.fromPayload(<Object?, Object?>{
          'taskId': 'scan-terminal',
          'generationId': 'generation-terminal',
          'eventType': type,
        });

    expect(event('completed').isDone, isTrue);
    expect(event('cancelled').isCancelled, isTrue);
    expect(event('failed').isError, isTrue);
  });

  test('scan results are complete only when enumeration is proven clean', () {
    final complete = NativeScanResult.success(
      <ScannedTrack>[],
      <String>{},
      completenessKnown: true,
    );
    final partial = NativeScanResult.success(
      <ScannedTrack>[],
      <String>{},
      failureCount: 1,
      completenessKnown: true,
    );
    final legacy = NativeScanResult.success(<ScannedTrack>[], <String>{});

    expect(complete.isComplete, isTrue);
    expect(partial.isComplete, isFalse);
    expect(legacy.isComplete, isFalse);
  });

  test('partial refresh never generates removal paths', () {
    final existing = MusicTrack(
      path: '/music/work/missing.mp3',
      displayName: 'missing',
      groupKey: '/music/work',
      groupTitle: 'work',
      groupSubtitle: '/music/work',
      isSingle: false,
    );

    final partial = processScannedTracksInIsolate(
      ScanMergeIsolatePayload(
        scannedTracks: <ScannedTrack>[],
        library: <MusicTrack>[existing],
        libraryRoot: '/music',
        promoteRootTracksToSingles: false,
        i18nImportedFiles: 'Imported',
        i18nManuallySelectedFiles: 'Selected',
        exclusionMatcher: null,
        sourceFolderPath: '/music/work',
        retainedTrackPaths: <String>{'/music/work/found.mp3'},
      ),
    );
    final complete = processScannedTracksInIsolate(
      ScanMergeIsolatePayload(
        scannedTracks: <ScannedTrack>[],
        library: <MusicTrack>[existing],
        libraryRoot: '/music',
        promoteRootTracksToSingles: false,
        i18nImportedFiles: 'Imported',
        i18nManuallySelectedFiles: 'Selected',
        exclusionMatcher: null,
        sourceFolderPath: '/music/work',
        retainedTrackPaths: <String>{'/music/work/found.mp3'},
        allowRemoval: true,
      ),
    );

    expect(partial.removedTrackPaths, isEmpty);
    expect(complete.removedTrackPaths, <String>['/music/work/missing.mp3']);
  });

  test('a missing filesystem root is reported as an incomplete scan', () {
    final missingPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'missing_scan_${DateTime.now().microsecondsSinceEpoch}';

    final payload = scanFileSystemFolderPayloadForTest(missingPath);

    expect(payload['failureCount'], 1);
    expect(payload['discoveredPaths'], isEmpty);
  });

  test('desktop filesystem scans stream bounded chunks', () async {
    final root = await Directory.systemTemp.createTemp(
      'doujin_audio_chunked_scan_',
    );
    try {
      for (var index = 0; index < 250; index++) {
        await File(
          '${root.path}${Platform.pathSeparator}track_$index.mp3',
        ).writeAsBytes(const <int>[]);
      }
      final chunkSizes = <int>[];
      var scannedTrackCount = 0;
      final dataSource = PlatformLibraryScanDataSource(isAndroid: () => false);

      final result = await dataSource.scanFileSystemFolderChunked(root.path, (
        chunk,
      ) {
        chunkSizes.add(chunk.tracks.length);
        scannedTrackCount += chunk.tracks.length;
        return true;
      });

      expect(chunkSizes, isNotEmpty);
      expect(chunkSizes.every((size) => size <= 120), isTrue);
      expect(scannedTrackCount, 250);
      expect(result.tracks, isEmpty);
      expect(result.paths, hasLength(250));
      expect(result.isComplete, isTrue);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
