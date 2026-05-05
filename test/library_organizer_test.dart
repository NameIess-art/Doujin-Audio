import 'package:flutter_test/flutter_test.dart';
import 'package:music_player/models/library_node.dart';
import 'package:music_player/models/music_track.dart';
import 'package:music_player/services/library_organizer.dart';

void main() {
  const organizer = LibraryOrganizer();

  MusicTrack track(
    String path, {
    String? groupKey,
    String? groupTitle,
    String? groupSubtitle,
    bool isSingle = false,
  }) {
    return MusicTrack(
      path: path,
      displayName: path.split('/').last,
      groupKey: groupKey ?? path.substring(0, path.lastIndexOf('/')),
      groupTitle: groupTitle ?? 'Group',
      groupSubtitle: groupSubtitle ?? groupKey ?? 'Group',
      isSingle: isSingle,
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
        track('/library/root/b/02.mp3', groupKey: '/library/root/b'),
        track('/library/root/a/01.mp3', groupKey: '/library/root/a'),
      ],
      watchedFolders: const <String>['/library/root'],
      nodeOrder: const <String>[],
    );

    expect(snapshot.leafFolderCount, 2);
    final root = snapshot.tree.single as FolderNode;
    expect(root.path, '/library/root');
    expect(root.children.map((node) => node.name), <String>['a', 'b']);
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
      nodeOrder: const <String>[],
    );

    expect(snapshot.tree.single.name, 'Music');
  });

  test('node order wins over alphabetical order', () {
    final snapshot = organizer.buildTree(
      tracks: <MusicTrack>[
        track('/music/a/01.mp3', groupKey: '/music/a', groupTitle: 'A'),
        track('/music/b/01.mp3', groupKey: '/music/b', groupTitle: 'B'),
      ],
      watchedFolders: const <String>[],
      nodeOrder: const <String>['/music/b', '/music/a'],
    );

    expect(snapshot.tree.map((node) => node.path), <String>[
      '/music/b',
      '/music/a',
    ]);
  });

  test('topLevelNodeIds reflects removed folder state', () {
    final remainingTracks = <MusicTrack>[
      track('/music/b/01.mp3', groupKey: '/music/b', groupTitle: 'B'),
    ];

    expect(
      organizer.topLevelNodeIds(remainingTracks, const <String>[]),
      <String>['/music/b'],
    );
  });
}
