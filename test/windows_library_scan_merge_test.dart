import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/library_scanner_isolate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'package:doujin_audio/features/library/application/library_scan_data_source.dart';
import 'package:doujin_audio/features/library/application/library_scanner_service.dart';
import 'support/app_runtime_test_fixture.dart';

class _CaseChangedScan extends Fake implements LibraryScanDataSource {
  @override
  Future<bool> ensureReadPermissionForSources(Iterable<String> sources) async =>
      true;

  @override
  Future<NativeScanResult> scanFolderChunked(
    String folderPath,
    FutureOr<bool> Function(FolderScanChunk) onChunk, {
    FutureOr<void> Function(FolderScanSessionEvent)? onProgress,
  }) async {
    const mediaPath = r'c:\music\track.mp3';
    await onChunk(
      FolderScanChunk(
        tracks: [
          const ScannedTrack(
            path: mediaPath,
            displayName: 'Updated',
            groupKey: r'c:\music',
            groupTitle: 'Music',
            groupSubtitle: '',
            isSingle: false,
            isVideo: false,
          ),
        ],
        paths: {mediaPath},
      ),
    );
    return NativeScanResult.success([], {mediaPath}, completenessKnown: true);
  }
}

void main() {
  AppRuntimeTestFixture.initialize();
  test(
    'refresh through the catalog preserves state across Windows casing changes',
    () async {
      final graph = createTestRuntimeGraph();
      addTearDown(graph.runtime.dispose);
      final existing = MusicTrack(
        path: r'C:\Music\Track.mp3',
        displayName: 'Track',
        groupKey: r'C:\Music',
        groupTitle: 'Music',
        groupSubtitle: '',
        isSingle: false,
        isFavorite: true,
        lastPlayedPosition: const Duration(seconds: 12),
      );
      graph.library.addWatchedFolder(r'C:\Music', notify: false);
      graph.library.addTracks([existing], notify: false, persist: false);
      await LibraryScannerService(
        dataSource: _CaseChangedScan(),
      ).refreshWatchedFolders(
        provider: graph.library,
        labels: const LibraryScanLabels(
          chooseMusicFolder: '',
          chooseLibraryFolder: '',
          chooseAudioFiles: '',
          importedFiles: '',
          manuallySelectedFiles: '',
        ),
      );
      expect(graph.library.library, hasLength(1));
      final refreshed = graph.library.trackByPath(r'c:/music/track.mp3')!;
      expect(refreshed.path, existing.path);
      expect(refreshed.displayName, 'Updated');
      expect(refreshed.isFavorite, isTrue);
      expect(refreshed.lastPlayedPosition, const Duration(seconds: 12));
      expect(graph.library.trackByPath(existing.path), same(refreshed));
    },
  );
  test(
    'Windows scan preserves the existing path and user state across casing changes',
    () {
      final existing = MusicTrack(
        path: r'C:\Music\声優\Track.mp3',
        displayName: 'Track',
        groupKey: r'C:\Music\声優',
        groupTitle: '声優',
        groupSubtitle: '',
        isSingle: false,
        isFavorite: true,
        lastPlayedPosition: const Duration(seconds: 12),
      );
      final result = processScannedTracksInIsolate(
        ScanMergeIsolatePayload(
          scannedTracks: [
            const ScannedTrack(
              path: r'c:\music\声優\track.mp3',
              displayName: 'Updated',
              groupKey: r'c:\music\声優',
              groupTitle: '声優',
              groupSubtitle: '',
              isSingle: false,
              isVideo: false,
            ),
          ],
          library: [existing],
          libraryRoot: null,
          promoteRootTracksToSingles: false,
          i18nImportedFiles: 'Imported',
          i18nManuallySelectedFiles: 'Selected',
          exclusionMatcher: null,
        ),
      );
      expect(result.trackBatch.single.path, existing.path);
      expect(result.trackBatch.single.isFavorite, isTrue);
      expect(
        result.trackBatch.single.lastPlayedPosition,
        const Duration(seconds: 12),
      );
    },
  );
}
