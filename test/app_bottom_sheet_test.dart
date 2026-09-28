import 'package:doujin_audio/core/widgets/app_bottom_sheet.dart';
import 'package:doujin_audio/core/widgets/drag_only_scrollbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      '$platform bottom sheet hides scrollbar and remains scrollable',
      (tester) async {
        final sheetController = ScrollController();
        addTearDown(sheetController.dispose);

        await tester.pumpWidget(
          MaterialApp(
            scrollBehavior: const AppScrollBehavior().copyWith(
              scrollbars: true,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => ListView.builder(
                  itemCount: 30,
                  itemExtent: 48,
                  itemBuilder: (_, index) => index == 0
                      ? TextButton(
                          onPressed: () => AppBottomSheet.show<void>(
                            context: context,
                            builder: (_) => ListView.builder(
                              controller: sheetController,
                              itemCount: 50,
                              itemExtent: 48,
                              itemBuilder: (_, item) =>
                                  Text('Sheet item $item'),
                            ),
                          ),
                          child: const Text('Open'),
                        )
                      : Text('Page item $index'),
                ),
              ),
            ),
          ),
        );
        expect(find.byType(DragOnlyScrollbar), findsOneWidget);

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        final sheet = find.byType(BottomSheet);
        expect(
          find.descendant(of: sheet, matching: find.byType(DragOnlyScrollbar)),
          findsNothing,
        );
        expect(find.byType(DragOnlyScrollbar), findsOneWidget);

        await tester.drag(
          find.descendant(of: sheet, matching: find.byType(ListView)),
          const Offset(0, -250),
        );
        await tester.pumpAndSettle();
        expect(sheetController.offset, greaterThan(0));
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final windowWidth in [960.0, 1280.0, 1920.0]) {
      testWidgets(
        '$platform sheet width in a $windowWidth window',
        (tester) async {
          tester.view.physicalSize = Size(windowWidth, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => AppBottomSheet.show<void>(
                      context: context,
                      builder: (_) =>
                          const SizedBox(width: double.infinity, height: 120),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();

          final material = find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Material),
          );
          final rect = tester.getRect(material.first);
          final expectedWidth = windowWidth * 0.5;
          expect(rect.width, expectedWidth);
          expect(rect.center.dx, windowWidth / 2);
          expect(rect.bottom, 800);
          expect(tester.takeException(), isNull);

          if (platform == TargetPlatform.windows) {
            for (final resizedWidth in [960.0, 1920.0]) {
              tester.view.physicalSize = Size(resizedWidth, 800);
              await tester.pumpAndSettle();
              final resizedRect = tester.getRect(material.first);
              expect(resizedRect.width, resizedWidth / 2);
              expect(resizedRect.center.dx, resizedWidth / 2);
              expect(resizedRect.bottom, 800);
              expect(tester.takeException(), isNull);
            }
            await tester.tapAt(const Offset(20, 780));
            await tester.pumpAndSettle();
            expect(find.byType(BottomSheet), findsNothing);
          }
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }
  }

  testWidgets(
    'Android portrait sheet keeps the full page width',
    (tester) async {
      tester.view.physicalSize = const Size(800, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => AppBottomSheet.show<void>(
                  context: context,
                  builder: (_) =>
                      const SizedBox(width: double.infinity, height: 120),
                ),
                child: const Text('Open portrait'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open portrait'));
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(BottomSheet)).width, 800);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
