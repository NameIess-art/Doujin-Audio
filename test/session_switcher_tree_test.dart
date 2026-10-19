import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/player/application/session_switcher_tree.dart';
import 'package:doujin_audio/features/player/domain/playback_queue.dart';
import 'package:flutter_test/flutter_test.dart';

MusicTrack _track(String name, {String? url}) => MusicTrack(
  path: url ?? '/work/$name',
  displayName: name,
  groupKey: '/work',
  groupTitle: 'Work',
  groupSubtitle: '',
  isSingle: false,
  remoteMetadataKind: url == null ? null : MusicTrack.remoteMetadataKindAsmrOne,
  remoteMetadata: url == null ? null : {'id': 7, 'trackRelativePath': name},
);

Future<SessionSwitcherTree> _prepare(
  List<MusicTrack> tracks, {
  PlaybackQueueDefinition? queue,
  List<MusicTrack>? custom,
  String? path,
  int index = 0,
  Set<String> expanded = const {},
  bool expandSelected = true,
}) => prepareSessionSwitcherTree(
  tracks: tracks,
  queue: queue,
  customQueueTracks: custom,
  currentPath: path ?? tracks.first.path,
  currentQueueIndex: index,
  workRoot: '/work',
  resolveTrack: (_) => null,
  workRootForTrack: (_) => '/work',
  expanded: expanded,
  expandSelected: expandSelected,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'background tree keeps remote natural order and original identities',
    () async {
      final tracks = [
        _track('disc/Track 10.mp3', url: 'https://new.test/10'),
        _track('disc/Track 2.mp3', url: 'https://new.test/2'),
      ];
      final old = _track('disc/Track 2.mp3', url: 'https://old.test/2');
      var completed = false;
      final pending = _prepare(tracks, custom: [old], path: old.path).then((
        value,
      ) {
        completed = true;
        return value;
      });
      await Future<void>.value();
      expect(completed, isFalse);
      final tree = await pending;
      final leaves = tree.rows.where((row) => !row.node.isFolder).toList();
      expect(leaves.map((row) => row.node.title), [
        'disc/Track 2.mp3',
        'disc/Track 10.mp3',
      ]);
      expect(leaves.first.node.track, same(tracks[1]));
      expect(leaves.last.node.track, same(tracks[0]));
      expect(leaves.first.node.selected, isTrue);
    },
  );

  test('duplicate queue occurrences retain the selected queue index', () async {
    final track = _track('same.mp3');
    final queue = PlaybackQueueDefinition(
      name: 'Queue',
      entries: [
        for (final id in ['one', 'two'])
          PlaybackQueueEntry(
            id: id,
            kind: PlaybackQueueEntryKind.track,
            title: id,
            tracks: [track],
          ),
      ],
    );
    final tree = await _prepare(queue.expandedTracks, queue: queue, index: 1);
    final leaves = tree.rows.where((row) => !row.node.isFolder).toList();
    expect(leaves.map((row) => row.node.queueIndex), [0, 1]);
    expect(leaves.map((row) => row.node.selected), [false, true]);
    expect(leaves.every((row) => identical(row.node.track, track)), isTrue);
  });

  test(
    'equal tracks with distinct metadata keep their original objects',
    () async {
      final first = _track('same.mp3').copyWith(tags: ['first']);
      final second = _track('same.mp3').copyWith(tags: ['second']);
      final tree = await _prepare([first, second], custom: [first, second]);
      final leaves = tree.rows.where((row) => !row.node.isFolder).toList();
      expect(leaves[0].node.track, same(first));
      expect(leaves[1].node.track, same(second));
    },
  );

  test('prepared tree retains explicit folder expansion', () async {
    final tracks = [_track('disc/one.mp3'), _track('disc/two.mp3')];
    final initial = await _prepare(tracks);
    final folders = initial.expanded;
    expect(folders, isNotEmpty);
    final restored = await _prepare(
      tracks,
      expanded: folders,
      expandSelected: false,
    );
    expect(restored.expanded, folders);
    expect(restored.rows.where((row) => !row.node.isFolder), hasLength(2));
  });
}
