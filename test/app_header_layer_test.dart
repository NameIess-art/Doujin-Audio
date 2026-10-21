import 'dart:async';

import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/core/widgets/app_search_page.dart';
import 'package:doujin_audio/app/presentation/routed_playback_dock_host.dart';
import 'support/app_runtime_test_fixture.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _oldHeader = Color(0xff00ff00);
const _newHeader = Color(0xffffff00);

class _HeaderPaintProbe extends CustomPainter {
  _HeaderPaintProbe(this.onPaint);

  final VoidCallback onPaint;

  @override
  void paint(Canvas canvas, Size size) {
    onPaint();
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.red);
  }

  @override
  bool shouldRepaint(_HeaderPaintProbe oldDelegate) => false;
}

Widget _page(String name, Color body, Color header, {VoidCallback? onTap}) =>
    Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          AppPageContentTransition(child: ColoredBox(color: body)),
          Positioned(
            top: 32,
            left: 0,
            right: 0,
            height: 56,
            child: AppPageHeaderTransition(
              child: GestureDetector(
                onTap: onTap,
                child: ColoredBox(key: ValueKey('$name-header'), color: header),
              ),
            ),
          ),
        ],
      ),
    );

Future<List<Color>> _pixels(
  WidgetTester tester,
  GlobalKey key,
  List<Offset> points,
) async => (await tester.runAsync(() async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  final image = await boundary.toImage();
  final bytes = (await image.toByteData())!;
  final colors = points.map((point) {
    final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
    return Color.fromARGB(
      bytes.getUint8(offset + 3),
      bytes.getUint8(offset),
      bytes.getUint8(offset + 1),
      bytes.getUint8(offset + 2),
    );
  }).toList();
  image.dispose();
  return colors;
}))!;

