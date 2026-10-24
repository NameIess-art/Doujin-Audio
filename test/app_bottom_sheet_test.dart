import 'dart:async';

import 'package:doujin_audio/core/widgets/app_bottom_sheet.dart';
import 'package:doujin_audio/core/widgets/drag_only_scrollbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'sheet fades in but slides out without fading',
    (tester) async {
      late BuildContext pageContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                pageContext = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      unawaited(
        AppBottomSheet.show<void>(
          context: pageContext,
          builder: (_) =>
              const SizedBox(height: 120, child: Text('Sheet content')),
        ),
      );
      double opacity() => tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.byType(BottomSheet),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;
      await tester.pump();
      expect(opacity(), 0);
      await tester.pump(const Duration(milliseconds: 150));
      expect(opacity(), inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 150));
      expect(opacity(), 1);
      final settledTop = tester.getTopLeft(find.byType(BottomSheet)).dy;
      Navigator.of(pageContext).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(opacity(), 1);
      expect(
        tester.getTopLeft(find.byType(BottomSheet)).dy,
        greaterThan(settledTop),
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(opacity(), 1);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'dragging a sheet down keeps it opaque through dismissal',
    (tester) async {
      late BuildContext pageContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                pageContext = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      unawaited(
        AppBottomSheet.show<void>(
          context: pageContext,
          builder: (_) =>
              const SizedBox(height: 200, child: Text('Drag content')),
        ),
      );
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet);
      double opacity() => tester
          .widget<Opacity>(
            find.ancestor(of: sheet, matching: find.byType(Opacity)).first,
          )
          .opacity;
      final settledTop = tester.getTopLeft(sheet).dy;
      final gesture = await tester.startGesture(tester.getCenter(sheet));
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getTopLeft(sheet).dy, greaterThan(settledTop));
      expect(opacity(), 1);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(sheet, findsOneWidget);
      expect(opacity(), 1);
      expect(tester.getTopLeft(sheet).dy, closeTo(settledTop, 0.01));
      await tester.drag(sheet, const Offset(0, 180));
      await tester.pump();
      expect(opacity(), 1);
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('closing during entrance holds the reached sheet opacity', (
    tester,
  ) async {
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              pageContext = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    unawaited(
      AppBottomSheet.show<void>(
        context: pageContext,
        builder: (_) =>
            const SizedBox(height: 200, child: Text('Early close content')),
      ),
    );
    final sheet = find.byType(BottomSheet);
    double opacity() => tester
        .widget<Opacity>(
          find.ancestor(of: sheet, matching: find.byType(Opacity)).first,
        )
        .opacity;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final reachedOpacity = opacity();
    expect(reachedOpacity, inExclusiveRange(0, 1));
    Navigator.of(pageContext).pop();
    await tester.pump();
    expect(opacity(), reachedOpacity);
    await tester.pump(const Duration(milliseconds: 75));
    expect(opacity(), reachedOpacity);
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
  });

  testWidgets('sheet header wraps large text beside its icon and action', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: SizedBox(
              width: 320,
              child: AppBottomSheetHeader(
                icon: Icons.subtitles_rounded,
                title: 'Subtitle settings and script selection',
                trailing: Icon(Icons.arrow_back_rounded),
              ),
            ),
          ),
        ),
      ),
    );
    final title = find.text('Subtitle settings and script selection');
    expect(tester.getSize(title).height, greaterThan(44));
    expect(
      tester.getRect(find.byIcon(Icons.subtitles_rounded)).right,
      lessThan(tester.getRect(title).left),
    );
    expect(
      tester.getRect(title).right,
      lessThan(tester.getRect(find.byIcon(Icons.arrow_back_rounded)).left),
    );
    expect(tester.takeException(), isNull);
  });

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
