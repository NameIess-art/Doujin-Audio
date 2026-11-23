import 'dart:async';

import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/shimmer_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'opening a skeleton route preserves its colors as shimmer starts',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      const skeletonKey = ValueKey('route-skeleton');
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          theme: ThemeData(
            colorScheme: const ColorScheme.light(
              surfaceContainerHighest: Color(0xFF808080),
              surfaceContainer: Color(0xFFF0F0F0),
            ),
          ),
          home: const SizedBox.shrink(),
        ),
      );
      final route = buildAppPageRoute<void>(
        context: navigatorKey.currentContext!,
        child: const Scaffold(
          body: Center(
            child: SizedBox(
              width: 160,
              height: 80,
              child: RepaintBoundary(
                key: skeletonKey,
                child: ShimmerLoader(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: ColoredBox(color: Color(0xFF303030))),
                      Expanded(child: ColoredBox(color: Color(0xFF606060))),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      unawaited(navigatorKey.currentState!.push(route));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      Future<List<int>> sample() =>
          _sampleRedChannels(tester, skeletonKey, [0.25, 0.5, 0.75]);

      final shimmerMaskFinder = find.byWidgetPredicate(
        (widget) => widget is ShaderMask,
      );
      expect(shimmerMaskFinder, findsNothing);
      final duringEntrance = await sample();
      expect(duringEntrance, [0x30, 0x60, 0x60]);

      await tester.pump(
        kAppPagePushDuration - const Duration(milliseconds: 99),
      );
      expect(shimmerMaskFinder, findsOneWidget);
      expect(await sample(), duringEntrance);
      await tester.pump(const Duration(milliseconds: 16));
      expect(await sample(), duringEntrance);

      await tester.pump(const Duration(milliseconds: 700));
      expect(await sample(), [0x30, greaterThan(220), 0x60]);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  for (final (platform, size) in [
    (TargetPlatform.android, const Size(64, 160)),
    (TargetPlatform.windows, const Size(160, 64)),
  ]) {
    testWidgets('shimmer sweeps smoothly across the loop on $platform', (
      tester,
    ) async {
      const baseColor = Color(0xFF303030);
      const highlightColor = Color(0xFFF0F0F0);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            platform: platform,
            colorScheme: const ColorScheme.light(
              surfaceContainer: highlightColor,
              surfaceContainerHighest: baseColor,
            ),
          ),
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: ShimmerLoader(
                child: ShimmerContainer(
                  width: size.width,
                  height: size.height,
                  borderRadius: 0,
                ),
              ),
            ),
          ),
        ),
      );

      Future<List<int>> sampleFrame(Duration elapsed) async {
        await tester.pump(elapsed);
        return _sampleRedChannels(tester, key, [0, 0.175, 0.825, 1]);
      }

      const baseRed = 0x30;
      final firstSweep = await sampleFrame(const Duration(milliseconds: 350));
      final endOfSweep = await sampleFrame(const Duration(milliseconds: 700));
      final beforeReset = await sampleFrame(const Duration(milliseconds: 342));
      final afterReset = await sampleFrame(const Duration(milliseconds: 16));
      expect(beforeReset, List.filled(4, closeTo(baseRed, 8)));
      expect(afterReset, List.filled(4, closeTo(baseRed, 8)));
      expect(firstSweep, [baseRed, greaterThan(220), baseRed, baseRed]);
      expect(endOfSweep, [baseRed, baseRed, greaterThan(220), baseRed]);
      expect(await sampleFrame(const Duration(milliseconds: 342)), firstSweep);
    });
  }
}

Future<List<int>> _sampleRedChannels(
  WidgetTester tester,
  Key key,
  List<double> fractions,
) async => (await tester.runAsync(() async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  final image = await boundary.toImage();
  try {
    final pixels = (await image.toByteData())!;
    final redChannels = <int>[];
    for (final fraction in fractions) {
      final x = ((image.width - 1) * fraction).round();
      final y = ((image.height - 1) * fraction).round();
      redChannels.add(pixels.getUint8(4 * (y * image.width + x)));
    }
    return redChannels;
  } finally {
    image.dispose();
  }
}))!;
