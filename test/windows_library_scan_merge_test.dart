import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/library_scan_models.dart';
import 'package:doujin_audio/features/library/application/library_scanner_isolate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
