import 'dart:collection';

import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_ui_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingNodes extends ListBase<LibraryNode> {
  _CountingNodes(this.nodes);

  final List<LibraryNode> nodes;
  int reads = 0;

  @override
  int get length => nodes.length;

  @override
  set length(int value) => throw UnsupportedError('Read only');

  @override
  LibraryNode operator [](int index) {
    reads++;
    return nodes[index];
  }

  @override
  void operator []=(int index, LibraryNode value) =>
      throw UnsupportedError('Read only');
}

void main() {
  test('initial selection stops after finding its node in a large library', () {
    final nodes = _CountingNodes([
      for (var index = 0; index < 5000; index++)
        FolderNode('Work $index', '/library/$index'),
    ]);

    final selected = selectedLibraryNodeSelections(nodes, {
      PathMatcher.normalize('/library/0'),
    });

    expect(selected.single.path, '/library/0');
    expect(nodes.reads, 1);
    nodes.reads = 0;
    expect(selectedLibraryNodeSelections(nodes, {}), isEmpty);
    expect(nodes.reads, 0);
  });

  test('selection preserves catalog order and ignores nonselectable nodes', () {
    final track = MusicTrack(
      path: '/library/audio.mp3',
      displayName: 'Audio',
      groupKey: '/library',
      groupTitle: 'Library',
      groupSubtitle: '',
      isSingle: true,
    );
    final nodes = <LibraryNode>[
      FolderNode('Work', '/library/work'),
      FolderNode('Nested', '/library/work/nested', depth: 1),
      TrackNode(track),
    ];

    final selected = selectedLibraryNodeSelections(
      nodes,
      {
        track.path,
        '/library/work/nested',
        '/library/work',
        '/library/stale',
      }.map(PathMatcher.normalize).toSet(),
    );

    expect(selected.map((entry) => entry.path), ['/library/work', track.path]);
    expect(selected.last.firstTrack, same(track));
  });
}
