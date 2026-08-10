import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/domain/library_entry.dart';
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

  test('permanent folder removal stays separate from exclusions', () {
    final service = LibraryService();
    addTearDown(service.dispose);
    const libraryPath = '/library';
    const folderPath = '/library/work';
    const trackPath = '$folderPath/01.mp3';
    final normalizedLibraryPath = path.normalize(libraryPath);
    final track = MusicTrack(
      path: trackPath,
      displayName: '01',
      groupKey: folderPath,
      groupTitle: 'work',
      groupSubtitle: folderPath,
      isSingle: false,
    );
    service
      ..watchedLibraries.add(libraryPath)
      ..watchedFolders.add(folderPath)
      ..excludedLibraryFolders[normalizedLibraryPath] = <String>{
        path.normalize(folderPath),
      }
      ..replaceLibraryEntries(<LibraryEntry>[
        LibraryEntry.folder(
          libraryPath: libraryPath,
          path: folderPath,
          state: LibraryEntryState.active,
        ),
        LibraryEntry.track(
          libraryPath: libraryPath,
          track: track,
          state: LibraryEntryState.active,
        ),
      ]);

    final result = service.permanentlyRemoveLibraryFolder(
      libraryPath,
      folderPath,
    );

    expect(result.changed, isTrue);
    expect(
      result.removedEntryPaths,
      containsAll(<String>[folderPath, trackPath]),
    );
    expect(service.watchedFolders, isEmpty);
    expect(service.libraryEntriesForLibrary(libraryPath), isEmpty);
    expect(service.excludedFoldersForLibrary(libraryPath), isEmpty);
    expect(
      service.permanentlyRemovedLibraryFolders[normalizedLibraryPath],
      <String>{path.normalize(folderPath)},
    );
    expect(service.isLibraryPathExcluded(libraryPath, trackPath), isFalse);
    expect(service.isLibraryPathIgnored(libraryPath, trackPath), isTrue);
    expect(service.clearLibraryExclusions(libraryPath).changed, isFalse);
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
        ..permanentlyRemovedLibraryFolders[oldRoot] = <String>{
          path.join(oldRoot, 'Removed'),
        }
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
      expect(service.permanentlyRemovedLibraryFolders[newRoot], <String>{
        path.join(newRoot, 'Removed'),
      });
      expect(service.libraryEntriesForLibrary(oldRoot), isEmpty);
      expect(
        service.libraryEntriesForLibrary(newRoot).single.path,
        newTrackPath,
      );
    },
  );
}
