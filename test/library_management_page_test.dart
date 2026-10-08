import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/core/media/path_display.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/file_tree_row.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_edit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();
  setUp(UiInteractionCoordinator.instance.resetForTest);
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  const platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.windows,
  });
  const libraryPath =
      '/library/a very long parent directory/another long folder name/我的曲库';

  for (final textScale in [1.0, 2.0]) {
    testWidgets(
      'library management rows fit a name and two path lines at $textScale scale',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        fixture.library.addWatchedLibrary(libraryPath, notify: false);
        fixture.library.addWatchedLibrary('/library/short', notify: false);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 800);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          fixture.build(
            MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 800),
                textScaler: TextScaler.linear(textScale),
              ),
              child: const LibraryManagementPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final row = find.byType(FileTreeRow).first;
        final title = find.descendant(
          of: row,
          matching: find.text(PathDisplay.folderName(libraryPath)),
        );
        final subtitle = find.descendant(
          of: row,
          matching: find.text(PathDisplay.displayPathFor(libraryPath)),
        );
        expect(tester.widget<Text>(title).maxLines, 1);
        expect(tester.widget<Text>(subtitle).maxLines, 2);
        expect(tester.getSize(subtitle).height, greaterThan(20 * textScale));
        final rowRect = tester.getRect(row);
        final searchRect = tester.getRect(
          find.byKey(const ValueKey('library-management-search')),
        );
        expect(searchRect.left, rowRect.left);
        expect(searchRect.right, rowRect.right);
        expect(searchRect.bottom, lessThanOrEqualTo(rowRect.top));
        expect(rowRect.height, textScale == 1 ? 64 : greaterThan(64));
        expect(
          tester.getRect(subtitle).bottom,
          lessThanOrEqualTo(rowRect.bottom),
        );
        expect(
          tester.getSize(find.byType(FileTreeRow).last).height,
          rowRect.height,
        );
        expect(
          tester.getRect(find.byType(FileTreeRow).last).top,
          rowRect.bottom,
        );

        final surface = tester.widget<Material>(
          find.byKey(const ValueKey('library-management-surface:$libraryPath')),
        );
        expect(surface.color, Colors.transparent);
        expect(surface.borderRadius, FileTreeRow.borderRadius);
        expect(
          tester.widget<Icon>(find.byIcon(Icons.folder_rounded).first).color,
          AppDesignTokens.folderIconColor,
        );
        expect(find.byType(Card), findsNothing);
        expect(find.byType(ListTile), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: platforms,
    );
  }

  testWidgets(
    'library management search filters names and paths and clears the query',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      const windowsPath = r'E:\Audio Collection\Rain';
      const safPath =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic%2F%E4%B8%AD%E6%96%87';
      fixture.library.addWatchedLibrary(libraryPath, notify: false);
      fixture.library.addWatchedLibrary(windowsPath, notify: false);
      fixture.library.addWatchedLibrary(safPath, notify: false);
      await tester.pumpWidget(fixture.build(const LibraryManagementPage()));
      await tester.pumpAndSettle();
      final search = find.descendant(
        of: find.byType(TopPageHeader),
        matching: find.byType(TextField),
      );
      expect(search, findsOneWidget);
      expect(find.byType(FileTreeRow), findsNWidgets(3));

      for (final (query, expectedPath) in [
        ('  rAiN  ', windowsPath),
        ('AUDIO COLLECTION', windowsPath),
        ('我的曲库', libraryPath),
        ('中文', safPath),
      ]) {
        await tester.enterText(search, query);
        await tester.pump();
        expect(find.byType(FileTreeRow), findsOneWidget);
        expect(
          tester.widget<FileTreeRow>(find.byType(FileTreeRow)).subtitle,
          PathDisplay.displayPathFor(expectedPath),
        );
        final richTexts = tester.widgetList<RichText>(
          find.descendant(
            of: find.byType(FileTreeRow),
            matching: find.byType(RichText),
          ),
        );
        expect(
          richTexts.any((text) {
            var highlighted = false;
            text.text.visitChildren((span) {
              highlighted |= span.style?.fontWeight == FontWeight.w900;
              return true;
            });
            return highlighted;
          }),
          isTrue,
        );
      }
      await tester.enterText(search, 'does not exist');
      await tester.pump();
      expect(find.byType(FileTreeRow), findsNothing);
      expect(
        find.text(fixture.languageProvider.tr('no_search_results')),
        findsOneWidget,
      );
      await tester.tap(find.byIcon(Icons.clear_rounded));
      await tester.pump();
      expect(tester.widget<TextField>(search).controller!.text, isEmpty);
      expect(find.byType(FileTreeRow), findsNWidgets(3));
      await tester.enterText(search, '   ');
      await tester.pump();
      expect(find.byType(FileTreeRow), findsNWidgets(3));
      expect(fixture.library.watchedLibraries.length, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: platforms,
  );

  testWidgets(
    'library management rows navigate while delete and undo keep the page open',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      fixture.library.addWatchedLibrary(libraryPath, notify: false);
      await tester.pumpWidget(fixture.build(const LibraryManagementPage()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '我的曲库');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(fixture.undoableRemovalService.state.pendingCount, 1);
      expect(find.byType(FileTreeRow), findsNothing);
      expect(find.byType(LibraryEditPage), findsNothing);
      expect(find.byType(LibraryManagementPage), findsOneWidget);

      await tester.tap(
        find.textContaining(
          fixture.languageProvider.tr('undo'),
          findRichText: true,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(fixture.undoableRemovalService.state.pendingCount, 0);
      expect(find.byType(FileTreeRow), findsOneWidget);
      expect(fixture.library.watchedLibraries, [libraryPath]);

      await tester.tap(
        find.descendant(
          of: find.byType(FileTreeRow),
          matching: find.text(
            PathDisplay.folderName(libraryPath),
            findRichText: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(LibraryEditPage), findsOneWidget);
      expect(
        tester
            .widget<LibraryEditPage>(find.byType(LibraryEditPage))
            .libraryPath,
        libraryPath,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: platforms,
  );
}
