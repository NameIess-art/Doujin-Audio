import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/music_track.dart';
import 'package:nameless_audio/features/library/application/library_scan_rules.dart';

void main() {
  const rules = LibraryScanRules();
  const existingTrack = MusicTrack(
    path: '/library/work/01.mp3',
    displayName: '01',
    groupKey: '/library/work',
    groupTitle: 'work',
    groupSubtitle: '/library/work',
    isSingle: false,
  );

  test('folder overlap detects watched and existing library content', () {
    expect(
      rules.isFolderAlreadyInLibrary(
        folderPath: '/library/work/disc',
        watchedFolders: const <String>['/library/work'],
        watchedLibraries: const <String>[],
        tracks: const <MusicTrack>[],
      ),
      isTrue,
    );
    expect(
      rules.isFolderAlreadyInLibrary(
        folderPath: '/library',
        watchedFolders: const <String>[],
        watchedLibraries: const <String>[],
        tracks: const <MusicTrack>[existingTrack],
      ),
      isTrue,
    );
  });

  test('track overlap respects watched roots and single-file entries', () {
    expect(
      rules.isTrackAlreadyInLibrary(
        trackPath: '/library/work/02.mp3',
        watchedFolders: const <String>['/library/work'],
        watchedLibraries: const <String>[],
        tracks: const <MusicTrack>[],
      ),
      isTrue,
    );
    expect(
      rules.isTrackAlreadyInLibrary(
        trackPath: '/other/02.mp3',
        watchedFolders: const <String>[],
        watchedLibraries: const <String>[],
        tracks: const <MusicTrack>[existingTrack],
      ),
      isFalse,
    );
  });

  test('promotion excludes content owned by promoted standalone folders', () {
    expect(
      rules.watchedFoldersToPromote(
        folderPath: '/library',
        watchedFolders: const <String>['/library/work', '/other/work'],
      ),
      const <String>['/library/work'],
    );
    expect(
      rules.hasUnmanagedLibraryContentOverlap(
        folderPath: '/library',
        promotedFolders: const <String>['/library/work'],
        tracks: const <MusicTrack>[existingTrack],
      ),
      isFalse,
    );
  });
}
