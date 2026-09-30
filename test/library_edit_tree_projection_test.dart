import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/library/presentation/library_edit_tree_projection.dart';

void main() {
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
}
