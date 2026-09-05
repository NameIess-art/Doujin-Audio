import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/breadcrumbs_bar.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/core/media/music_track.dart';

void main() {
  group('BreadcrumbsBar widget tests', () {
    testWidgets('renders breadcrumb items and separators correctly', (tester) async {
      String? tappedItem;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BreadcrumbsBar(
              items: [
                BreadcrumbItem(
                  title: 'Root Work',
                  icon: Icons.folder_open_rounded,
                  onTap: () => tappedItem = 'root',
                ),
                BreadcrumbItem(
                  title: 'Disc 1',
                  onTap: () => tappedItem = 'disc1',
                ),
                const BreadcrumbItem(
                  title: 'wav',
                  isCurrent: true,
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('breadcrumb_chip_Root Work')), findsOneWidget);
      expect(find.byKey(const ValueKey('breadcrumb_chip_Disc 1')), findsOneWidget);
      expect(find.byKey(const ValueKey('breadcrumb_chip_wav')), findsOneWidget);
      expect(find.byIcon(Icons.folder_open_rounded), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsNWidgets(2));

      await tester.tap(find.byKey(const ValueKey('breadcrumb_chip_Disc 1')));
      expect(tappedItem, 'disc1');

      await tester.tap(find.byKey(const ValueKey('breadcrumb_chip_Root Work')));
      expect(tappedItem, 'root');
    });
  });

  group('FolderNode ancestors and natural sorted tracks', () {
    test('pathAncestors returns complete hierarchy', () {
      final root = FolderNode('Root', '/root');
      final disc1 = FolderNode('Disc 1', '/root/Disc 1', depth: 1);
      final wav = FolderNode('wav', '/root/Disc 1/wav', depth: 2);

      root.addChild(disc1);
      disc1.addChild(wav);

      expect(wav.pathAncestors, [root, disc1]);
      expect(disc1.pathAncestors, [root]);
      expect(root.pathAncestors, isEmpty);
    });

    test('allTracksNaturalSorted orders tracks naturally across folders', () {
      final root = FolderNode('Root', '/root');
      final disc1 = FolderNode('Disc 1', '/root/Disc 1', depth: 1);
      final disc2 = FolderNode('Disc 2', '/root/Disc 2', depth: 1);

      MusicTrack createTrack(String path, String displayName) {
        return MusicTrack(
          path: path,
          displayName: displayName,
          groupKey: 'work',
          groupTitle: 'Work',
          groupSubtitle: '',
          isSingle: false,
        );
      }

      final track10 = createTrack('/root/Disc 1/10.mp3', '10. Track');
      final track2 = createTrack('/root/Disc 1/02.mp3', '02. Track');
      final track1 = createTrack('/root/Disc 1/01.mp3', '01. Track');
      final trackDisc2 = createTrack('/root/Disc 2/01.mp3', '01. Disc 2');

      disc1.addChild(TrackNode(track10));
      disc1.addChild(TrackNode(track2));
      disc1.addChild(TrackNode(track1));
      disc2.addChild(TrackNode(trackDisc2));

      root.addChild(disc2);
      root.addChild(disc1);

      final sorted = root.allTracksNaturalSorted;
      expect(sorted.map((t) => t.displayName).toList(), [
        '01. Track',
        '02. Track',
        '10. Track',
        '01. Disc 2',
      ]);
    });
  });
}
