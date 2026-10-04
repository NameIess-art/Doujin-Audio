import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/library_scan_rules.dart';

void main() {
  const rules = LibraryScanRules();
  final existingTrack = MusicTrack(
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
        tracks: <MusicTrack>[existingTrack],
      ),
      isTrue,
    );
  });

  test('track overlap respects watched roots and single-file entries', () {
    expect(
      rules.areAnyTracksAlreadyInLibrary(
        trackPaths: const ['/library/work/02.mp3'],
        watchedFolders: const <String>['/library/work'],
        watchedLibraries: const <String>[],
        tracks: const <MusicTrack>[],
      ),
      isTrue,
    );
    expect(
      rules.areAnyTracksAlreadyInLibrary(
        trackPaths: const ['/other/02.mp3'],
        watchedFolders: const <String>[],
        watchedLibraries: const <String>[],
        tracks: <MusicTrack>[existingTrack],
      ),
      isFalse,
    );
  });

  test('batch overlap scans the existing catalog once for many new files', () {
    var visitedTracks = 0;
    Iterable<MusicTrack> library() sync* {
      for (var index = 0; index < 10000; index++) {
        visitedTracks++;
        yield MusicTrack.fromJson({
          ...existingTrack.toJson(),
          'path': '/library/work/$index.mp3',
        });
      }
    }

    expect(
      rules.areAnyTracksAlreadyInLibrary(
        trackPaths: List.generate(1000, (index) => '/other/$index.mp3'),
        watchedFolders: const [],
        watchedLibraries: const [],
        tracks: library(),
      ),
      isFalse,
    );
    expect(visitedTracks, 10000);
  });

  test('batch overlap keeps path equivalence and ancestor direction', () {
    const tree = 'content://provider/tree/primary%3AMusic';
    const document = '$tree/document/primary%3AMusic%2FWork%2F01.mp3';
    final cases = <({String existing, String candidate, bool expected})>[
      (
        existing: r'C:\Music\Work',
        candidate: 'c:/music/work/01.mp3',
        expected: true,
      ),
      (
        existing: '/music/work',
        candidate: '/music/work-other/01.mp3',
        expected: false,
      ),
      (existing: '/music/work', candidate: '/music', expected: false),
      (existing: tree, candidate: document, expected: true),
      (existing: '$tree::Work', candidate: document, expected: true),
      (existing: '$tree::Other', candidate: document, expected: false),
      (
        existing: 'https://example.test/work',
        candidate: 'https://example.test/work/01.mp3',
        expected: false,
      ),
    ];
    for (final scenario in cases) {
      expect(
        rules.areAnyTracksAlreadyInLibrary(
          trackPaths: [scenario.candidate],
          watchedFolders: [scenario.existing],
          watchedLibraries: const [],
          tracks: const [],
        ),
        scenario.expected,
        reason: '${scenario.candidate} under ${scenario.existing}',
      );
    }
    expect(
      rules.areAnyTracksAlreadyInLibrary(
        trackPaths: const ['$tree::Work/01.mp3'],
        watchedFolders: const [],
        watchedLibraries: const [],
        tracks: [
          MusicTrack.fromJson({
            ...existingTrack.toJson(),
            'path': document,
            'groupKey': '__single_files__',
          }),
        ],
      ),
      isTrue,
    );
    expect(
      rules.areAnyTracksAlreadyInLibrary(
        trackPaths: const ['/other/01.mp3'],
        watchedFolders: const [],
        watchedLibraries: const [],
        tracks: [
          MusicTrack.fromJson({
            ...existingTrack.toJson(),
            'path': '/elsewhere/01.mp3',
            'groupKey': '__single_files__',
          }),
        ],
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
        tracks: <MusicTrack>[existingTrack],
      ),
      isFalse,
    );
  });
}
