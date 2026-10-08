import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/library_organizer.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';

void main() {
  const organizer = LibraryOrganizer();

  MusicTrack track(
    String path, {
    String? groupKey,
    String? groupTitle,
    String? groupSubtitle,
    bool isSingle = false,
    Duration duration = Duration.zero,
  }) {
    return MusicTrack(
      path: path,
      displayName: path.split('/').last,
      groupKey: groupKey ?? path.substring(0, path.lastIndexOf('/')),
      groupTitle: groupTitle ?? 'Group',
      groupSubtitle: groupSubtitle ?? groupKey ?? 'Group',
      isSingle: isSingle,
      duration: duration,
    );
  }

  test(
    'topLevelNodeIds keeps duplicate files out and preserves first order',
    () {
      final tracks = <MusicTrack>[
        track('/music/a/01.mp3', groupKey: '/music/a', groupTitle: 'A'),
        track('/music/a/01.mp3', groupKey: '/music/a', groupTitle: 'A'),
        track('/music/b/01.mp3', groupKey: '/music/b', groupTitle: 'B'),
      ];

      expect(organizer.topLevelNodeIds(tracks, const <String>[]), <String>[
        '/music/a',
        '/music/b',
      ]);
    },
  );

  test('buildTree groups folders under watched root and sorts tracks', () {
    final snapshot = organizer.buildTree(
      tracks: <MusicTrack>[
        track(
          '/library/root/Album 10/10.mp3',
          groupKey: '/library/root/Album 10',
        ),
        track(
          '/library/root/Album 2/02.mp3',
          groupKey: '/library/root/Album 2',
        ),
        track(
          '/library/root/Album 1/01.mp3',
          groupKey: '/library/root/Album 1',
        ),
      ],
      watchedFolders: const <String>['/library/root'],
    );

    expect(snapshot.leafFolderCount, 3);
    final root = snapshot.tree.single as FolderNode;
    expect(root.path, '/library/root');
    expect(root.children.map((node) => node.name), <String>[
      'Album 1',
      'Album 2',
      'Album 10',
    ]);
  });

  test('content tree root uses decoded display name', () {
    final uri = Uri.parse(
      'content://com.android.externalstorage.documents/tree/primary%3AMusic',
    ).toString();

    final snapshot = organizer.buildTree(
      tracks: <MusicTrack>[
        track(
          '$uri::Album/01.mp3',
          groupKey: '$uri::Album',
          groupSubtitle: 'Music/Album',
        ),
      ],
      watchedFolders: <String>[uri],
    );

    expect(snapshot.tree.single.name, 'Music');
  });

  test('content document tracks match watched tree roots', () {
    const root =
        'content://com.android.externalstorage.documents/tree/primary%3AOld';
    const trackPath = '$root/document/primary%3AOld%2FAlbum%2F01.mp3';

    final snapshot = organizer.buildTree(
      tracks: <MusicTrack>[
        track(trackPath, groupKey: '$root::Album', groupSubtitle: 'Old/Album'),
      ],
      watchedFolders: const <String>[root],
    );

    expect(snapshot.tree.single.path, root);
    expect(snapshot.tree.single.name, 'Old');
  });

  test('content library child roots keep nested folder tree and own names', () {
    const libraryRoot =
        'content://com.android.externalstorage.documents/tree/primary%3ALibrary';
    const childRoot = '$libraryRoot/document/primary%3ALibrary%2FAlbum';

    final snapshot = organizer.buildTree(
      tracks: <MusicTrack>[
        track(
          '$libraryRoot/document/primary%3ALibrary%2FAlbum%2FDisc%2F01.mp3',
          groupKey: '$libraryRoot::Album/Disc',
          groupTitle: 'Disc',
          groupSubtitle: 'Library/Album/Disc',
        ),
      ],
      watchedFolders: const <String>[childRoot],
    );

    final album = snapshot.tree.single as FolderNode;
    expect(album.name, 'Album');
    expect(album.children.single, isA<FolderNode>());
    expect((album.children.single as FolderNode).name, 'Disc');
  });

  test('watched library groups nested audio under the work root', () {
    const libraryRoot =
        'content://com.android.externalstorage.documents/tree/primary%3ALibrary';
    const workRoot = '$libraryRoot::Work';
    final workTrack = track(
      '$libraryRoot/document/work-track.wav',
      groupKey: '$workRoot/Work/音声',
      groupTitle: '音声',
    );

    final cards = organizer.buildCardTree(
      tracks: <MusicTrack>[workTrack],
      watchedFolders: const <String>[],
      watchedLibraries: const <String>[libraryRoot],
    );
    final tree = organizer.buildTree(
      tracks: <MusicTrack>[workTrack],
      watchedFolders: const <String>[],
      watchedLibraries: const <String>[libraryRoot],
    );

    expect(cards.tree.single.path, workRoot);
    expect(tree.tree.single.path, workRoot);
    expect(
      organizer.rootFolderPath(
        '$workRoot/Work/音声',
        const <String>[],
        watchedLibraries: const <String>[libraryRoot],
      ),
      workRoot,
    );
  });

  test('top-level nodes use stable alphabetical order', () {
    final snapshot = organizer.buildTree(
      tracks: <MusicTrack>[
        track('/music/a/01.mp3', groupKey: '/music/a', groupTitle: 'A'),
        track('/music/b/01.mp3', groupKey: '/music/b', groupTitle: 'B'),
      ],
      watchedFolders: const <String>[],
    );

    expect(snapshot.tree.map((node) => node.path), <String>[
      '/music/a',
      '/music/b',
    ]);
  });

  test('prepared folder roots preserve longest match and path equivalence', () {
    const safRoot =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic';
    const safWork = '$safRoot/document/primary%3AMusic%2FWork';
    final roots = <String>[
      '/music',
      '/music/album',
      r'E:\音频 库',
      r'E:\音频 库\作品 A',
      safRoot,
      safWork,
    ]..sort((a, b) => b.length.compareTo(a.length));
    final index = LibraryService.createPathIndex<String>();
    for (final root in roots) {
      index.putIfAbsent(root, () => PathMatcher.normalize(root));
    }
    final cases = <String, String>{
      '/music/album': '/music/album',
      '/music/album/disc': '/music/album',
      '/music/other': '/music',
      'e:/音频 库/作品 a': r'E:\音频 库\作品 A',
      'e:/音频 库/作品 a/Disc': r'E:\音频 库\作品 A',
      '$safRoot::Work': safWork,
      '$safRoot::Work/Disc': safWork,
      '/unwatched/work': PathMatcher.normalize('/unwatched/work'),
    };
    for (final entry in cases.entries) {
      expect(
        organizer.rootFolderPath(
          entry.key,
          roots,
          rootsAlreadySorted: true,
          watchedFolderByPath: index,
        ),
        PathMatcher.normalize(entry.value),
        reason: entry.key,
      );
    }
  });

  test(
    'prepared roots retain library priority and grouped track semantics',
    () {
      const library = '/library';
      const nestedLibrary = '/library/collection';
      const exactFolder = '/library/collection/work/disc';
      final roots = <String>[exactFolder, '/outside'];
      final libraries = <String>[nestedLibrary, library];
      final index = LibraryService.createPathIndex<String>({
        exactFolder: exactFolder,
        '/outside': '/outside',
      });
      expect(
        organizer.rootFolderPath(
          exactFolder,
          roots,
          watchedLibraries: libraries,
          rootsAlreadySorted: true,
          watchedFolderByPath: index,
        ),
        PathMatcher.normalize('/library/collection/work'),
      );
      for (final (item, expected) in <(MusicTrack, String)>[
        (
          track('$exactFolder/01.mp3', groupKey: exactFolder),
          PathMatcher.normalize('/library/collection/work'),
        ),
        (track('/outside/01.mp3', groupKey: '/unwatched'), '/outside'),
        (track('$exactFolder/01.mp3', groupKey: '/outside'), nestedLibrary),
        (
          track('/single.mp3', isSingle: true, groupKey: '__single_files__'),
          '/single.mp3',
        ),
      ]) {
        expect(
          organizer.rootPathForTrack(
            item,
            roots,
            watchedLibraries: libraries,
            rootsAlreadySorted: true,
          ),
          expected,
        );
      }
    },
  );

  test('topLevelNodeIds reflects removed folder state', () {
    final remainingTracks = <MusicTrack>[
      track('/music/b/01.mp3', groupKey: '/music/b', groupTitle: 'B'),
    ];

    expect(
      organizer.topLevelNodeIds(remainingTracks, const <String>[]),
      <String>['/music/b'],
    );
  });

  test('deep multi-root tree caches counts and first tracks correctly', () {
    final snapshot = organizer.buildTree(
      tracks: <MusicTrack>[
        track(
          '/library/a/Disc 2/02.mp3',
          duration: const Duration(seconds: 20),
        ),
        track(
          '/library/a/Disc 1/Sub/01.mp3',
          duration: const Duration(seconds: 10),
        ),
        track('/library/b/Album/03.mp3'),
      ],
      watchedFolders: const <String>['/library/a', '/library/b'],
    );

    expect(snapshot.leafFolderCount, 3);
    final firstRoot = snapshot.tree.first as FolderNode;
    final secondRoot = snapshot.tree.last as FolderNode;
    expect(firstRoot.totalTrackCount, 2);
    expect(firstRoot.leafFolderCount, 2);
    expect(firstRoot.firstTrack?.path, '/library/a/Disc 1/Sub/01.mp3');
    expect(firstRoot.totalDuration, const Duration(seconds: 30));
    expect(secondRoot.totalTrackCount, 1);
    expect(secondRoot.leafFolderCount, 1);
    expect(secondRoot.firstTrack?.path, '/library/b/Album/03.mp3');
  });

  test('10k-track tree benchmark records observational build time', () {
    final tracks = List<MusicTrack>.generate(10000, (index) {
      final folder = index % 100;
      return track(
        '/benchmark/Album ${folder.toString().padLeft(3, '0')}/'
        '${index.toString().padLeft(5, '0')}.mp3',
      );
    }, growable: false);
    final stopwatch = Stopwatch()..start();

    final snapshot = organizer.buildTree(
      tracks: tracks,
      watchedFolders: const <String>['/benchmark'],
    );
    stopwatch.stop();

    final root = snapshot.tree.single as FolderNode;
    expect(root.totalTrackCount, 10000);
    expect(root.leafFolderCount, 100);
    // Observation only: CI hardware variance makes a hard threshold unreliable.
    // ignore: avoid_print
    print('library_organizer_10k_ms=${stopwatch.elapsedMilliseconds}');
  });
}
