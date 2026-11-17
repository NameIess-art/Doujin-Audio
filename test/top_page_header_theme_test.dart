import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';

Widget _buildThemedApp({required Widget child, ThemeData? theme}) {
  return ProviderScope(
    child: MaterialApp(
      theme: theme ?? ThemeData.light(),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('title capsules use larger text and icons within their row height', (
    tester,
  ) async {
    for (final topCapsule in [false, true]) {
      for (final icon in [
        Icons.playlist_play_rounded,
        Icons.cloud_rounded,
        Icons.description_rounded,
      ]) {
        await tester.pumpWidget(
          _buildThemedApp(
            child: SizedBox(
              width: 320,
              child: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: TopPageHeader(
                  icon: icon,
                  title: topCapsule ? 'Actions' : 'Playlist',
                  topCapsuleTitle: topCapsule ? 'Playlist' : null,
                  topCapsuleData: '12 selected',
                  useSafeAreaTop: false,
                ),
              ),
            ),
          ),
        );
        final iconFinder = topCapsule
            ? find.descendant(
                of: find.byType(HeaderTopCapsule),
                matching: find.byIcon(icon),
              )
            : find.byIcon(icon);
        final size = tester.widget<Icon>(iconFinder).size;
        expect(
          size,
          closeTo(
            icon == Icons.playlist_play_rounded ? 22 * 1.15 : 22,
            0.001,
          ),
        );
        expect(tester.widget<Text>(find.text('Playlist')).style!.fontSize, 16);
        if (topCapsule) {
          expect(
            tester.widget<Text>(find.text('12 selected')).style!.fontSize,
            13,
          );
        }
        expect(
          tester.getSize(find.byType(TopPageHeader)).height,
          topCapsule ? 88 : 44,
        );
        expect(tester.takeException(), isNull);
      }
    }
  }, variant: const TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.windows,
  }));

  group('TopPageHeader and HeaderSegmentedCategoryBar theme & accent tests', () {
    testWidgets('TopPageHeader uses custom iconColor when provided', (
      tester,
    ) async {
      const customColor = Colors.deepPurple;
      await tester.pumpWidget(
        _buildThemedApp(
          child: const TopPageHeader(
            icon: Icons.cloud_rounded,
            iconColor: customColor,
            title: 'ASMR.ONE',
            useSafeAreaTop: false,
          ),
        ),
      );

      final iconFinder = find.byIcon(Icons.cloud_rounded);
      expect(iconFinder, findsOneWidget);
      final iconWidget = tester.widget<Icon>(iconFinder);
      expect(iconWidget.color, customColor);
    });

    testWidgets('TopPageHeader top capsule uses custom iconColor', (
      tester,
    ) async {
      const customColor = Colors.teal;
      await tester.pumpWidget(
        _buildThemedApp(
          child: const TopPageHeader(
            icon: Icons.cloud_rounded,
            iconColor: customColor,
            topCapsuleTitle: 'Top Title',
            useSafeAreaTop: false,
          ),
        ),
      );

      final iconFinder = find.byIcon(Icons.cloud_rounded);
      expect(iconFinder, findsOneWidget);
      final iconWidget = tester.widget<Icon>(iconFinder);
      expect(iconWidget.color, customColor);
    });

    testWidgets('TopPageHeader defaults iconColor to Theme primary', (
      tester,
    ) async {
      const primaryColor = Colors.amber;
      final theme = ThemeData.light().copyWith(
        colorScheme: const ColorScheme.light(primary: primaryColor),
      );

      await tester.pumpWidget(
        _buildThemedApp(
          theme: theme,
          child: const TopPageHeader(
            icon: Icons.cloud_rounded,
            title: 'ASMR.ONE',
            useSafeAreaTop: false,
          ),
        ),
      );

      final iconFinder = find.byIcon(Icons.cloud_rounded);
      expect(iconFinder, findsOneWidget);
      final iconWidget = tester.widget<Icon>(iconFinder);
      expect(iconWidget.color, primaryColor);
    });

    testWidgets(
      'HeaderSegmentedCategoryBar matches search category capsule sizing',
      (tester) async {
        const customAccent = Color(0xFF1D4ED8);
        int selectedIndex = 0;

        await tester.pumpWidget(
          _buildThemedApp(
            child: StatefulBuilder(
              builder: (context, setState) {
                return HeaderSegmentedCategoryBar<int>(
                  items: const [0, 1, 2],
                  selected: selectedIndex,
                  onSelected: (val) => setState(() => selectedIndex = val),
                  labelBuilder: (item) => 'Tab $item',
                  accentColor: customAccent,
                );
              },
            ),
          ),
        );

        // Check selected tab label color
        final textFinder = find.text('Tab 0');
        expect(textFinder, findsOneWidget);
        final textWidget = tester
            .widget<RichText>(
              find.descendant(of: textFinder, matching: find.byType(RichText)),
            )
            .text;
        expect(textWidget.style?.color, customAccent);
        expect(textWidget.style?.fontSize, 12.5);
        expect(textWidget.style?.fontWeight, FontWeight.w700);

        // Check sliding indicator paints the accent capsule around the active tab
        final indicatorFinder = find.byKey(
          const ValueKey<String>('header_category_indicator'),
        );
        final indicatorPaint = tester.widget<CustomPaint>(indicatorFinder);
        final canvas = TestRecordingCanvas();
        indicatorPaint.painter!.paint(canvas, tester.getSize(indicatorFinder));
        final drawCall = canvas.invocations.singleWhere(
          (call) => call.invocation.memberName == #drawRRect,
        );
        final indicatorRRect =
            drawCall.invocation.positionalArguments[0] as RRect;
        final indicatorPaintArg =
            drawCall.invocation.positionalArguments[1] as Paint;
        expect(
          indicatorPaintArg.color,
          isSameColorAs(customAccent.withValues(alpha: 0.19)),
        );
        expect(
          indicatorRRect.blRadius,
          Radius.circular(indicatorRRect.shortestSide / 2),
        );

        final materialFinder = find.ancestor(
          of: textFinder,
          matching: find.byType(Material),
        );
        expect(tester.getSize(materialFinder.first).height, 32);
        expect(
          indicatorRRect.width,
          closeTo(tester.getSize(materialFinder.first).width, 0.01),
        );
        final nextMaterial = find.ancestor(
          of: find.text('Tab 1'),
          matching: find.byType(Material),
        );
        expect(
          tester.getTopLeft(nextMaterial.first).dx -
              tester.getTopRight(materialFinder.first).dx,
          2,
        );
        expect(
          DefaultTextStyle.of(
            tester.element(find.text('Tab 1')),
          ).style.fontWeight,
          FontWeight.w600,
        );
      },
    );

    testWidgets(
      'HeaderSegmentedCategoryBar slides capsule between categories like bottom navigation',
      (tester) async {
        const customAccent = Color(0xFF1D4ED8);
        var selectedIndex = 0;
        StateSetter? updateSelection;

        RRect? readIndicatorRRect() {
          final finder = find.byKey(
            const ValueKey<String>('header_category_indicator'),
          );
          final paint = tester.widget<CustomPaint>(finder);
          final canvas = TestRecordingCanvas();
          paint.painter!.paint(canvas, tester.getSize(finder));
          final calls = canvas.invocations
              .where((call) => call.invocation.memberName == #drawRRect)
              .toList(growable: false);
          if (calls.isEmpty) return null;
          return calls.single.invocation.positionalArguments.first as RRect;
        }

        double tabRelativeCenterX(String label) {
          final indicatorTopLeft = tester.getTopLeft(
            find.byKey(const ValueKey<String>('header_category_indicator')),
          );
          final pill = find
              .ancestor(of: find.text(label), matching: find.byType(Material))
              .first;
          return tester.getCenter(pill).dx - indicatorTopLeft.dx;
        }

        await tester.pumpWidget(
          _buildThemedApp(
            child: StatefulBuilder(
              builder: (context, setState) {
                updateSelection = setState;
                return HeaderSegmentedCategoryBar<int>(
                  items: const [0, 1, 2],
                  selected: selectedIndex,
                  onSelected: (val) => setState(() => selectedIndex = val),
                  labelBuilder: (item) =>
                      item == 2 ? 'Longer Tab 2' : 'Tab $item',
                  accentColor: customAccent,
                );
              },
            ),
          ),
        );

        final startCenter = tabRelativeCenterX('Tab 0');
        final endCenter = tabRelativeCenterX('Longer Tab 2');
        final startWidth = tester
            .getSize(
              find
                  .ancestor(
                    of: find.text('Tab 0'),
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .width;
        final endWidth = tester
            .getSize(
              find
                  .ancestor(
                    of: find.text('Longer Tab 2'),
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .width;
        expect(readIndicatorRRect()!.center.dx, closeTo(startCenter, 0.01));
        expect(readIndicatorRRect()!.width, closeTo(startWidth, 0.01));

        await tester.tap(find.text('Longer Tab 2'));
        await tester.pump();
        expect(readIndicatorRRect()!.center.dx, closeTo(startCenter, 0.01));

        await tester.pump(const Duration(milliseconds: 60));
        final midRRect = readIndicatorRRect()!;
        expect(midRRect.center.dx, inExclusiveRange(startCenter, endCenter));
        expect(midRRect.width, inExclusiveRange(startWidth, endWidth));

        await tester.pump(const Duration(milliseconds: 160));
        final endRRect = readIndicatorRRect()!;
        expect(endRRect.center.dx, closeTo(endCenter, 0.01));
        expect(endRRect.width, closeTo(endWidth, 0.01));
        expect(
          DefaultTextStyle.of(
            tester.element(find.text('Longer Tab 2')),
          ).style.color,
          customAccent,
        );

        // Reduced motion completes the capsule transition immediately.
        await tester.pumpWidget(
          _buildThemedApp(
            child: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: StatefulBuilder(
                builder: (context, setState) {
                  updateSelection = setState;
                  return HeaderSegmentedCategoryBar<int>(
                    items: const [0, 1, 2],
                    selected: selectedIndex,
                    onSelected: (val) => setState(() => selectedIndex = val),
                    labelBuilder: (item) =>
                        item == 2 ? 'Longer Tab 2' : 'Tab $item',
                    accentColor: customAccent,
                  );
                },
              ),
            ),
          ),
        );
        updateSelection!(() => selectedIndex = 0);
        await tester.pump();
        expect(readIndicatorRRect()!.center.dx, closeTo(startCenter, 0.01));
      },
    );

    testWidgets(
      'HeaderSegmentedCategoryBar highlights hovered Windows tab and suppresses pointer ink',
      (tester) async {
        const customAccent = Color(0xFF1D4ED8);
        await tester.pumpWidget(
          _buildThemedApp(
            theme: ThemeData.light().copyWith(platform: TargetPlatform.windows),
            child: HeaderSegmentedCategoryBar<int>(
              items: const [0, 1],
              selected: 0,
              onSelected: (_) {},
              labelBuilder: (item) => 'Tab $item',
              accentColor: customAccent,
            ),
          ),
        );

        final restColor = DefaultTextStyle.of(
          tester.element(find.text('Tab 1')),
        ).style.color;
        expect(restColor, isNot(equals(customAccent)));

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(find.text('Tab 1')));
        await tester.pumpAndSettle();

        expect(
          DefaultTextStyle.of(tester.element(find.text('Tab 1'))).style.color,
          customAccent,
        );
        final ink = tester.widget<InkWell>(
          find.ancestor(of: find.text('Tab 1'), matching: find.byType(InkWell)),
        );
        expect(ink.splashFactory, NoSplash.splashFactory);
        expect(ink.hoverColor, Colors.transparent);
        expect(ink.highlightColor, Colors.transparent);

        await mouse.moveTo(const Offset(500, 500));
        await tester.pumpAndSettle();
        expect(
          DefaultTextStyle.of(tester.element(find.text('Tab 1'))).style.color,
          restColor,
        );
      },
    );

    testWidgets('category pills scroll inside search-sized outer capsule', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildThemedApp(
          child: Center(
            child: SizedBox(
              width: 180,
              child: HeaderSegmentedCategoryBar<int>(
                items: const [0, 1, 2, 3, 4],
                selected: 0,
                onSelected: (_) {},
                labelBuilder: (item) => 'Category $item',
              ),
            ),
          ),
        ),
      );

      final viewport = find.byType(SingleChildScrollView);
      final clips = find.descendant(
        of: find.byType(HeaderSegmentedCategoryBar<int>),
        matching: find.byType(ClipRRect),
      );
      expect(clips, findsOneWidget);
      expect(
        tester.widget<ClipRRect>(clips).borderRadius,
        BorderRadius.circular(19),
      );
      expect(tester.getSize(clips).height, 38);
      expect(
        (tester.widget<SingleChildScrollView>(viewport).child as Padding)
            .padding,
        const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
      );
      final firstPill = find
          .ancestor(
            of: find.text('Category 0'),
            matching: find.byType(Material),
          )
          .first;
      expect(tester.getTopLeft(firstPill).dx - tester.getTopLeft(clips).dx, 4);
      expect(tester.getTopLeft(firstPill).dy - tester.getTopLeft(clips).dy, 3);

      final scrollable = tester.widget<SingleChildScrollView>(viewport);
      expect(scrollable.physics, isA<ClampingScrollPhysics>());
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      expect(position.maxScrollExtent, greaterThan(0));
      final fullDragDistance =
          position.maxScrollExtent + tester.getSize(viewport).width;

      // Drag left to reach the right end (max extent)
      await tester.drag(viewport, Offset(-fullDragDistance, 0));
      await tester.pumpAndSettle();
      expect(position.pixels, position.maxScrollExtent);

      // Attempting to drag further left at the rightmost end should clamp with no extra slack
      await tester.drag(viewport, const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(position.pixels, position.maxScrollExtent);

      // Drag right to reach the leftmost end (0)
      await tester.drag(viewport, Offset(fullDragDistance, 0));
      await tester.pumpAndSettle();
      expect(position.pixels, 0);

      // Attempting to drag further right at the leftmost end should clamp with no extra slack
      await tester.drag(viewport, const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(position.pixels, 0);
    });

    testWidgets('online library header inherits the application theme', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildThemedApp(
          child: Builder(
            builder: (context) {
              return TopPageHeader(
                icon: Icons.cloud_rounded,
                iconColor: Theme.of(context).colorScheme.primary,
                title: 'ASMR.ONE',
                useSafeAreaTop: false,
              );
            },
          ),
        ),
      );

      final iconFinder = find.byIcon(Icons.cloud_rounded);
      final iconWidget = tester.widget<Icon>(iconFinder);
      final scheme = Theme.of(tester.element(iconFinder)).colorScheme;
      expect(iconWidget.color, scheme.primary);
    });
  });
}
