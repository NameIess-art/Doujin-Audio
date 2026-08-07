import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/music_track.dart';
import 'package:nameless_audio/features/library/application/library_service.dart';
import 'package:nameless_audio/features/library/domain/library_entry.dart';
import 'package:path/path.dart' as path;

void main() {
  test('clearLibraryExclusions restores entry-backed tracks', () async {
    final service = LibraryService();
    addTearDown(service.dispose);
    const libraryPath = '/library';
    const trackPath = '/library/work/01.mp3';
    final track = MusicTrack(
      path: trackPath,
      displayName: '01',
      groupKey: '/library/work',
      groupTitle: 'work',
      groupSubtitle: '/library/work',
      isSingle: false,
    );
    service.replaceLibraryEntries(<LibraryEntry>[
      LibraryEntry.track(
        libraryPath: libraryPath,
        track: track,
        state: LibraryEntryState.excluded,
      ),
    ]);
    service.rebuildExclusionsFromEntries(
      service.libraryEntriesForLibrary(libraryPath),
    );

    final result = service.clearLibraryExclusions(libraryPath);

    expect(result.changed, isTrue);
    expect(result.restoredEntryPaths, <String>[trackPath]);
    expect(result.restoredTracks.single.path, trackPath);
    expect(service.excludedLibraryTracks, isEmpty);
  });

  test(
    'retargetLibraryFolder moves all mutable library state together',
    () async {
      final service = LibraryService();
      addTearDown(service.dispose);
      final oldRoot = path.join('library', 'Old');
      final newRoot = path.join('library', 'New');
      final oldTrackPath = path.join(oldRoot, '01.mp3');
      final newTrackPath = path.join(newRoot, '01.mp3');
      final track = MusicTrack(
        path: oldTrackPath,
        displayName: '01',
        groupKey: oldRoot,
        groupTitle: 'Old',
        groupSubtitle: oldRoot,
        isSingle: false,
        manualCoverPath: path.join(oldRoot, 'cover.jpg'),
      );
      service
        ..library.add(track)
        ..watchedFolders.add(oldRoot)
        ..watchedLibraries.add(oldRoot)
        ..groupOrder.add(oldRoot)
        ..replaceLibraryEntries(<LibraryEntry>[
          LibraryEntry.track(
            libraryPath: oldRoot,
            track: track,
            state: LibraryEntryState.excluded,
          ),
        ])
        ..rebuildExclusionsFromEntries(
          service.libraryEntriesForLibrary(oldRoot),
        )
        ..rebuildLibraryIndexes();

      final result = service.retargetLibraryFolder(oldRoot, newRoot, 'New');

      expect(result.retargetedTracks.keys, <String>[oldTrackPath]);
      expect(service.library.single.path, newTrackPath);
      expect(service.library.single.groupKey, newRoot);
      expect(service.library.single.groupTitle, 'New');
      expect(
        service.library.single.manualCoverPath,
        path.join(newRoot, 'cover.jpg'),
      );
      expect(service.watchedFolders, <String>[newRoot]);
      expect(service.watchedLibraries, <String>[newRoot]);
      expect(service.groupOrder, <String>[newRoot]);
      expect(service.excludedTracksForLibrary(newRoot), <String>[newTrackPath]);
      expect(service.libraryEntriesForLibrary(oldRoot), isEmpty);
      expect(
        service.libraryEntriesForLibrary(newRoot).single.path,
        newTrackPath,
      );
    },
  );
}
