import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/app_entry_ink_well.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Windows mouse entry clears highlights while its page is covered', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: ThemeData(
          platform: TargetPlatform.windows,
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {TargetPlatform.windows: AppPageTransitionsBuilder()},
          ),
        ),
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => OutlinedButton(
                style: AppEntryInkWell.entryButtonStyle(Theme.of(context)),
                onPressed: () => Navigator.of(context).push<void>(
                  buildAppPageRoute<void>(
                    context: context,
                    child: const Scaffold(body: Text('detail')),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    final entry = find.byType(OutlinedButton);
    final ink = find.descendant(of: entry, matching: find.byType(InkWell));
    final dynamic controller = Material.of(tester.element(ink));
    Iterable<InkHighlight> visibleHighlights() =>
        (controller.debugInkFeatures as List<InkFeature>? ?? [])
            .whereType<InkHighlight>()
            .where((feature) => feature.color.a > 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(entry));
    await tester.pumpAndSettle();
    final hoverBackground = find.descendant(
      of: entry,
      matching: find.byWidgetPredicate(
        (widget) {
          if (widget is! DecoratedBox) return false;
          final decoration = widget.decoration;
          final Color? color = switch (decoration) {
            BoxDecoration(:final color) => color,
            ShapeDecoration(:final color) => color,
            _ => null,
          };
          return color?.a == 0.08;
        },
      ),
      skipOffstage: false,
    );
    expect(hoverBackground, findsOneWidget);
    await mouse.down(tester.getCenter(entry));
    await tester.pump(const Duration(milliseconds: 100));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(
      TickerMode.valuesOf(
        tester.element(find.byType(InkWell, skipOffstage: false)),
      ).enabled,
      isFalse,
    );
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 200));
    navigator.currentState!.pop();
    await tester.pump();
    expect(visibleHighlights(), isEmpty);
    await tester.pumpAndSettle();
    expect(visibleHighlights(), isEmpty);
    expect(hoverBackground, findsNothing);
    await mouse.removePointer();
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final buttonType in ['outlined', 'filled', 'text', 'icon']) {
      testWidgets('$buttonType entry clears pressed ink on $platform', (
        tester,
      ) async {
        final navigator = GlobalKey<NavigatorState>();
        final focus = FocusNode(canRequestFocus: false);
        addTearDown(focus.dispose);
        const entryKey = ValueKey('button_entry');
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: Center(
                child: Builder(
                  builder: (context) {
                    final style = AppEntryInkWell.entryButtonStyle(
                      Theme.of(context),
                    );
                    void open() => Navigator.of(context).push<void>(
                      buildAppPageRoute<void>(
                        context: context,
                        child: const Scaffold(body: Text('detail')),
                      ),
                    );
                    return KeyedSubtree(
                      key: entryKey,
                      child: switch (buttonType) {
                        'outlined' => OutlinedButton(
                          style: style,
                          focusNode: focus,
                          onPressed: open,
                          child: const Text('open'),
                        ),
                        'filled' => FilledButton(
                          style: style,
                          focusNode: focus,
                          onPressed: open,
                          child: const Text('open'),
                        ),
                        'text' => TextButton(
                          style: style,
                          focusNode: focus,
                          onPressed: open,
                          child: const Text('open'),
                        ),
                        _ => IconButton(
                          style: style,
                          focusNode: focus,
                          onPressed: open,
                          icon: const Icon(Icons.add),
                        ),
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        );
        final entry = find.byKey(entryKey);
        final ink = find.descendant(
          of: entry,
          matching: find.bySubtype<InkWell>(),
        );
        final dynamic controller = Material.of(tester.element(ink));
        Iterable<InteractiveInkFeature> visibleInk() =>
            (controller.debugInkFeatures as List<InkFeature>? ?? [])
                .whereType<InteractiveInkFeature>()
                .where((feature) => feature.color.a > 0);
        final cancelled = await tester.startGesture(tester.getCenter(entry));
        await tester.pump(const Duration(milliseconds: 120));
        expect(visibleInk(), isNotEmpty);
        await cancelled.cancel();
        expect(visibleInk(), isEmpty);
        final pressed = await tester.startGesture(tester.getCenter(entry));
        await tester.pump(const Duration(milliseconds: 120));
        expect(visibleInk(), isNotEmpty);
        await pressed.up();
        expect(visibleInk(), isEmpty);
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(visibleInk(), isEmpty);
        await tester.pumpAndSettle();
        expect(entry, findsOneWidget);
        expect(visibleInk(), isEmpty);
      });
    }
  }

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
      expect(visibleInk().whereType<InkSplash>(), isEmpty);
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
      expect(visibleInk().whereType<InkSplash>(), isEmpty);
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
      Iterable<InkSplash> splashes() {
        final dynamic controller = Material.of(entryContext);
        final features = controller.debugInkFeatures as List<InkFeature>?;
        return (features ?? <InkFeature>[]).whereType<InkSplash>();
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
      expect(splashes(), isEmpty);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Windows hover background conforms to button shape', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.windows,
          iconButtonTheme: IconButtonThemeData(
            style: IconButton.styleFrom(shape: const CircleBorder()),
          ),
        ),
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => IconButton(
                style: AppEntryInkWell.entryButtonStyle(Theme.of(context)),
                onPressed: () {},
                icon: const Icon(Icons.settings),
              ),
            ),
          ),
        ),
      ),
    );

    final entry = find.byType(IconButton);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(entry));
    await tester.pumpAndSettle();

    final decorated = tester.widget<DecoratedBox>(
      find.descendant(of: entry, matching: find.byType(DecoratedBox)),
    );
    expect(decorated.decoration, isA<ShapeDecoration>());
    final shapeDecoration = decorated.decoration as ShapeDecoration;
    expect(shapeDecoration.shape, isA<CircleBorder>());
    expect(shapeDecoration.color?.a, 0.08);

    await mouse.removePointer();
  });
}