void main() {
  for (final (brightness, showFadeMask) in [
    for (final brightness in Brightness.values)
      for (final showFadeMask in [false, true]) (brightness, showFadeMask),
  ]) {
    testWidgets(
      'glass header keeps its tint continuous at route fade endpoints in $brightness (mask: $showFadeMask)',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        final surface = GlobalKey();
        var headerPaints = 0;
        final backdrop = showFadeMask
            ? const ColoredBox(color: Colors.blue)
            : const Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 35, child: ColoredBox(color: Colors.black)),
                  Expanded(child: ColoredBox(color: Colors.white)),
                ],
              );
        await tester.pumpWidget(
          RepaintBoundary(
            key: surface,
            child: MaterialApp(
              navigatorKey: navigator,
              theme: ThemeData(
                brightness: brightness,
                platform: defaultTargetPlatform,
              ),
              builder: (_, child) => AppPageTransitionHost(child: child!),
              home: Scaffold(backgroundColor: Colors.blue, body: backdrop),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final detailPage = Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            fit: StackFit.expand,
            children: [
              AppPageContentTransition(child: backdrop),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: TopPageHeader(
                  showFadeMask: showFadeMask,
                  titleWidget: const SizedBox.shrink(),
                  leading: HeaderFloatingButton(
                    backgroundOpacity: 0.5,
                    child: showFadeMask
                        ? const SizedBox.shrink()
                        : CustomPaint(
                            size: const Size(12, 12),
                            painter: _HeaderPaintProbe(() => headerPaints++),
                          ),
                  ),
                ),
              ),
            ],
          ),
        );
        PageRouteBuilder<void> route() => buildAppPageRoute<void>(
          context: navigator.currentContext!,
          separateHeader: true,
          slide: false,
          child: detailPage,
        );
        final detail = route();
        unawaited(navigator.currentState!.push(detail));
        await tester.pump();
        await tester.pump();
        expect(detail.animation!.value, 0);
        if (!showFadeMask) {
          expect(
            headerPaints,
            1,
            reason: 'Record the header before its first visible fade tick.',
          );
        }
        final samples = <({double progress, List<Color> pixels})>[];
        Future<void> sampleTint() async {
          final progress = kAppFadeCurve.transform(detail.animation!.value);
          final center = tester.getCenter(find.byType(HeaderFloatingButton));
          final pixels = await _pixels(tester, surface, [
            if (!showFadeMask) center + const Offset(0, -11),
            center,
          ]);
          samples.add((progress: progress, pixels: pixels));
        }

        for (final milliseconds in [75, 75, 75, 45, 15, 15]) {
          await tester.pump(Duration(milliseconds: milliseconds));
          await sampleTint();
        }
        await tester.pumpAndSettle();
        await sampleTint();
        final settled = samples.last.pixels;
        navigator.currentState!.pop();
        await tester.pump();
        await tester.pump();
        for (final milliseconds in [15, 15, 45, 75, 75]) {
          await tester.pump(Duration(milliseconds: milliseconds));
          await sampleTint();
        }
        for (final sample in samples) {
          for (var index = 0; index < settled.length; index++) {
            final expected = Color.lerp(
              showFadeMask ? Colors.blue : Colors.white,
              settled[index],
              sample.progress,
            )!;
            expect(
              sample.pixels[index].r,
              closeTo(expected.r, 0.02),
              reason: 'Progress ${sample.progress}',
            );
            expect(
              sample.pixels[index].g,
              closeTo(expected.g, 0.02),
              reason: 'Progress ${sample.progress}',
            );
            expect(
              sample.pixels[index].b,
              closeTo(expected.b, 0.02),
              reason: 'Progress ${sample.progress}',
            );
          }
        }
        await tester.pumpAndSettle();
        await tester.pump(Duration.zero);
        if (!showFadeMask) {
          final interrupted = route();
          unawaited(navigator.currentState!.push(interrupted));
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 75));
          final center = tester.getCenter(find.byType(HeaderFloatingButton));
          final points = [center + const Offset(0, -11), center];
          final before = await _pixels(tester, surface, points);
          navigator.currentState!.pop();
          await tester.pump();
          expect(await _pixels(tester, surface, points), before);
          await tester.pumpAndSettle();
          await tester.pump(Duration.zero);
        }
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'route header crossfades across its full width on push and pop',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final surface = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: surface,
          child: MaterialApp(
            navigatorKey: navigator,
            theme: ThemeData(
              platform: defaultTargetPlatform,
              pageTransitionsTheme: const PageTransitionsTheme(
                builders: {
                  TargetPlatform.android: AppPageTransitionsBuilder(),
                  TargetPlatform.windows: AppPageTransitionsBuilder(),
                },
              ),
            ),
            builder: (_, child) => AppPageTransitionHost(child: child!),
            home: _page('home', Colors.blue, _oldHeader),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final detail = buildAppPageRoute<void>(
        context: navigator.currentContext!,
        separateHeader: true,
        child: _page('detail', Colors.blue, _newHeader),
      );
      unawaited(navigator.currentState!.push(detail));
      await tester.pump();
      await tester.pump();

      Future<void> expectCrossfade() async {
        final progress = kAppFadeCurve.transform(detail.animation!.value);
        final expected = Color.alphaBlend(
          _newHeader.withValues(alpha: progress),
          Color.alphaBlend(
            _oldHeader.withValues(alpha: 1 - progress),
            Colors.blue,
          ),
        );
        final pixels = await _pixels(tester, surface, [
          const Offset(40, 50),
          const Offset(760, 50),
        ]);
        for (final pixel in pixels) {
          expect(pixel.r, closeTo(expected.r, 0.02));
          expect(pixel.g, closeTo(expected.g, 0.02));
          expect(pixel.b, closeTo(expected.b, 0.02));
        }
      }

      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 75));
        await expectCrossfade();
      }
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 75));
        await expectCrossfade();
      }
      await tester.pumpAndSettle();
      await tester.pump(Duration.zero);
      expect(find.byKey(const ValueKey('detail-header')), findsNothing);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'transparent header blocks sibling input within its live bounds',
    (tester) async {
      var bodyPointers = 0;
      var bodyGestures = 0;
      var bodySignals = 0;
      var controlTaps = 0;
      var height = 96.0;
      var visible = true;
      Widget page() => MaterialApp(
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              Listener(
                onPointerDown: (_) => bodyPointers++,
                onPointerSignal: (_) => bodySignals++,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => bodyGestures++,
                  onLongPress: () => bodyGestures++,
                  onSecondaryTap: () => bodyGestures++,
                  onVerticalDragUpdate: (_) => bodyGestures++,
                  child: const SizedBox.expand(),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Offstage(
                  offstage: !visible,
                  child: AppPageHeaderTransition(
                    child: SizedBox(
                      height: height,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          key: const ValueKey('header-control'),
                          onPressed: () => controlTaps++,
                          icon: const Icon(Icons.close),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(page());
      const gap = Offset(400, 40);
      await tester.tapAt(gap);
      await tester.longPressAt(gap);
      await tester.tapAt(gap, buttons: kSecondaryMouseButton);
      await tester.dragFrom(gap, const Offset(0, 100));
      await tester.sendEventToBinding(
        const PointerScrollEvent(position: gap, scrollDelta: Offset(0, 100)),
      );
      await tester.tap(find.byKey(const ValueKey('header-control')));
      await tester.pump();
      expect(controlTaps, 1);
      expect(bodyPointers, 0);
      expect(bodyGestures, 0);
      expect(bodySignals, 0);

      height = 24;
      await tester.pumpWidget(page());
      await tester.tapAt(gap);
      expect(bodyGestures, 1);
      visible = false;
      await tester.pumpWidget(page());
      await tester.tapAt(const Offset(400, 8));
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(400, 8),
          scrollDelta: Offset(0, 100),
        ),
      );
      expect(bodyGestures, 2);
      expect(bodySignals, 1);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  for (final (platform, reducedMotion) in [
    for (final platform in [TargetPlatform.android, TargetPlatform.windows])
      for (final reducedMotion in [false, true]) (platform, reducedMotion),
  ]) {
    testWidgets(
      'instant search header fades behind work details on $platform (reduced: $reducedMotion)',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        final surface = GlobalKey();
        final controller = TextEditingController();
        final focus = FocusNode();
        final tab = ValueNotifier(0);
        addTearDown(controller.dispose);
        addTearDown(focus.dispose);
        addTearDown(tab.dispose);
        await tester.pumpWidget(
          RepaintBoundary(
            key: surface,
            child: MaterialApp(
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
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: reducedMotion),
                child: AppPageTransitionHost(
                  child: AppFadeThroughIndexedStack.lazy(
                    indexListenable: tab,
                    itemCount: 1,
                    separateHeader: true,
                    itemBuilder: (_, _) => child!,
                  ),
                ),
              ),
              home: _page('home', Colors.red, _oldHeader),
            ),
          ),
        );
        unawaited(
          navigator.currentState!.push(
            buildAppPageRoute<void>(
              context: navigator.currentContext!,
              duration: Duration.zero,
              child: AppSearchPageScaffold<int>(
                controller: controller,
                focusNode: focus,
                hintText: 'Search',
                categories: const [AppSearchCategory(value: 0, label: 'All')],
                selectedCategory: 0,
                onCategorySelected: (_) {},
                onChanged: (_) {},
                onSubmitted: (_) {},
                onCloseOrClear: () {},
                controlsOverlay: const SizedBox(
                  height: 88,
                  child: ColoredBox(color: _oldHeader),
                ),
                body: const ColoredBox(color: Colors.red),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final detail = buildAppPageRoute<void>(
          context: navigator.currentContext!,
          separateHeader: true,
          child: _page('detail', Colors.blue, _newHeader),
        );
        unawaited(navigator.currentState!.push(detail));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        final sampled = await _pixels(tester, surface, [
          const Offset(790, 50),
          const Offset(790, 140),
        ]);
        final pixel = sampled.first;
        final incoming = kAppFadeCurve.transform(detail.animation!.value);
        final expected = Color.alphaBlend(
          _newHeader.withValues(alpha: incoming),
          Color.alphaBlend(
            _oldHeader.withValues(alpha: 1 - incoming),
            sampled.last,
          ),
        );
        // The search top mask also blends the body into the theme surface.
        // Red isolates header opacity because both underlying bodies have the
        // same red contribution here; green verifies the retained header wins.
        expect(pixel.r, closeTo(expected.r, 0.02));
        expect(pixel.g, greaterThan(0.6));
        expect(pixel.b, lessThan(0.4));
        await tester.pumpAndSettle();
        // This area belongs only to the search header, outside the detail header.
        expect(
          (await _pixels(tester, surface, [const Offset(790, 10)])).single,
          const Color(0xff2196f3),
        );
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(
          (await _pixels(tester, surface, [const Offset(790, 50)])).single,
          _oldHeader,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('header opacity recovers after hiding and repeated resizes', (
    tester,
  ) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    final surface = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: surface,
        child: MaterialApp(
          theme: ThemeData(
            platform: TargetPlatform.android,
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {TargetPlatform.android: AppPageTransitionsBuilder()},
            ),
          ),
          builder: (_, child) => AppPageTransitionHost(child: child!),
          home: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xffff0000)),
                Positioned(
                  top: 32,
                  left: 0,
                  right: 0,
                  height: 56,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: visible,
                    child: const AppPageHeaderTransition(
                      child: ColoredBox(color: _oldHeader),
                    ),
                    builder: (_, value, child) => AnimatedOpacity(
                      opacity: value ? 1 : 0,
                      duration: kAppFadeDuration,
                      curve: kAppFadeCurve,
                      child: child,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var cycle = 0; cycle < 3; cycle++) {
      visible.value = false;
      await tester.pumpAndSettle();
      tester.view.physicalSize = cycle.isEven
          ? const Size(600, 800)
          : const Size(800, 600);
      await tester.pumpAndSettle();
      expect(
        (await _pixels(tester, surface, [const Offset(8, 50)])).single,
        const Color(0xffff0000),
      );
      visible.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final middle = (await _pixels(tester, surface, [
        const Offset(8, 50),
      ])).single;
      expect(middle.g, closeTo(kAppFadeCurve.transform(0.5), 0.02));
      await tester.pumpAndSettle();
      expect(
        (await _pixels(tester, surface, [const Offset(8, 50)])).single,
        _oldHeader,
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (platform, separateHeader) in [
    for (final platform in [TargetPlatform.android, TargetPlatform.windows])
      for (final separated in [false, true]) (platform, separated),
  ]) {
    testWidgets('headers paint above both sliding route bodies ($platform, separate: $separateHeader)', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      final surface = GlobalKey();
      var taps = 0;
      await tester.pumpWidget(
        RepaintBoundary(
          key: surface,
          child: MaterialApp(
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
            builder: (_, child) => AppPageTransitionHost(child: child!),
            home: _page('old', Colors.red, _oldHeader),
          ),
        ),
      );
      final route = buildAppPageRoute<void>(
        context: navigator.currentContext!,
        separateHeader: separateHeader,
        child: _page('new', Colors.blue, _newHeader, onTap: () => taps++),
      );
      unawaited(navigator.currentState!.push(route));
      await tester.pump();
      await tester.pump();
      final header = find.byKey(const ValueKey('new-header'));
      final rect = tester.getRect(header);
      for (final elapsed in [50, 50, 50]) {
        await tester.pump(Duration(milliseconds: elapsed));
        expect(tester.getRect(header), rect);
        final colors = await _pixels(tester, surface, [
          const Offset(8, 50),
          const Offset(790, 50),
          const Offset(790, 140),
        ]);
        // Both edges retain the old green header while the new yellow header
        // fades in; the blue body's moving edge cannot wipe either header.
        final incoming = kAppFadeCurve.transform(route.animation!.value);
        final expected = Color.alphaBlend(
          _newHeader.withValues(alpha: incoming),
          Color.alphaBlend(
            _oldHeader.withValues(alpha: 1 - incoming),
            colors.last,
          ),
        );
        expect(colors[1].r, closeTo(expected.r, 0.02));
        expect(colors[1].g, closeTo(expected.g, 0.02));
        expect(colors[1].b, closeTo(expected.b, 0.02));
        expect(
          colors.take(2).every((color) => color.g > 0.6 && color.b < 0.4),
          isTrue,
          reason: '$colors',
        );
      }
      await tester.pumpAndSettle();
      await tester.tap(header);
      expect(taps, 1);
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.getRect(header), rect);
      final colors = await _pixels(tester, surface, [
        const Offset(8, 50),
        const Offset(790, 50),
      ]);
      expect(
        colors.every((color) => color.g > 0.6 && color.b < 0.4),
        isTrue,
        reason: '$colors',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('old-header')), findsOneWidget);
      unawaited(
        navigator.currentState!.push(
          buildAppPageRoute<void>(
            context: navigator.currentContext!,
            separateHeader: separateHeader,
            child: _page('interrupted', Colors.blue, _newHeader),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      final beforeReverse = (await _pixels(tester, surface, [
        const Offset(790, 50),
      ])).single;
      navigator.currentState!.pop();
      await tester.pump();
      final afterReverse = (await _pixels(tester, surface, [
        const Offset(790, 50),
      ])).single;
      expect(afterReverse, beforeReverse);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('interrupted-header')), findsNothing);
      expect(find.byKey(const ValueKey('old-header')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'header foreground respects ancestor opacity and popup coverage',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final navigator = GlobalKey<NavigatorState>();
      final surface = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: surface,
          child: fixture.build(
            RoutedPlaybackDockHost(
              navigatorKey: navigator,
              enabled: false,
              builder: (_, observer, geometry, wrapNavigator) => MaterialApp(
                navigatorKey: navigator,
                navigatorObservers: [observer],
                theme: ThemeData(
                  pageTransitionsTheme: const PageTransitionsTheme(
                    builders: {
                      TargetPlatform.android: AppPageTransitionsBuilder(),
                    },
                  ),
                ),
                builder: (context, child) => wrapNavigator(context, child!),
                home: const Scaffold(
                  body: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(color: Colors.red),
                      Positioned(
                        top: 32,
                        left: 0,
                        right: 0,
                        height: 56,
                        child: Opacity(
                          opacity: 0.25,
                          child: AppPageHeaderTransition(
                            child: ColoredBox(color: _oldHeader),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final initial = (await _pixels(tester, surface, [
        const Offset(8, 50),
      ])).single;
      expect(
        initial.g,
        closeTo(
          Color.alphaBlend(_oldHeader.withValues(alpha: 0.25), Colors.red).g,
          0.02,
        ),
      );
      unawaited(
        showGeneralDialog<void>(
          useRootNavigator: false,
          context: navigator.currentContext!,
          transitionDuration: kAppFadeDuration,
          pageBuilder: (_, animation, secondary) =>
              const ColoredBox(color: Color(0xffff00ff)),
        ),
      );
      await tester.pumpAndSettle();
      final covered = (await _pixels(tester, surface, [
        const Offset(8, 50),
      ])).single;
      expect(covered, const Color(0xffff00ff));
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      final restored = (await _pixels(tester, surface, [
        const Offset(8, 50),
      ])).single;
      expect(restored, initial);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('tab headers stay above both full-size page backgrounds', (
    tester,
  ) async {
    final selected = ValueNotifier(0);
    addTearDown(selected.dispose);
    final surface = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: surface,
        child: MaterialApp(
          home: AppFadeThroughIndexedStack.lazy(
            indexListenable: selected,
            itemCount: 2,
            separateHeader: true,
            itemBuilder: (_, index) => _page(
              '$index',
              index == 0 ? Colors.red : Colors.blue,
              index == 0 ? _oldHeader : _newHeader,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    selected.value = 1;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final colors = await _pixels(tester, surface, [
      const Offset(8, 50),
      const Offset(790, 50),
    ]);
    expect(
      colors.every((color) => color.g > 0.6 && color.b < 0.4),
      isTrue,
      reason: '$colors',
    );
    await tester.pumpAndSettle();
    selected.value = 0;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final returningColors = await _pixels(tester, surface, [
      const Offset(8, 50),
      const Offset(790, 50),
      const Offset(8, 140),
    ]);
    final incoming = kAppFadeCurve.transform(0.5);
    // Revisited tabs must follow the current Stack paint order, not mount order.
    final expected = Color.alphaBlend(
      _oldHeader.withValues(alpha: incoming),
      Color.alphaBlend(
        _newHeader.withValues(alpha: 1 - incoming),
        returningColors.last,
      ),
    );
    expect(returningColors.first.r, closeTo(expected.r, 0.02));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
