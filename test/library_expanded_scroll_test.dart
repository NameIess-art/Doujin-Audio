import 'package:doujin_audio/app/application/browse_page_state_store.dart';
import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_tree_widgets.dart';
import 'package:doujin_audio/features/library/presentation/library_tree_list.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/runtime_test_models.dart';

void main() {
  AppRuntimeTestFixture.initialize();
  setUp(UiInteractionCoordinator.instance.resetForTest);
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  for (final width in [450.0, 1280.0]) {
    testWidgets(
      'expanded library skips intermediate tracks on long scroll jumps at $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 650);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        final root = FolderNode('Expanded work', '/expanded');
        final child = FolderNode('Nested folder', '/expanded/child', depth: 1);
        child.addChildren(
          List.generate(
            1000,
            (index) => TrackNode(
              testMusicTrack(
                name: 'Track $index',
                path: '/expanded/child/$index.mp3',
                groupKey: root.path,
                groupTitle: root.name,
              ),
            ),
          ),
        );
        root.addChild(child);
        final store = BrowsePageStateStore();
        store.update('library', {
          'expanded': [
            PathMatcher.normalize(root.path),
            PathMatcher.normalize(child.path),
          ],
        });
        await tester.pumpWidget(
          fixture.build(
            LibraryTreeList(
              tree: [root],
              structureRevision: 1,
              selectedPaths: const {},
              isSelectionMode: false,
              scrollController: scroll,
              i18n: fixture.languageProvider,
              topPadding: 12,
              bottomPadding: 20,
              cacheExtent: 0,
              physics: null,
              loadFolder: (_) async => root,
              currentStructureRevision: () => 1,
              onLongPress: (_) {},
              onToggleSelect: (_) {},
            ),
            overrides: [
              browsePageStateStoreProvider.overrideWithValue(store),
              libraryDetailForTargetProvider.overrideWith(
                (ref, target) async => AudioDetail.empty(target),
              ),
            ],
          ),
        );
        for (var attempt = 0; attempt < 1000; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(microseconds: 1));
          await tester.pumpAndSettle();
          if (find.byType(LibraryTreeItem).evaluate().length >= 3 &&
              tester
                      .widget<ListView>(find.byType(ListView))
                      .itemExtentBuilder !=
                  null) {
            break;
          }
        }
        expect(scroll.hasClients, isTrue);
        expect(
          tester.getSize(find.byType(LibraryTreeItem).at(0)).height,
          LibraryLikeCardMetrics.rootTileHeight,
        );
        expect(tester.getSize(find.byType(LibraryTreeItem).at(1)).height, 44);
        expect(tester.getSize(find.byType(LibraryTreeItem).at(2)).height, 38);
        expect(
          tester.widget<ListView>(find.byType(ListView)).itemExtentBuilder,
          isNotNull,
        );
        final built = <String>{};
        final expectedMax = width == 450
            ? LibraryLikeCardMetrics.rootTileHeight + 44 + 38000 + 32 - 650
            : LibraryLikeCardMetrics.rootTileHeight + 333 * 38 + 32 - 650;
        final previous = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previous?.call(element, builtOnce);
          if (element.widget case LibraryTreeItem(:final node)) {
            built.add(node.path);
          }
        };
        try {
          scroll.jumpTo(width == 450 ? 35000 : expectedMax * 0.9);
          await tester.pump();
          debugPrint(
            'EXPANDED_LIBRARY_JUMP width=$width '
            'platform=$defaultTargetPlatform built=${built.length} total=1002',
          );
          expect(
            built.length,
            lessThan(width == 450 ? 30 : 70),
            reason: 'Built ${built.length} rows',
          );
          expect(built, isNot(contains('/expanded/child/500.mp3')));
          expect(tester.takeException(), isNull);
        } finally {
          debugOnRebuildDirtyWidget = previous;
        }
        // Flutter estimates the remaining extent until the last row lays out.
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(find.text('Track 999'), findsOneWidget);
        expect(scroll.position.maxScrollExtent, closeTo(expectedMax, 0.01));
        scroll.jumpTo(0);
        await tester.pumpAndSettle();
        final folderItem = tester.widget<LibraryTreeItem>(
          find.byWidgetPredicate(
            (widget) => widget is LibraryTreeItem && widget.node == child,
          ),
        );
        folderItem.onFolderExpansionChanged!(child, false);
        for (var attempt = 0; attempt < 1000; attempt++) {
          await tester.pump(const Duration(microseconds: 1));
          if (find
              .byWidgetPredicate(
                (widget) => widget is AnimatedTreeReveal && !widget.visible,
              )
              .evaluate()
              .isNotEmpty) {
            break;
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        expect(
          find.byWidgetPredicate(
            (widget) => widget is AnimatedTreeReveal && !widget.visible,
          ),
          findsWidgets,
        );
        // Keep the final projection pending after the collapse timer ends.
        // The old shrinking rows must retain their natural animation heights.
        final interaction = Object();
        UiInteractionCoordinator.instance.beginInteraction(interaction);
        try {
          await tester.pump(const Duration(seconds: 1));
          final list = tester.widget<ListView>(find.byType(ListView));
          expect(list.itemExtentBuilder, isNull);
          final trackItem = find.byWidgetPredicate(
            (widget) => widget is LibraryTreeItem && widget.node is TrackNode,
          );
          final reveal = find.ancestor(
            of: trackItem.first,
            matching: find.byType(AnimatedTreeReveal),
          );
          expect(tester.getSize(reveal.first).height, lessThan(38));
        } finally {
          UiInteractionCoordinator.instance.cancelInteraction(interaction);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }
}
