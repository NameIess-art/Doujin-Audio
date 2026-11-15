import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/app_entry_ink_well.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('entry clears press ink before navigation on $platform', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      const entryKey = ValueKey('entry');
      late BuildContext entryContext;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: ThemeData(
            platform: platform,
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: AppPageTransitionsBuilder(),
                TargetPlatform.windows: AppPageTransitionsBuilder(),
              },
            ),
          ),
          home: Scaffold(
            body: Center(
              child: Material(
                child: Builder(
                  builder: (context) {
                    entryContext = context;
                    return AppEntryInkWell(
                      key: entryKey,
                      canRequestFocus: false,
                      onTap: () => Navigator.of(context).push<void>(
                        buildAppPageRoute<void>(
                          context: context,
                          child: const Scaffold(body: Text('detail')),
                        ),
                      ),
                      child: const SizedBox(width: 240, height: 80),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Iterable<InteractiveInkFeature> visibleInk() {
        final dynamic controller = Material.of(entryContext);
        final features = controller.debugInkFeatures as List<InkFeature>?;
        return (features ?? <InkFeature>[])
            .whereType<InteractiveInkFeature>()
            .where((feature) => feature.color.a > 0);
      }

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(entryKey)),
        kind: platform == TargetPlatform.windows
            ? PointerDeviceKind.mouse
            : PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 120));
      expect(visibleInk(), isNotEmpty);
      await gesture.up();
      expect(visibleInk().where((ink) => ink is! InkHighlight), isEmpty);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(visibleInk(), isEmpty);
      await tester.pumpAndSettle();

      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(visibleInk(), isEmpty);
      await tester.pumpAndSettle();
      expect(find.byKey(entryKey), findsOneWidget);
      expect(visibleInk().where((ink) => ink is! InkHighlight), isEmpty);
      if (platform == TargetPlatform.windows) {
        // A stationary mouse can legitimately hover the restored entry.
        await gesture.moveTo(Offset.zero);
        await tester.pump();
      }
      expect(visibleInk(), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('entry preserves long press and cancellation on $platform', (
      tester,
    ) async {
      var taps = 0;
      var longPresses = 0;
      late BuildContext entryContext;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: Center(
              child: Material(
                child: Builder(
                  builder: (context) {
                    entryContext = context;
                    return AppEntryInkWell(
                      onTap: () => taps++,
                      onLongPress: () => longPresses++,
                      child: const SizedBox(width: 240, height: 80),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      final entry = find.byType(AppEntryInkWell);
      Iterable<InteractiveInkFeature> splashes() {
        final dynamic controller = Material.of(entryContext);
        final features = controller.debugInkFeatures as List<InkFeature>?;
        return (features ?? <InkFeature>[])
            .whereType<InteractiveInkFeature>()
            .where((feature) => feature.color.a > 0);
      }

      final cancelled = await tester.startGesture(tester.getCenter(entry));
      await tester.pump(const Duration(milliseconds: 120));
      expect(splashes(), isNotEmpty);
      await cancelled.cancel();
      expect(splashes(), isEmpty);
      expect(taps, 0);

      final held = await tester.startGesture(tester.getCenter(entry));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
      expect(longPresses, 1);
      expect(splashes(), isEmpty);
      await held.up();
      expect(taps, 0);
      await tester.tap(entry);
      expect(taps, 1);
      if (platform == TargetPlatform.android) {
        await tester.pump();
        expect(splashes(), hasLength(1));
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(splashes(), isEmpty);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('starting a scroll clears the pressed row without opening it', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final row = find.byKey(const ValueKey('scrolling-entry'));
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: Material(
            child: ListView(
              controller: scroll,
              children: [
                AppEntryInkWell(
                  key: const ValueKey('scrolling-entry'),
                  onTap: () => taps++,
                  child: const SizedBox(height: 160),
                ),
                const SizedBox(height: 1200),
              ],
            ),
          ),
        ),
      ),
    );
    final dynamic ink = Material.of(tester.element(row));
    Iterable<InteractiveInkFeature> visibleInk() =>
        ((ink.debugInkFeatures as List<InkFeature>?) ?? [])
            .whereType<InteractiveInkFeature>()
            .where((feature) => feature.color.a > 0);
    final gesture = await tester.startGesture(tester.getCenter(row));
    await tester.pump(const Duration(milliseconds: 120));
    expect(visibleInk(), isNotEmpty);
    await gesture.moveBy(const Offset(0, -30));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    expect(scroll.offset, greaterThan(0));
    expect(visibleInk(), isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(taps, 0);
  });
}
