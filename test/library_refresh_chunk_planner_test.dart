import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/library_snapshot_cache_service.dart';

void main() {
  MusicTrack track(int index) => MusicTrack(
    path: '/music/$index.mp3',
    displayName: '$index',
    groupKey: '/music',
    groupTitle: 'music',
    groupSubtitle: '/music',
    isSingle: false,
  );

  test(
    'derived snapshot builds indexes, natural order, and cards together',
    () {
      final snapshot = buildLibraryDerivedSnapshot(
        LibraryDerivedSnapshotPayload(
          tracks: <MusicTrack>[track(10), track(2), track(1)],
          watchedFolders: const <String>['/music'],
        ),
      );

      expect(snapshot.libraryByPath.keys, contains('/music/10.mp3'));
      expect(snapshot.libraryIndexByPath['/music/2.mp3'], 1);
      expect(snapshot.sortedLibraryTrackPaths, const <String>[
        '/music/1.mp3',
        '/music/2.mp3',
        '/music/10.mp3',
      ]);
      expect(snapshot.tracksByGroup['/music'], hasLength(3));
      expect(snapshot.cardSnapshot.tree, hasLength(1));
      expect(snapshot.cardSnapshot.tree.single.path, '/music');
      expect(
        (snapshot.cardSnapshot.tree.single as FolderNode).children,
        isEmpty,
      );
    },
  );

  test('derived snapshot reuses natural order for groups and cards', () {
    final tracks = <MusicTrack>[
      track(10),
      MusicTrack(
        path: '/music/other/11.mp3',
        displayName: '11',
        groupKey: '/music/other',
        groupTitle: 'other',
        groupSubtitle: '/music/other',
        isSingle: false,
      ),
      track(2),
      track(1),
    ];

    final snapshot = buildLibraryDerivedSnapshot(
      LibraryDerivedSnapshotPayload(
        tracks: tracks,
        watchedFolders: const <String>['/music'],
      ),
    );
    final folder = snapshot.cardSnapshot.tree.single as FolderNode;

    expect(
      snapshot.tracksByGroup['/music']!.map((item) => item.displayName),
      const <String>['1', '2', '10'],
    );
    expect(
      folder.allTracks.map((item) => item.path),
      snapshot.sortedLibraryTracks.map((item) => item.path),
    );
  });

  test('watched library snapshot keeps nested groups under the work root', () {
    const libraryRoot = '/library';
    const workRoot = '$libraryRoot/Work';
    const nestedGroup = '$workRoot/Work/voice';
    const nestedTrack = '$nestedGroup/track.wav';

    final snapshot = buildLibraryDerivedSnapshot(
      LibraryDerivedSnapshotPayload(
        tracks: <MusicTrack>[
          MusicTrack(
            path: nestedTrack,
            displayName: 'track',
            groupKey: nestedGroup,
            groupTitle: 'voice',
            groupSubtitle: nestedGroup,
            isSingle: false,
          ),
        ],
        watchedFolders: const <String>[],
        watchedLibraries: const <String>[libraryRoot],
      ),
    );

    expect(snapshot.cardSnapshot.tree, hasLength(1));
    expect(
      snapshot.cardSnapshot.tree.single.path.replaceAll('\\', '/'),
      workRoot,
    );
  });
}
