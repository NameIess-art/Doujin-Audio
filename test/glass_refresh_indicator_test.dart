import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/glass_refresh_indicator.dart';

void main() {
  testWidgets('pull-to-refresh indicator has no shadow decoration', (
    tester,
  ) async {
    final refresh = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassRefreshIndicator(
            onRefresh: () => refresh.future,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [SizedBox(height: 800)],
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();

    final indicator = find.byType(RefreshProgressIndicator);
    expect(indicator, findsOneWidget);
    final decoratedAncestors = tester.widgetList<DecoratedBox>(
      find.ancestor(of: indicator, matching: find.byType(DecoratedBox)),
    );
    expect(
      decoratedAncestors.where((widget) {
        final decoration = widget.decoration;
        return decoration is BoxDecoration &&
            (decoration.boxShadow?.isNotEmpty ?? false);
      }),
      isEmpty,
    );

    refresh.complete();
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets(
    'pull-to-refresh indicator stays strictly at or below edgeOffset and fades in during drag',
    (tester) async {
      final refresh = Completer<void>();
      const edgeOffset = 100.0;
      const displacement = 32.0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GlassRefreshIndicator(
              edgeOffset: edgeOffset,
              displacement: displacement,
              onRefresh: () => refresh.future,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [SizedBox(height: 800)],
              ),
            ),
          ),
        ),
      );

      final gesture = await tester.startGesture(const Offset(200, 200));
      // Drag down slightly
      await gesture.moveBy(const Offset(0, 50));
      await tester.pump();

      final indicatorFinder = find.byType(RefreshProgressIndicator);
      expect(indicatorFinder, findsOneWidget);

      // Verify the top position of the indicator is at or below edgeOffset
      final topPos = tester.getTopLeft(indicatorFinder).dy;
      expect(topPos, greaterThanOrEqualTo(edgeOffset));

      // Verify FadeTransition ancestor exists and opacity is partially faded in
      final fadeTransitions = tester.widgetList<FadeTransition>(
        find.ancestor(of: indicatorFinder, matching: find.byType(FadeTransition)),
      );
      expect(fadeTransitions, isNotEmpty);
      final dragFade = fadeTransitions.firstWhere(
        (f) => f.opacity.value > 0.0 && f.opacity.value <= 1.0,
      );
      expect(dragFade.opacity.value, greaterThan(0.0));

      // Drag down further to arm
      await gesture.moveBy(const Offset(0, 200));
      await tester.pump();

      final topPosArmed = tester.getTopLeft(indicatorFinder).dy;
      expect(topPosArmed, greaterThan(topPos));
      expect(dragFade.opacity.value, closeTo(1.0, 0.01));

      // End drag to trigger refresh
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 200));

      refresh.complete();
      await tester.pump(const Duration(milliseconds: 300));
    },
  );
}
