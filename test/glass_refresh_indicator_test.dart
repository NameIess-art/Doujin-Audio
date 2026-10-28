import 'dart:async';

import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/app_glass_surface.dart';
import 'package:doujin_audio/core/widgets/glass_refresh_indicator.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';

void main() {
  testWidgets(
    'first upward scroll skips refresh artwork and can reverse into a pull',
    (tester) async {
      final refresh = Completer<void>();
      final controller = ScrollController();
      final indicatorKey = GlobalKey<GlassRefreshIndicatorState>();
      addTearDown(controller.dispose);
      var refreshCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            extensions: [AppDesignTokens.light.copyWith(barGlassEnabled: true)],
          ),
          home: Scaffold(
            body: GlassRefreshIndicator(
              key: indicatorKey,
              triggerMode: GlassRefreshIndicatorTriggerMode.anywhere,
              lockChildWhileRefreshing: true,
              onRefresh: () {
                refreshCount++;
                return refresh.future;
              },
              child: ListView(
                controller: controller,
                physics: AlwaysScrollableScrollPhysics(
                  parent: GlassRefreshIndicatorScrollPhysics(
                    isIndicatorVisible: () =>
                        indicatorKey.currentState?.isIndicatorVisible ?? false,
                  ),
                ),
                children: const [SizedBox(height: 2000)],
              ),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(const Offset(200, 300));
      await gesture.moveBy(const Offset(0, -100));
      await tester.pump();
      expect(controller.offset, greaterThan(0));
      expect(find.byType(RefreshProgressIndicator), findsNothing);
      expect(find.byType(AppGlassSurface), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);

      // The same gesture can return to the edge and become a real refresh.
      await gesture.moveBy(const Offset(0, 100));
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump();
      expect(controller.offset, 0);
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget);
      await gesture.moveBy(const Offset(0, 260));
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(refreshCount, 1);
      refresh.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AppGlassSurface), findsNothing);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'active refresh follows bar glass preference in $brightness',
      (tester) async {
        final enabled = ValueNotifier(false);
        addTearDown(enabled.dispose);
        final refresh = Completer<void>();
        final key = GlobalKey<GlassRefreshIndicatorState>();
        final theme = ThemeData(brightness: brightness);
        await tester.pumpWidget(
          ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (_, value, child) => MaterialApp(
              theme: theme.copyWith(
                extensions: [
                  (brightness == Brightness.dark
                          ? AppDesignTokens.dark
                          : AppDesignTokens.light)
                      .copyWith(barGlassEnabled: value),
                ],
              ),
              home: child,
            ),
            child: Scaffold(
              body: GlassRefreshIndicator(
                key: key,
                onRefresh: () => refresh.future,
                child: ListView(children: const [SizedBox(height: 800)]),
              ),
            ),
          ),
        );
        final pending = key.currentState!.show();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final state = key.currentState;
        for (final value in [false, true, false]) {
          enabled.value = value;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(key.currentState, same(state));
          expect(find.byType(RefreshProgressIndicator), findsOneWidget);
          expect(
            find.byType(BackdropFilter),
            value ? findsOneWidget : findsNothing,
          );
          final glass = find.byType(AppGlassSurface);
          expect(tester.widget<AppGlassSurface>(glass).enabled, value);
          final tint = tester.widget<ColoredBox>(
            find.descendant(of: glass, matching: find.byType(ColoredBox)).first,
          );
          expect(
            tint.color.a,
            closeTo(
              value ? (brightness == Brightness.dark ? .84 : .8) : 1,
              .005,
            ),
          );
        }
        refresh.complete();
        await tester.pump();
        await pending;
        await tester.pumpAndSettle();
        expect(find.byType(AppGlassSurface), findsNothing);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }
  testWidgets('hidden refresh releases deferred updates on other pages', (
    tester,
  ) async {
    final interaction = UiInteractionCoordinator.instance;
    addTearDown(interaction.resetForTest);
    final refresh = Completer<void>();
    final key = GlobalKey<GlassRefreshIndicatorState>();
    var visible = true;
    late StateSetter setVisible;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setVisible = setState;
              return TickerMode(
                enabled: visible,
                child: GlassRefreshIndicator(
                  key: key,
                  onRefresh: () => refresh.future,
                  child: ListView(children: const [SizedBox(height: 800)]),
                ),
              );
            },
          ),
        ),
      ),
    );
    unawaited(key.currentState!.show());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    var commits = 0;
    interaction.scheduleCommit(
      key: 'hidden-refresh-test',
      structural: true,
      commit: () => commits++,
    );
    expect(interaction.isInteracting, isTrue);
    setVisible(() => visible = false);
    await tester.pump();
    await tester.pump();
    expect(interaction.isInteracting, isFalse);
    expect(commits, 1);
    refresh.complete();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('catalog updates wait for refresh and indicator dismissal', (
    tester,
  ) async {
    final interaction = UiInteractionCoordinator.instance;
    addTearDown(interaction.resetForTest);
    final refresh = Completer<void>();
    final key = GlobalKey<GlassRefreshIndicatorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassRefreshIndicator(
            key: key,
            onRefresh: () => refresh.future,
            child: ListView(children: const [SizedBox(height: 800)]),
          ),
        ),
      ),
    );
    final future = key.currentState!.show();
    var commits = 0;
    interaction.scheduleCommit(
      key: 'refresh-catalog-test',
      structural: true,
      commit: () => commits++,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(commits, 0);
    refresh.complete();
    await tester.pump();
    await future;
    await tester.pump(const Duration(milliseconds: 100));
    expect(commits, 0);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pump();
    expect(commits, 1);
    await tester.pumpWidget(const SizedBox());
    expect(interaction.isInteracting, isFalse);
  });
  testWidgets('refresh mounts one circular glass surface only while visible', (
    tester,
  ) async {
    final refresh = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: [AppDesignTokens.light.copyWith(barGlassEnabled: true)],
        ),
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

    expect(find.byType(AppGlassSurface), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();

    final indicator = find.byType(RefreshProgressIndicator);
    expect(indicator, findsOneWidget);
    expect(
      find.ancestor(of: indicator, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    final glass = tester.widget<AppGlassSurface>(find.byType(AppGlassSurface));
    expect(glass.blurSigma, 4);
    final clips = find.ancestor(of: indicator, matching: find.byType(ClipRRect));
    expect(clips, findsOneWidget);
    final clipSize = tester.getSize(clips);
    expect(clipSize.width, clipSize.height);
    final radius = tester.widget<ClipRRect>(clips).borderRadius.resolve(
      TextDirection.ltr,
    );
    expect(radius.topLeft.x, greaterThanOrEqualTo(clipSize.width / 2));
    expect(
      find.ancestor(of: indicator, matching: find.byType(ClipOval)),
      findsNothing,
    );
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
    await tester.pumpAndSettle();
    expect(find.byType(AppGlassSurface), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('refresh preserves input alpha in $brightness theme', (
      tester,
    ) async {
      final refresh = Completer<void>();
      const backgroundColor = Color(0x99FF0000);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: brightness,
            extensions: [
              (brightness == Brightness.dark
                      ? AppDesignTokens.dark
                      : AppDesignTokens.light)
                  .copyWith(barGlassEnabled: true),
            ],
          ),
          home: Scaffold(
            body: GlassRefreshIndicator(
              backgroundColor: backgroundColor,
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
      final glass = tester.widget<AppGlassSurface>(
        find.byType(AppGlassSurface),
      );
      expect(glass.backgroundColor, backgroundColor);
      final background = tester.widget<ColoredBox>(
        find
            .descendant(
              of: find.byType(AppGlassSurface),
              matching: find.byType(ColoredBox),
            )
            .first,
      );
      expect(
        background.color.a,
        closeTo(
          backgroundColor.a * (brightness == Brightness.dark ? .84 : .8),
          .005,
        ),
      );

      refresh.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    });
  }

  testWidgets('transparent refresh background disables the blur filter', (
    tester,
  ) async {
    final refresh = Completer<void>();
    final key = GlobalKey<GlassRefreshIndicatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: [AppDesignTokens.light.copyWith(barGlassEnabled: true)],
        ),
        home: Scaffold(
          body: GlassRefreshIndicator(
            key: key,
            backgroundColor: Colors.transparent,
            onRefresh: () => refresh.future,
            child: ListView(children: const [SizedBox(height: 800)]),
          ),
        ),
      ),
    );
    unawaited(key.currentState!.show());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    expect(
      tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
      isFalse,
    );
    refresh.complete();
    await tester.pump();
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
        find.ancestor(
          of: indicatorFinder,
          matching: find.byType(FadeTransition),
        ),
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

  testWidgets(
    'clamped pull keeps content fixed while the indicator refreshes',
    (tester) async {
      final refresh = Completer<void>();
      final controller = ScrollController();
      final indicatorKey = GlobalKey<GlassRefreshIndicatorState>();
      addTearDown(controller.dispose);
      var refreshCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GlassRefreshIndicator(
              key: indicatorKey,
              lockChildWhileRefreshing: true,
              onRefresh: () {
                refreshCount++;
                return refresh.future;
              },
              child: ListView(
                controller: controller,
                physics: AlwaysScrollableScrollPhysics(
                  parent: GlassRefreshIndicatorScrollPhysics(
                    isIndicatorVisible: () =>
                        indicatorKey.currentState?.isIndicatorVisible ?? false,
                  ),
                ),
                children: const [
                  SizedBox(key: ValueKey('first-item'), height: 120),
                  SizedBox(height: 1200),
                ],
              ),
            ),
          ),
        ),
      );

      final item = find.byKey(const ValueKey('first-item'));
      final initialTop = tester.getTopLeft(item).dy;
      final gesture = await tester.startGesture(tester.getCenter(item));
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump();
      expect(tester.getTopLeft(item).dy, initialTop);
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);

      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
      expect(controller.offset, 0);
      expect(indicatorKey.currentState?.isIndicatorVisible, isTrue);

      await gesture.moveBy(const Offset(0, -70));
      await tester.pump();
      expect(controller.offset, 0);

      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();

      await gesture.moveBy(const Offset(0, 260));
      await tester.pump();
      expect(tester.getTopLeft(item).dy, initialTop);
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(refreshCount, 1);

      await tester.dragFrom(const Offset(400, 300), const Offset(0, -250));
      await tester.pump();
      expect(controller.offset, 0);

      refresh.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.drag(find.byType(ListView), const Offset(0, -250));
      await tester.pump();
      expect(controller.offset, greaterThan(0));
    },
  );
}
