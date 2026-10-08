import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/domain/library_entry.dart';
import 'package:path/path.dart' as path;

void main() {
  test(
    'equivalent Windows paths preserve spelling and user state when merged',
    () async {
      final service = LibraryService();
      addTearDown(service.dispose);
      final original = MusicTrack(
        path: r'C:\Music\Track.mp3',
        displayName: 'original',
        groupKey: r'C:\Music',
        groupTitle: 'Music',
        groupSubtitle: '',
        isSingle: false,
        isFavorite: true,
        lastPlayedPosition: const Duration(seconds: 12),
      );
      service.addTracks([original], persist: false);
      expect(service.trackByPath(r'c:/music/track.mp3'), same(original));
      service.addOrReplaceTracks([
        MusicTrack(
          path: r'c:\music\track.mp3',
          displayName: 'updated',
          groupKey: r'C:\Music',
          groupTitle: 'Music',
          groupSubtitle: '',
          isSingle: false,
        ),
      ], persist: false);
      expect(service.library, hasLength(1));
      expect(service.library.single.path, original.path);
      expect(service.library.single.displayName, 'updated');
      expect(service.library.single.isFavorite, isTrue);
      expect(
        service.library.single.lastPlayedPosition,
        const Duration(seconds: 12),
      );
      service.addTracks([original], persist: false);
      expect(service.library, hasLength(1));
    },
  );

  test(
    'equivalent Windows paths replace all fields without duplicating tracks',
    () async {
      final service = LibraryService();
      addTearDown(service.dispose);
      final original = MusicTrack(
        path: r'C:\Music\Track.mp3',
        displayName: 'original',
        groupKey: r'C:\Music',
        groupTitle: 'Music',
        groupSubtitle: '',
        isSingle: false,
        isFavorite: true,
        lastPlayedPosition: const Duration(seconds: 12),
        manualCoverPath: r'C:\Music\old.jpg',
      );
      service.addTracks([original], persist: false);
      final replacement = MusicTrack(
        path: r'c:/music/track.mp3',
        displayName: 'replacement',
        groupKey: r'C:\Music',
        groupTitle: 'Music',
        groupSubtitle: '',
        isSingle: false,
        duration: const Duration(seconds: 30),
      );

      final mutation = service.addOrReplaceTracks(
        [replacement],
        persist: false,
        mergeExistingState: false,
      );

      expect(service.library, hasLength(1));
      final stored = service.library.single;
      expect(stored.path, original.path);
      expect(stored.displayName, replacement.displayName);
      expect(stored.duration, replacement.duration);
      expect(stored.isFavorite, isFalse);
      expect(stored.lastPlayedPosition, Duration.zero);
      expect(stored.manualCoverPath, isNull);
      expect(service.trackByPath(replacement.path), same(stored));
      expect(mutation.tracks.single, same(stored));
    },
  );

  test('retarget moves and deduplicates every watched descendant', () async {
    final service = LibraryService();
    addTearDown(service.dispose);
    service.watchedFolders.addAll([
      r'C:\Old\Child',
      r'C:\Old\Child\Nested',
      r'c:\NEW\child',
    ]);
    service.watchedLibraries.addAll([r'C:\Old', r'C:\Old\Child']);
    service.retargetLibraryFolder(r'C:\Old', r'C:\New', 'New');
    expect(service.watchedFolders, [r'C:\New\Child', r'C:\New\Child\Nested']);
    expect(service.watchedLibraries, [r'C:\New', r'C:\New\Child']);
  });
  test('scan rollback replaces all fields of an existing track', () async {
    final service = LibraryService();
    addTearDown(service.dispose);
    final original = MusicTrack(
      path: '/music/01.mp3',
      displayName: 'original',
      groupKey: '/music',
      groupTitle: 'music',
      groupSubtitle: '/music',
      isSingle: false,
    );
    service.library.add(original);
    service.rebuildLibraryIndexes();

    service.addOrReplaceTracks(<MusicTrack>[
      MusicTrack(
        path: original.path,
        displayName: 'changed',
        groupKey: '/music',
        groupTitle: 'music',
        groupSubtitle: '/music',
        isSingle: false,
        manualCoverPath: '/music/new-cover.jpg',
        duration: const Duration(seconds: 30),
      ),
    ], persist: false);
    service.addOrReplaceTracks(
      <MusicTrack>[original],
      persist: false,
      mergeExistingState: false,
    );

    expect(identical(service.library.single, original), isTrue);
    expect(service.library.single.duration, Duration.zero);
    expect(service.library.single.manualCoverPath, isNull);
  });

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

  test(
    'retargetLibraryFolder keeps a nested folder under its library root',
    () {
      final service = LibraryService();
      addTearDown(service.dispose);
      final libraryRoot = path.join('library', 'Work');
      final oldFolder = path.join(libraryRoot, 'Old');
      final newFolder = path.join(libraryRoot, 'New');
      final oldTrackPath = path.join(oldFolder, '01.mp3');
      final newTrackPath = path.join(newFolder, '01.mp3');
      final track = MusicTrack(
        path: oldTrackPath,
        displayName: '01',
        groupKey: oldFolder,
        groupTitle: 'Old',
        groupSubtitle: oldFolder,
        isSingle: false,
      );
      service
        ..library.add(track)
        ..watchedFolders.add(libraryRoot)
        ..groupOrder.add(oldFolder)
        ..replaceLibraryEntries(<LibraryEntry>[
          LibraryEntry.folder(
            libraryPath: libraryRoot,
            path: oldFolder,
            parentPath: libraryRoot,
            state: LibraryEntryState.active,
            displayName: 'Old',
          ),
          LibraryEntry.track(
            libraryPath: libraryRoot,
            track: track,
            state: LibraryEntryState.active,
          ),
        ])
        ..rebuildLibraryIndexes();

      final result = service.retargetLibraryFolder(
        oldFolder,
        newFolder,
        'New',
        libraryRootPath: libraryRoot,
      );

      expect(result.retargetedTracks.keys, <String>[oldTrackPath]);
      expect(service.library.single.path, newTrackPath);
      expect(service.library.single.groupKey, newFolder);
      expect(service.library.single.groupTitle, 'New');
      expect(service.watchedFolders, <String>[libraryRoot]);
      expect(service.groupOrder, <String>[newFolder]);
      expect(service.libraryEntriesForLibrary(oldFolder), isEmpty);
      final entries = service.libraryEntriesForLibrary(libraryRoot);
      expect(
        entries.map((entry) => entry.path),
        containsAll(<String>[newFolder, newTrackPath]),
      );
      expect(entries.singleWhere((entry) => entry.isFolder).displayName, 'New');
    },
  );

  test('addWatchedLibrary and removeWatchedLibrary increment structureRevision', () {
    final service = LibraryService();
    addTearDown(service.dispose);
    const libraryPath = '/library/test';

    final initialRevision = service.structureRevision;
    final added = service.addWatchedLibrary(libraryPath);
    expect(added, isTrue);
    expect(service.structureRevision, greaterThan(initialRevision));

    final afterAddRevision = service.structureRevision;
    final removed = service.removeWatchedLibrary(libraryPath);
    expect(removed, isTrue);
    expect(service.structureRevision, greaterThan(afterAddRevision));
  });
}
