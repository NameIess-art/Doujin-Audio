import 'dart:async';

import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/core/widgets/swipe_reveal_card.dart';
import 'package:doujin_audio/core/widgets/duration_overlay.dart';
import 'package:doujin_audio/core/widgets/rj_code_overlay.dart';
import 'package:doujin_audio/features/library/presentation/library_card_artwork.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_tree_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/runtime_test_models.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  for (final kind in ['folder', 'covered single', 'uncovered single']) {
    testWidgets(
      '$kind metadata updates preserve card shells and artwork',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final track = MusicTrack(
          path: '/library/card/file.mp3',
          displayName: 'File name',
          groupKey: '/library/card',
          groupTitle: 'Folder name',
          groupSubtitle: '',
          isSingle: kind != 'folder',
          isVideo: kind == 'covered single',
        );
        final target = kind == 'folder'
            ? AudioDetailTarget.libraryRootFolder(track.groupKey)
            : AudioDetailTarget.singleAudioFile(track.path);
        final detail = Completer<AudioDetail>();
        final folder = FolderNode('Folder name', track.groupKey)
          ..addChild(TrackNode(track));
        fixture.library.addTracks([track], persist: false);
        await tester.pumpWidget(
          fixture.build(
            Center(
              child: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LibraryTreeItem(
                      node: kind == 'folder' ? folder : TrackNode(track),
                    ),
                    LibraryTreeItem(
                      node: FolderNode('Unrelated folder', '/library/other'),
                    ),
                  ],
                ),
              ),
            ),
            overrides: [
              libraryDetailForTargetProvider.overrideWith((ref, requested) {
                return requested == target
                    ? detail.future
                    : Future.value(AudioDetail.empty(requested));
              }),
              libraryCoverForTrackProvider.overrideWith((ref, request) => null),
            ],
          ),
        );
        await tester.pump();
        await tester.pumpAndSettle();
        var shellBuilds = 0;
        var artworkBuilds = 0;
        final previous = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previous?.call(element, builtOnce);
          if (element.widget is SwipeRevealCard) shellBuilds++;
          if (element.widget is LibraryCoverThumbnail ||
              element.widget is LibraryTrackCoverThumbnail) {
            artworkBuilds++;
          }
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previous);
        detail.complete(
          AudioDetail.empty(target).copyWith(
            workTitle: 'Updated work title',
            rjCode: 'RJ123456',
            tags: ['Updated metadata'],
            duration: const Duration(minutes: 3),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          find.text('#Updated metadata', findRichText: true),
          findsOneWidget,
        );
        if (kind == 'folder') {
          expect(
            find.text('Updated work title', findRichText: true),
            findsOneWidget,
          );
        }
        if (kind != 'uncovered single') {
          expect(
            tester
                .widget<DurationOverlay>(find.byType(DurationOverlay))
                .duration,
            const Duration(minutes: 3),
          );
          expect(
            tester.widget<RjCodeOverlay>(find.byType(RjCodeOverlay)).rjCode,
            'RJ123456',
          );
        }
        expect(shellBuilds, 0);
        expect(artworkBuilds, 0);
        expect(
          find.text('Unrelated folder', findRichText: true),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        debugPrint(
          'LIBRARY_DETAIL_UPDATE kind=$kind shellBuilds=$shellBuilds artworkBuilds=$artworkBuilds',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }
}

