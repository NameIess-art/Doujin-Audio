import 'dart:typed_data';

import 'package:doujin_audio/core/widgets/app_glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'disabled glass paints the supplied color without a backdrop filter',
    (tester) async {
      const tint = Color(0x80336699);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: AppGlassSurface(
              enabled: false,
              backgroundColor: tint,
              borderRadius: BorderRadius.circular(12),
              child: const SizedBox(width: 120, height: 60),
            ),
          ),
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
      expect(
        tester
            .widget<ColoredBox>(
              find.descendant(
                of: find.byType(AppGlassSurface),
                matching: find.byType(ColoredBox),
              ),
            )
            .color,
        tint,
      );
      expect(tester.getSize(find.byType(ClipRRect)), const Size(120, 60));
    },
  );

  testWidgets('disjoint grouped glass matches independent glass during fades', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    Widget scene({required bool grouped, required double opacity}) {
      final row = Row(
        children: [
          const SizedBox(width: 10),
          for (var i = 0; i < 2; i++) ...[
            AppGlassSurface(
              backgroundColor: i == 0 ? Colors.white : Colors.black,
              borderRadius: BorderRadius.circular(12),
              child: const SizedBox(width: 80, height: 40),
            ),
            const SizedBox(width: 8),
          ],
        ],
      );
      return MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: SizedBox(
              width: 200,
              height: 60,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: List.generate(
                        20,
                        (i) => Expanded(
                          child: ColoredBox(
                            color: i.isEven ? Colors.black : Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: Opacity(
                      opacity: opacity,
                      child: grouped ? BackdropGroup(child: row) : row,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    Future<ByteData?> capture() => tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage();
      try {
        return (await image.toByteData())!;
      } finally {
        image.dispose();
      }
    });
    for (final opacity in [1.0, 0.5]) {
      await tester.pumpWidget(scene(grouped: false, opacity: opacity));
      final independent = (await capture())!;
      await tester.pumpWidget(scene(grouped: true, opacity: opacity));
      final grouped = (await capture())!;
      expect(grouped.lengthInBytes, independent.lengthInBytes);
      for (var i = 0; i < independent.lengthInBytes; i++) {
        expect(
          grouped.getUint8(i),
          closeTo(independent.getUint8(i), 2),
          reason: 'Opacity $opacity, byte $i',
        );
      }
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets('glass respects input alpha in $brightness theme', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Center(
            child: AppGlassSurface(
              backgroundColor: Colors.blue.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
              child: const SizedBox(width: 120, height: 60),
            ),
          ),
        ),
      );
      final surface = find.byType(AppGlassSurface);
      final color = tester
          .widget<ColoredBox>(
            find.descendant(of: surface, matching: find.byType(ColoredBox)),
          )
          .color;
      expect(
        color.a,
        closeTo(brightness == Brightness.dark ? 0.42 : 0.4, 1e-6),
      );
      final clip = find.descendant(
        of: surface,
        matching: find.byType(ClipRRect),
      );
      expect(tester.getSize(clip), const Size(120, 60));
      expect(
        tester.widget<ClipRRect>(clip).borderRadius,
        BorderRadius.circular(12),
      );
      expect(
        find.descendant(of: surface, matching: find.byType(BackdropFilter)),
        findsOneWidget,
      );
    });
  }

  testWidgets(
    'transparent glass disables blur and hidden glass paints no filter',
    (tester) async {
      Widget build({Color color = Colors.transparent, double opacity = 1}) =>
          MaterialApp(
            home: Center(
              child: Opacity(
                opacity: opacity,
                child: AppGlassSurface(
                  backgroundColor: color,
                  child: const SizedBox(width: 120, height: 60),
                ),
              ),
            ),
          );
      await tester.pumpWidget(build());
      expect(
        tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
        isFalse,
      );
      expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
      await tester.pumpWidget(build(color: Colors.white, opacity: 0));
      expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
      await tester.pumpWidget(build(color: Colors.white));
      expect(tester.layers.whereType<BackdropFilterLayer>(), hasLength(1));
    },
  );

  testWidgets('only the clipped backdrop blurs while foreground stays sharp', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final opacity = ValueNotifier(1.0);
    addTearDown(opacity.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: SizedBox(
              width: 200,
              height: 100,
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: ColoredBox(color: Colors.black)),
                        Expanded(child: ColoredBox(color: Colors.white)),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 40,
                    top: 20,
                    child: ValueListenableBuilder<double>(
                      valueListenable: opacity,
                      builder: (context, value, child) =>
                          Opacity(opacity: value, child: child),
                      child: AppGlassSurface(
                        backgroundColor: Colors.black.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        child: const SizedBox(
                          width: 120,
                          height: 60,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: EdgeInsets.only(left: 20),
                              child: SizedBox(
                                width: 12,
                                height: 12,
                                child: ColoredBox(color: Color(0xFFFF0000)),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    Future<ByteData?> capture() => tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        return (await image.toByteData())!;
      } finally {
        image.dispose();
      }
    });
    var pixels = await capture();
    int channel(int x, int y, int channel) =>
        pixels!.getUint8((y * 200 + x) * 4 + channel);
    expect(channel(99, 10, 0), 0);
    expect(channel(100, 10, 0), 255);
    expect(
      channel(41, 21, 0),
      0,
      reason: 'Rounded corner stays outside glass.',
    );
    expect(channel(99, 50, 0), inExclusiveRange(10, 230));
    expect(channel(100, 50, 0), inExclusiveRange(10, 230));
    expect(channel(66, 50, 0), 255);
    expect(channel(66, 50, 1), 0);
    expect(channel(66, 50, 2), 0);
    final leftBlur = channel(99, 50, 0);
    final rightBlur = channel(100, 50, 0);
    opacity.value = 0.5;
    await tester.pump();
    pixels = await capture();
    expect(channel(99, 50, 0), closeTo(leftBlur * 0.5, 2));
    expect(channel(100, 50, 0), closeTo(rightBlur * 0.5 + 255 * 0.5, 2));
    expect(channel(66, 50, 0), closeTo(255 * 0.5, 2));
  });
}
