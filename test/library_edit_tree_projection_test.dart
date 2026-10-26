import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/features/library/presentation/library_edit_tree_projection.dart';

void main() {
  test(
    'large projections and metadata filtering yield to the UI isolate',
    () async {
      const root = '/library';
      final tracks = List.generate(
        2000,
        (index) => MusicTrack(
          path: '$root/Work/Disc/${index + 1}.mp3',
          displayName: 'Track ${index + 1}',
          groupKey: 'work',
          groupTitle: index == 1499 ? 'Special voice' : 'Work',
          groupSubtitle: 'Circle',
          isSingle: false,
        ),
      );
      final request = LibraryEditTreeRequest(
        libraryPath: root,
        tracks: tracks,
        diskTrackPaths: tracks.map((track) => track.path).toList(),
        diskTrackPathSet: tracks
            .map((track) => PathMatcher.normalize(track.path))
            .toSet(),
        diskTrackParents: const {},
        liveFolders: const {'$root/Work', '$root/Work/Disc'},
        authoritative: true,
        excludedTracks: const [],
        excludedFolders: const [],
        entries: const [],
        childFolders: const [],
        restoringFolders: const [],
      );
      var eventProcessed = false;
      Timer.run(() => eventProcessed = true);
      final snapshot = await request.project();
      expect(eventProcessed, isTrue);
      final work = snapshot.nodes.single as LibraryEditFolderTreeNode;
      final disc = work.children.single as LibraryEditFolderTreeNode;
      expect(disc.children, hasLength(2000));
      expect(disc.children.first.name, '1');
      expect(disc.children.last.name, '2000');
      final filtered = await snapshot.filter('SPECIAL VOICE');
      final filteredWork = filtered.single as LibraryEditFolderTreeNode;
      final filteredDisc =
          filteredWork.children.single as LibraryEditFolderTreeNode;
      expect(filteredDisc.children.single.name, '1500');
      expect(disc.children, hasLength(2000));
    },
  );

  test(
    'snapshot projection preserves confirmed SAF parents and disk pruning',
    () async {
      const root = 'content://provider/tree/root';
      const nested = '$root/document/123';
      const deleted = '$root/document/456';
      const foreign = 'content://provider/tree/other/document/789';
      final request = LibraryEditTreeRequest(
        libraryPath: root,
        tracks: const [],
        diskTrackPaths: const [nested, foreign],
        diskTrackPathSet: const {nested, foreign},
        diskTrackParents: const {
          nested: '$root::Work/Disc',
          foreign: '$root::Work',
        },
        liveFolders: const {'$root::Work', '$root::Work/Disc', '$root::Empty'},
        authoritative: true,
        excludedTracks: const [nested, deleted],
        excludedFolders: const ['$root::Empty', '$root::Deleted'],
        entries: const [],
        childFolders: const [],
        restoringFolders: [
          LibraryEditFolderTreeNode(
            folderPath: '$root::Deleted',
            depth: 0,
            children: [LibraryEditTrackTreeNode(deleted)],
          ),
        ],
      );
      final snapshot = await request.project();
      expect(snapshot.nodes.map((node) => node.name), ['Empty', 'Work']);
      final work = snapshot.nodes.last as LibraryEditFolderTreeNode;
      final disc = work.children.single as LibraryEditFolderTreeNode;
      expect(disc.children.single.pathValue, nested);
      expect(await snapshot.filter('123'), hasLength(1));
    },
  );

  test('opaque SAF tracks retain confirmed scan and persisted parents', () {
    const root = 'content://provider/tree/root';
    const projection = LibraryEditTreeProjection(root);
    const nested = '$root/document/123';
    const direct = '$root/document/456';
    const foreign = 'content://provider/tree/other/document/789';
    final tree = projection.buildEditTree(
      [nested, direct, foreign],
      [],
      [],
      trackParentPaths: {
        nested: '$root::Work/Disc',
        direct: root,
        foreign: '$root::Work',
      },
    );
    final work = tree.first as LibraryEditFolderTreeNode;
    final disc = work.children.single as LibraryEditFolderTreeNode;
    expect(work.folderPath, '$root::Work');
    expect(disc.folderPath, '$root::Work/Disc');
    expect(disc.children.single.pathValue, nested);
    expect(tree.last.pathValue, direct);
    expect(tree, hasLength(2));
    expect(projection.includedTrackCounts(tree, (uri) => uri != nested), {
      '$root::Work': 0,
      '$root::Work/Disc': 0,
    });
    final restored = projection.buildEditTree([], [], [work]);
    expect(
      ((restored.single as LibraryEditFolderTreeNode).children.single
              as LibraryEditFolderTreeNode)
          .children
          .single
          .pathValue,
      nested,
    );
  });
  test(
    'restored folders merge without duplicate tracks or out-of-root files',
    () {
      const projection = LibraryEditTreeProjection('/library');
      final snapshot = LibraryEditFolderTreeNode(
        folderPath: '/library/Disc 2',
        depth: 0,
        children: [LibraryEditTrackTreeNode('/library/Disc 2/10.mp3')],
      );
      final tree = projection.buildEditTree(
        ['/library/Disc 2/10.mp3', '/library/Disc 2/2.mp3', '/other/1.mp3'],
        ['/library/Disc 10'],
        [snapshot],
      );
      expect(tree.map((node) => node.name), ['Disc 2', 'Disc 10']);
      expect(
        (tree.first as LibraryEditFolderTreeNode).children.map(
          (node) => node.name,
        ),
        ['2', '10'],
      );
      expect(snapshot.children, hasLength(1));
    },
  );

  test('filter keeps nested ancestry and leaves base tree intact', () {
    const projection = LibraryEditTreeProjection('/library');
    final tree = projection.buildEditTree(
      ['/library/Work/Disc 1/01.mp3', '/library/Work/Disc 1/02.mp3'],
      [],
      [],
    );
    final filtered = projection.filterEditTree(
      tree,
      'VOICE',
      (track, query) => track.endsWith('02.mp3') && query == 'voice',
    );
    final work = filtered.single as LibraryEditFolderTreeNode;
    final disc = work.children.single as LibraryEditFolderTreeNode;
    expect(work.name, 'Work');
    expect(disc.name, 'Disc 1');
    expect(disc.children.single.name, '02');
    expect(
      ((tree.single as LibraryEditFolderTreeNode).children.single
              as LibraryEditFolderTreeNode)
          .children,
      hasLength(2),
    );
  });

  test('SAF document tracks retain virtual parent folder paths', () {
    const root =
        'content://com.android.externalstorage.documents/tree/primary%3AASMR';
    const track = '$root/document/primary%3AASMR%2FWork%2FDisc1%2F01.mp3';
    const projection = LibraryEditTreeProjection(root);
    final tree = projection.buildEditTree([track], [], []);
    final work = tree.single as LibraryEditFolderTreeNode;
    final disc = work.children.single as LibraryEditFolderTreeNode;
    expect(work.folderPath, '$root::Work');
    expect(disc.folderPath, '$root::Work/Disc1');
    expect(disc.children.single.pathValue, track);
  });

  test('included counts visit each track once across nested folders', () {
    const projection = LibraryEditTreeProjection('/library');
    final tree = projection.buildEditTree(
      [
        '/library/Work/01.mp3',
        '/library/Work/Disc/02.mp3',
        '/library/Work/Disc/03.mp3',
      ],
      ['/library/Empty'],
      [],
    );
    final visits = <String, int>{};
    final counts = projection.includedTrackCounts(tree, (track) {
      visits.update(track, (count) => count + 1, ifAbsent: () => 1);
      return !track.endsWith('02.mp3');
    });
    expect(visits.values, everyElement(1));
    expect(visits, hasLength(3));
    expect(counts[PathMatcher.normalize('/library/Work')], 2);
    expect(counts[PathMatcher.normalize('/library/Work/Disc')], 1);
    expect(counts[PathMatcher.normalize('/library/Empty')], 0);

    final filtered = projection.filterEditTree(
      tree,
      '03',
      (track, query) => track.contains(query),
    );
    expect(projection.includedTrackCounts(filtered, (_) => true), {
      PathMatcher.normalize('/library/Work'): 1,
      PathMatcher.normalize('/library/Work/Disc'): 1,
    });
    expect(
      projection.includedTrackCounts(tree, (_) => true)[PathMatcher.normalize(
        '/library/Work',
      )],
      3,
    );
  });
}
