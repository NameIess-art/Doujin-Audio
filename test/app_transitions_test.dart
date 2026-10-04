import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';

class _StateProbe extends StatefulWidget {
  const _StateProbe({super.key, required this.label});

  final String label;

  @override
  State<_StateProbe> createState() => _StateProbeState();
}

class _StateProbeState extends State<_StateProbe> {
  @override
  Widget build(BuildContext context) => Center(child: Text(widget.label));
}

class _BuildCountingContent extends AppPageContentTransition {
  const _BuildCountingContent({required this.onBuild, required super.child});

  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return super.build(context);
  }
}

class _DetailPaintProbe extends SingleChildRenderObjectWidget {
  const _DetailPaintProbe({required this.onPaint, required super.child});

  final VoidCallback onPaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _DetailPaintRenderBox(onPaint);
}

class _DetailPaintRenderBox extends RenderProxyBox {
  _DetailPaintRenderBox(this.onPaint);

  final VoidCallback onPaint;

  @override
  void paint(PaintingContext context, Offset offset) {
    onPaint();
    super.paint(context, offset);
  }
}

void main() {
  setUp(UiInteractionCoordinator.instance.resetForTest);
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  testWidgets('route preparation preserves the full visible animation', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigatorKey, home: const SizedBox()),
    );
    final route = buildAppPageRoute<void>(
      context: navigatorKey.currentContext!,
      child: const _StateProbe(label: 'prepared-route'),
    );
    unawaited(navigatorKey.currentState!.push(route));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('prepared-route', skipOffstage: false), findsOneWidget);
    expect(route.animation!.value, 0);
    expect(route.animation!.status, AnimationStatus.forward);
    await tester.pump(const Duration(milliseconds: 500));
    expect(route.animation!.value, 0);
    await tester.pump(const Duration(milliseconds: 150));
    expect(route.animation!.value, closeTo(0.5, 0.001));
    await tester.pump(const Duration(milliseconds: 149));
    expect(route.animation!.status, AnimationStatus.forward);
    await tester.pump(const Duration(milliseconds: 1));
    expect(route.animation!.status, AnimationStatus.completed);
    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 301));
    expect(route.animation!.status, AnimationStatus.dismissed);
    await tester.pumpAndSettle();
    expect(find.text('prepared-route'), findsNothing);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('route preserves content and restores input on $platform', (
      tester,
    ) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final focus = FocusNode();
      final text = TextEditingController();
      addTearDown(focus.dispose);
      addTearDown(text.dispose);
      var builds = 0;
      var presses = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          navigatorKey: navigatorKey,
          home: const SizedBox(),
        ),
      );
      unawaited(
        navigatorKey.currentState!.push(
          buildAppPageRoute<void>(
            context: navigatorKey.currentContext!,
            child: Scaffold(
              body: _BuildCountingContent(
                onBuild: () => builds++,
                child: Column(
                  children: [
                    TextField(
                      key: const ValueKey('route-input'),
                      focusNode: focus,
                      controller: text,
                    ),
                    TextButton(
                      onPressed: () => presses++,
                      child: const Text('route-action'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      final preparedBuilds = builds;
      expect(preparedBuilds, greaterThan(0));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(builds, preparedBuilds);
      await tester.pumpAndSettle();
      await tester.tap(find.text('route-action'));
      await tester.pump();
      expect(presses, 1);
      final input = find.byKey(const ValueKey('route-input'));
      await tester.tap(input);
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      tester.testTextInput.enterText('作品搜索');
      await tester.pump();
      expect(text.text, '作品搜索');
      expect(tester.takeException(), isNull);
    });
  }

  for (final lazy in [false, true]) {
    testWidgets('first page frame prepares once (lazy: $lazy)', (tester) async {
      final index = ValueNotifier<int>(0);
      addTearDown(index.dispose);
      final completed = <int>[];
      Widget page(int i) => Text('prepared-$i');
      await tester.pumpWidget(
        MaterialApp(
          home: lazy
              ? AppFadeThroughIndexedStack.lazy(
                  indexListenable: index,
                  itemCount: 2,
                  itemBuilder: (_, i) => page(i),
                  duration: kAppMotionSlow,
                  onTransitionCompleted: completed.add,
                )
              : AppFadeThroughIndexedStack(
                  indexListenable: index,
                  duration: kAppMotionSlow,
                  onTransitionCompleted: completed.add,
                  children: [page(0), page(1)],
                ),
        ),
      );
      index.value = 1;
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('prepared-1'), findsOneWidget);
      expect(completed, isEmpty);
      expect(UiInteractionCoordinator.instance.isInteracting, isTrue);
      await tester.pump(const Duration(milliseconds: 500));
      expect(completed, isEmpty);
      await tester.pump(const Duration(milliseconds: 299));
      expect(completed, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(completed, [1]);
      await tester.pumpAndSettle();
      index.value = 0;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(_translationFor(tester, 'prepared-0'), isNot(Offset.zero));
      await tester.pump(const Duration(milliseconds: 151));
      expect(completed, [1, 0]);
      await tester.pump(UiInteractionCoordinator.instance.idleDelay);
      await tester.pumpAndSettle();
      expect(UiInteractionCoordinator.instance.isInteracting, isFalse);
    });
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'cached pages prepare at the resized viewport ($platform)',
      (tester) async {
        final index = ValueNotifier<int>(0);
        final size = ValueNotifier<double>(300);
        addTearDown(index.dispose);
        addTearDown(size.dispose);
        final completed = <int>[];
        final builds = [0, 0];
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: ValueListenableBuilder<double>(
                valueListenable: size,
                builder: (_, extent, _) => SizedBox(
                  width: extent,
                  height: extent,
                  child: AppFadeThroughIndexedStack.lazy(
                    indexListenable: index,
                    itemCount: 2,
                    duration: kAppMotionSlow,
                    onTransitionCompleted: completed.add,
                    itemBuilder: (_, page) {
                      builds[page]++;
                      return Text('resized-$page');
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        index.value = 1;
        await tester.pumpAndSettle();
        completed.clear();
        size.value = 400;
        await tester.pump();
        index.value = 0;
        await tester.pump(const Duration(milliseconds: 500));
        expect(completed, isEmpty);
        await tester.pump(const Duration(milliseconds: 500));
        expect(completed, isEmpty);
        await tester.pump(const Duration(milliseconds: 299));
        expect(completed, isEmpty);
        await tester.pump(const Duration(milliseconds: 1));
        expect(completed, [0]);
        expect(builds, [1, 1]);
        expect(find.text('resized-0'), findsOneWidget);
        await tester.pumpAndSettle();
        index.value = 1;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        size.value = 500;
        await tester.pump();
        await tester.pumpAndSettle();
        expect(completed, [0, 1]);
        expect(builds, [1, 1]);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('separate header reuses content between frames', (tester) async {
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    final builds = [0, 0];
    final paints = [0, 0];
    await tester.pumpWidget(
      MaterialApp(
        home: AppFadeThroughIndexedStack.lazy(
          indexListenable: index,
          itemCount: 2,
          duration: kAppMotionSlow,
          separateHeader: true,
          itemBuilder: (_, page) => Column(
            children: [
              AppPageHeaderTransition(child: Text('header-$page')),
              Expanded(
                child: _BuildCountingContent(
                  onBuild: () => builds[page]++,
                  child: _DetailPaintProbe(
                    onPaint: () => paints[page]++,
                    child: Text('content-$page'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    index.value = 1;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump(const Duration(milliseconds: 30));
    final preparedBuilds = List<int>.of(builds);
    final preparedPaints = List<int>.of(paints);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(builds, preparedBuilds);
    expect(paints, preparedPaints);
    await tester.pumpAndSettle();
  });

  testWidgets('preparing pages follow newest choice and release on dispose', (
    tester,
  ) async {
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    final created = <int>[];
    final completed = <int>[];
    final coordinator = UiInteractionCoordinator.instance;
    await tester.pumpWidget(
      MaterialApp(
        home: AppFadeThroughIndexedStack.lazy(
          indexListenable: index,
          itemCount: 3,
          duration: kAppMotionSlow,
          onTransitionCompleted: completed.add,
          itemBuilder: (_, page) {
            created.add(page);
            return Text('rapid-prepared-$page');
          },
        ),
      ),
    );
    index.value = 1;
    index.value = 2;
    await tester.pump();
    expect(created, [0, 2]);
    expect(completed, isEmpty);
    index.value = 0;
    await tester.pumpAndSettle();
    expect(completed.last, 0);
    await tester.pump(coordinator.idleDelay);
    expect(coordinator.isInteracting, isFalse);
    index.value = 1;
    var committed = false;
    coordinator.scheduleCommit(
      key: 'disposed-preparation',
      commit: () => committed = true,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(coordinator.isInteracting, isFalse);
    expect(committed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('page routes open and close in 300 ms', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: ThemeData(
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: AppPageTransitionsBuilder(),
              TargetPlatform.windows: AppPageTransitionsBuilder(),
            },
          ),
        ),
        home: const Scaffold(),
      ),
    );

    final navigator = navigatorKey.currentState!;
    final appRoute = buildAppPageRoute<void>(
      context: navigator.context,
      child: const Scaffold(),
    );
    expect(appRoute.transitionDuration, kAppMotionSlow);
    expect(appRoute.reverseTransitionDuration, kAppMotionSlow);

    final materialRoute = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(),
    );
    unawaited(navigator.push(materialRoute));
    await tester.pump();
    expect(materialRoute.transitionDuration, kAppMotionSlow);
    expect(materialRoute.reverseTransitionDuration, kAppMotionSlow);
    await tester.pumpAndSettle();
  });

  Widget regions(
    String name, {
    Color? backgroundColor,
    bool transparentPage = false,
  }) => Scaffold(
    backgroundColor: transparentPage ? Colors.transparent : backgroundColor,
    body: Column(
      children: [
        AppPageHeaderTransition(
          child: SizedBox(
            key: ValueKey('$name-header'),
            width: 100,
            height: 38,
          ),
        ),
        Expanded(
          child: AppPageContentTransition(
            backgroundColor: transparentPage ? backgroundColor : null,
            child: SizedBox.expand(key: ValueKey('$name-body')),
          ),
        ),
      ],
    ),
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'work detail fades its stationary header and retains prepared frames on $platform',
      (tester) async {
        final navigatorKey = GlobalKey<NavigatorState>();
        final surface = GlobalKey();
        var paints = 0;
        var builds = 0;
        await tester.pumpWidget(
          RepaintBoundary(
            key: surface,
            child: MaterialApp(
              theme: ThemeData(platform: platform),
              navigatorKey: navigatorKey,
              home: regions('whole-home', backgroundColor: Colors.red),
            ),
          ),
        );
        final route = buildAppPageRoute<void>(
          context: navigatorKey.currentContext!,
          workDetailTransition: true,
          child: _DetailPaintProbe(
            onPaint: () => paints++,
            child: _BuildCountingContent(
              onBuild: () => builds++,
              child: regions('whole-detail', backgroundColor: Colors.blue),
            ),
          ),
        );
        expect(route.transitionDuration, const Duration(milliseconds: 300));
        expect(
          route.reverseTransitionDuration,
          const Duration(milliseconds: 300),
        );
        unawaited(navigatorKey.currentState!.push(route));
        await tester.pump(const Duration(milliseconds: 500));
        expect(route.animation!.value, 0);
        await tester.pump(const Duration(milliseconds: 500));
        expect(route.animation!.value, 0);
        expect(
          paints,
          1,
          reason: 'The offscreen page is recorded before moving.',
        );
        final preparedBuilds = builds;
        final headerLeft = tester
            .getRect(find.byKey(const ValueKey('whole-home-header')))
            .left;
        await tester.pump(const Duration(milliseconds: 75));
        final header = find.byKey(const ValueKey('whole-detail-header'));
        final body = find.byKey(const ValueKey('whole-detail-body'));
        expect(tester.getRect(header).left, closeTo(headerLeft, 0.01));
        expect(tester.getRect(body).left, greaterThan(0));
        final headerOpacity = find
            .ancestor(of: header, matching: find.byType(Opacity))
            .first;
        expect(
          tester.widget<Opacity>(headerOpacity).opacity,
          inExclusiveRange(0, 1),
        );
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 75));
        }
        await tester.pump(const Duration(milliseconds: 1));
        expect(route.animation!.status, AnimationStatus.completed);
        expect(builds, preparedBuilds);
        expect(
          paints,
          1,
          reason: 'Translation reuses the recorded page layer.',
        );

        navigatorKey.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 225));
        expect(tester.getRect(header).left, closeTo(headerLeft, 0.01));
        expect(tester.getRect(body).left, greaterThan(0));
        expect(
          tester.widget<Opacity>(headerOpacity).opacity,
          inExclusiveRange(0, 1),
        );
        var finalFrameRetained = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          finalFrameRetained =
              route.animation!.value == 0 &&
              route.animation!.status == AnimationStatus.reverse &&
              find
                  .byKey(
                    const ValueKey('whole-detail-body'),
                    skipOffstage: false,
                  )
                  .evaluate()
                  .isNotEmpty;
        });
        await tester.pump(const Duration(milliseconds: 76));
        expect(
          finalFrameRetained,
          isTrue,
          reason: 'Pop finalization must not remove the last animated frame.',
        );
        final color = await tester.runAsync(() async {
          final image = await tester
              .renderObject<RenderRepaintBoundary>(find.byKey(surface))
              .toImage();
          final bytes = (await image.toByteData())!;
          final offset =
              ((image.height * 0.75).floor() * image.width +
                  (image.width * 0.5).floor()) *
              4;
          final pixel = Color.fromARGB(
            bytes.getUint8(offset + 3),
            bytes.getUint8(offset),
            bytes.getUint8(offset + 1),
            bytes.getUint8(offset + 2),
          );
          image.dispose();
          return pixel;
        });
        expect(color, const Color(0xfff44336));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('whole-detail-body'), skipOffstage: false),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'work detail cancels during preparation and honors reduced motion',
    (tester) async {
      for (final reduced in [false, true]) {
        final navigatorKey = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: MaterialApp(
              navigatorKey: navigatorKey,
              home: const SizedBox(),
            ),
          ),
        );
        final route = buildAppPageRoute<void>(
          context: navigatorKey.currentContext!,
          workDetailTransition: true,
          child: const Text('cancel-whole-detail'),
        );
        if (reduced) expect(route.transitionDuration, Duration.zero);
        unawaited(navigatorKey.currentState!.push(route));
        await tester.pump();
        navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        expect(
          find.text('cancel-whole-detail', skipOffstage: false),
          findsNothing,
        );
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'work detail releases tickers after interrupted entry and removal',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const SizedBox()),
      );
      for (final remove in [false, true]) {
        final route = buildAppPageRoute<void>(
          context: navigatorKey.currentContext!,
          workDetailTransition: true,
          child: const Text('interrupted-whole-detail'),
        );
        unawaited(navigatorKey.currentState!.push(route));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        expect(route.animation!.value, closeTo(0.25, 0.001));
        navigatorKey.currentState!.pop();
        await tester.pump();
        if (remove) navigatorKey.currentState!.removeRoute(route);
        await tester.pumpAndSettle();
        expect(
          find.text('interrupted-whole-detail', skipOffstage: false),
          findsNothing,
        );
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
      }
    },
  );

  for (final (platform, materialRoute) in [
    (TargetPlatform.android, false),
    (TargetPlatform.android, true),
    (TargetPlatform.windows, false),
    (TargetPlatform.windows, true),
  ]) {
    testWidgets(
      'route slide preserves page state ($platform, material: $materialRoute)',
      (tester) async {
        final navigatorKey = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigatorKey,
            theme: ThemeData(
              platform: platform,
              pageTransitionsTheme: const PageTransitionsTheme(
                builders: {
                  TargetPlatform.android: AppPageTransitionsBuilder(),
                  TargetPlatform.windows: AppPageTransitionsBuilder(),
                },
              ),
            ),
            home: const Scaffold(),
          ),
        );
        final navigator = navigatorKey.currentState!;
        const page = _StateProbe(label: 'route-state');
        unawaited(
          navigator.push(
            materialRoute
                ? MaterialPageRoute<void>(builder: (_) => page)
                : buildAppPageRoute<void>(
                    context: navigator.context,
                    child: page,
                  ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        final state = tester.state<_StateProbeState>(find.byType(_StateProbe));
        expect(
          find.ancestor(
            of: find.byType(_StateProbe),
            matching: find.byType(SlideTransition),
          ),
          findsOneWidget,
        );
        expect(find.byType(ShaderMask), findsNothing);
        await tester.pumpAndSettle();
        expect(
          tester.state<_StateProbeState>(find.byType(_StateProbe)),
          same(state),
        );
        expect(find.byType(ShaderMask), findsNothing);
        navigator.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(
          tester.state<_StateProbeState>(find.byType(_StateProbe)),
          same(state),
        );
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'route content slides from the right while narrow headers stay fixed',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: regions('home')),
      );
      final navigator = navigatorKey.currentState!;
      final expectedHeader = tester.getRect(
        find.byKey(const ValueKey('home-header')),
      );
      unawaited(
        navigator.push(
          buildAppPageRoute<void>(
            context: navigator.context,
            child: regions('detail'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      final header = find.byKey(const ValueKey('detail-header'));
      final body = find.byKey(const ValueKey('detail-body'));
      final enteringHeader = tester.getRect(header);
      final enteringBody = tester.getRect(body);
      expect(
        tester
            .widgetList<Opacity>(
              find.ancestor(of: header, matching: find.byType(Opacity)),
            )
            .any((opacity) => opacity.opacity > 0 && opacity.opacity < 1),
        isTrue,
      );
      await tester.pumpAndSettle();
      final settledHeader = tester.getRect(header);
      final settledBody = tester.getRect(body);
      expect(enteringHeader, settledHeader);
      expect(enteringBody.left, greaterThan(settledBody.left));
      expect(enteringBody.size, settledBody.size);
      expect(
        find.byKey(const ValueKey('home-header'), skipOffstage: false),
        findsOneWidget,
      );
      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getRect(header), settledHeader);
      expect(tester.getRect(body).left, greaterThan(settledBody.left));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('home-header'))),
        expectedHeader,
      );
      expect(find.byKey(const ValueKey('home-header')), findsOneWidget);
    },
  );

  testWidgets('detail routes slide body over the old page and fade header', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final surface = GlobalKey();

    Future<Color> pixelAt(double xFraction) async {
      return (await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(surface),
        );
        final image = await boundary.toImage();
        final data = await image.toByteData();
        final x = (image.width * xFraction).floor();
        final offset = ((image.height * 0.75).floor() * image.width + x) * 4;
        final color = Color.fromARGB(
          data!.getUint8(offset + 3),
          data.getUint8(offset),
          data.getUint8(offset + 1),
          data.getUint8(offset + 2),
        );
        image.dispose();
        return color;
      }))!;
    }

    await tester.pumpWidget(
      RepaintBoundary(
        key: surface,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: regions('home', backgroundColor: Colors.red),
        ),
      ),
    );

    unawaited(
      navigatorKey.currentState!.push(
        buildAppPageRoute<void>(
          context: navigatorKey.currentContext!,
          child: regions(
            'detail',
            backgroundColor: Colors.blue,
            transparentPage: true,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    final body = find.byKey(const ValueKey('detail-body'));
    final header = find.byKey(const ValueKey('detail-header'));
    final midBody = tester.getRect(body);
    final midHeader = tester.getRect(header);
    expect(find.byKey(const ValueKey('home-body')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-header')), findsOneWidget);
    expect(await pixelAt(0.1), const Color(0xfff44336));
    expect(await pixelAt(0.9), const Color(0xff2196f3));
    final headerOpacity = tester.widgetList<Opacity>(
      find.ancestor(of: header, matching: find.byType(Opacity)),
    );
    expect(headerOpacity.length, 1);
    expect(headerOpacity.single.opacity, greaterThan(0));
    expect(headerOpacity.single.opacity, lessThan(1));
    expect(
      find.ancestor(of: body, matching: find.byType(FadeTransition)),
      findsNothing,
    );
    expect(
      find.ancestor(of: body, matching: find.byType(SlideTransition)),
      findsOneWidget,
    );
    expect(find.byType(ShaderMask), findsNothing);
    await tester.pumpAndSettle();
    final settledBody = tester.getRect(body);
    final settledHeader = tester.getRect(header);
    expect(midBody.left, greaterThan(settledBody.left));
    expect(midBody.size, settledBody.size);
    expect(midHeader.left - settledHeader.left, closeTo(0, 0.01));

    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    final popBody = tester.getRect(body);
    final popHeader = tester.getRect(header);
    expect(find.byKey(const ValueKey('home-body')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-header')), findsOneWidget);
    expect(await pixelAt(0.1), const Color(0xfff44336));
    expect(await pixelAt(0.9), const Color(0xff2196f3));
    expect(popBody.left, greaterThan(settledBody.left));
    expect(popHeader.left - settledHeader.left, closeTo(0, 0.01));
    await tester.pumpAndSettle();
  });

  testWidgets('batch routes retain their own header transition', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigatorKey, home: regions('home')),
    );
    final navigator = navigatorKey.currentState!;
    unawaited(
      navigator.push(
        buildAppPageRoute<void>(
          context: navigator.context,
          fadeHeader: false,
          child: regions('batch'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(
      navigator.push(
        buildAppPageRoute<void>(
          context: navigator.context,
          fadeHeader: false,
          child: regions('detail'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));

    final incoming = find.byKey(const ValueKey('detail-header'));
    final outgoing = find.byKey(
      const ValueKey('batch-header'),
      skipOffstage: false,
    );
    expect(outgoing, findsOneWidget);
    expect(incoming, findsOneWidget);
    expect(
      find.ancestor(of: incoming, matching: find.byType(Opacity)),
      findsNothing,
    );
    expect(
      find.ancestor(of: outgoing, matching: find.byType(Opacity)),
      findsNothing,
    );
    expect(
      find.ancestor(of: incoming, matching: find.byType(SlideTransition)),
      findsOneWidget,
    );
  });

  testWidgets('tab headers stay fixed while content slides independently', (
    tester,
  ) async {
    final index = ValueNotifier(0);
    addTearDown(index.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppFadeThroughIndexedStack(
          indexListenable: index,
          separateHeader: true,
          children: [regions('first'), regions('second')],
        ),
      ),
    );
    final expectedHeader = tester.getRect(
      find.byKey(const ValueKey('first-header')),
    );
    index.value = 1;
    await tester.pump();
    final incomingHeaderFade = find.ancestor(
      of: find.byKey(const ValueKey('second-header')),
      matching: find.byType(FadeTransition),
    );
    expect(
      tester.widget<FadeTransition>(incomingHeaderFade.first).opacity.value,
      0,
    );
    await tester.pump(const Duration(milliseconds: 70));
    expect(
      tester.getRect(find.byKey(const ValueKey('second-header'))),
      expectedHeader,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('second-body'))).left,
      greaterThan(0),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const ValueKey('second-body'))).left, 0);
  });

  testWidgets('zero duration switches immediately without motion transitions', (
    tester,
  ) async {
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    var completedIndex = -1;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppFadeThroughIndexedStack(
            indexListenable: index,
            duration: Duration.zero,
            onTransitionCompleted: (value) => completedIndex = value,
            children: const [
              _StateProbe(label: 'first'),
              _StateProbe(label: 'second'),
            ],
          ),
        ),
      ),
    );

    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsNothing);

    index.value = 1;
    await tester.pump();

    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);
    expect(completedIndex, 1);
    expect(
      find.descendant(
        of: find.byType(AppFadeThroughIndexedStack),
        matching: find.byType(FractionalTranslation),
      ),
      findsNothing,
    );
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'slide goes directly between nonadjacent pages in 300 ms on $platform',
      (tester) async {
        final index = ValueNotifier<int>(0);
        addTearDown(index.dispose);
        final coordinator = UiInteractionCoordinator.instance;
        coordinator.resetForTest();
        addTearDown(coordinator.resetForTest);
        final builds = <int>[0, 0, 0, 0];
        final completed = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            home: AppFadeThroughIndexedStack.lazy(
              indexListenable: index,
              duration: kAppMotionSlow,
              itemCount: 4,
              onTransitionCompleted: completed.add,
              itemBuilder: (_, page) {
                builds[page]++;
                return Stack(
                  children: [
                    regions('page-$page'),
                    _StateProbe(label: 'state-$page'),
                  ],
                );
              },
            ),
          ),
        );
        final firstState = tester.state(
          find.ancestor(
            of: find.text('state-0'),
            matching: find.byType(_StateProbe),
          ),
        );
        final body = find.byKey(const ValueKey('page-0-body'));
        final width = tester.getSize(body).width;
        final headerLeft = tester
            .getTopLeft(find.byKey(const ValueKey('page-0-header')))
            .dx;
        var idleWork = false;
        index.value = 3;
        coordinator.scheduleAfterIdle(
          key: 'slide-idle-work',
          generation: coordinator.generation,
          priority: 0,
          task: () async => idleWork = true,
        );
        await tester.pump();
        expect(builds, [1, 0, 0, 1]);
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('page-3-body'))).dx,
          width,
        );
        expect(completed, isEmpty);
        expect(coordinator.isInteracting, isTrue);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        final outgoing = tester.getRect(body);
        final incoming = tester.getRect(
          find.byKey(const ValueKey('page-3-body')),
        );
        expect(outgoing.left, lessThan(0));
        expect(incoming.left, allOf(greaterThan(0), lessThan(width)));
        expect(outgoing.right, closeTo(incoming.left, 0.01));
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('page-3-header'))).dx,
          closeTo(headerLeft + incoming.left, 0.01),
        );
        expect(idleWork, isFalse);
        expect(find.byType(Opacity), findsNothing);
        expect(find.byType(PageView), findsNothing);
        expect(builds, [
          1,
          0,
          0,
          1,
        ], reason: 'Animation frames reuse the page subtree.');
        await tester.pump(const Duration(milliseconds: 149));
        expect(completed, isEmpty);
        await tester.pump(const Duration(milliseconds: 2));
        expect(completed, [3]);
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('page-3-body'))).dx,
          0,
        );
        await tester.pump(coordinator.idleDelay);
        await tester.pumpAndSettle();
        expect(idleWork, isTrue);
        expect(coordinator.isInteracting, isFalse);
        index.value = 0;
        await tester.pump();
        expect(tester.getTopLeft(body).dx, -width);
        await tester.pump(const Duration(milliseconds: 150));
        expect(
          tester.getRect(find.byKey(const ValueKey('page-3-body'))).left,
          greaterThan(0),
        );
        expect(tester.getRect(body).left, lessThan(0));
        await tester.pumpAndSettle();
        expect(completed, [3, 0]);
        expect(builds, [1, 0, 0, 1]);
        expect(
          tester.state(
            find.ancestor(
              of: find.text('state-0'),
              matching: find.byType(_StateProbe),
            ),
          ),
          same(firstState),
        );
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'slide changes headers independently on $platform',
      (tester) async {
        final index = ValueNotifier<int>(0);
        addTearDown(index.dispose);
        var builds = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 420,
                height: 500,
                child: AppFadeThroughIndexedStack.lazy(
                  indexListenable: index,
                  itemCount: 4,
                  separateHeader: true,
                  duration: kAppMotionSlow,
                  itemBuilder: (_, page) {
                    builds++;
                    return regions('fixed-$page', transparentPage: true);
                  },
                ),
              ),
            ),
          ),
        );
        final oldHeader = find.byKey(const ValueKey('fixed-0-header'));
        final newHeader = find.byKey(const ValueKey('fixed-3-header'));
        final newBody = find.byKey(const ValueKey('fixed-3-body'));
        final headerRect = tester.getRect(oldHeader);
        final left = tester
            .getRect(find.byKey(const ValueKey('fixed-0-body')))
            .left;
        index.value = 3;
        await tester.pump();
        expect(tester.getRect(newHeader), headerRect);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(tester.getRect(oldHeader), headerRect);
        expect(tester.getRect(newHeader), headerRect);
        expect(tester.getRect(newBody).left, greaterThan(left));
        final tabFades = find.descendant(
          of: find.byType(AppFadeThroughIndexedStack),
          matching: find.byType(FadeTransition),
        );
        final oldFade = tester.widget<FadeTransition>(
          find.ancestor(of: oldHeader, matching: tabFades),
        );
        final newFade = tester.widget<FadeTransition>(
          find.ancestor(of: newHeader, matching: tabFades),
        );
        expect(oldFade.opacity.value, allOf(greaterThan(0), lessThan(1)));
        expect(
          oldFade.opacity.value + newFade.opacity.value,
          closeTo(1, 0.001),
        );
        expect(find.ancestor(of: newBody, matching: tabFades), findsNothing);
        expect(
          find.ancestor(of: newBody, matching: find.byType(Opacity)),
          findsNothing,
        );
        expect(builds, 2);
        await tester.pumpAndSettle();
        index.value = 0;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(tester.getRect(oldHeader), headerRect);
        expect(tester.getRect(newHeader), headerRect);
        expect(
          tester.getRect(find.byKey(const ValueKey('fixed-0-body'))).left,
          lessThan(left),
        );
        await tester.pumpAndSettle();
        expect(builds, 2);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  for (final elapsed in [80, 200]) {
    testWidgets('slide completes the latest rapid switch after $elapsed ms', (
      tester,
    ) async {
      final index = ValueNotifier<int>(0);
      addTearDown(index.dispose);
      final coordinator = UiInteractionCoordinator.instance;
      coordinator.resetForTest();
      addTearDown(coordinator.resetForTest);
      final completed = <int>[];
      final built = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: AppFadeThroughIndexedStack.lazy(
            indexListenable: index,
            itemCount: 4,
            duration: kAppMotionSlow,
            onTransitionCompleted: completed.add,
            itemBuilder: (_, page) {
              built.add(page);
              return Text('slide-$page');
            },
          ),
        ),
      );
      index.value = 1;
      await tester.pump();
      await tester.pump();
      await tester.pump(Duration(milliseconds: elapsed));
      final before = _translationFor(tester, 'slide-0');
      index.value = 3;
      await tester.pump();
      expect(_translationFor(tester, 'slide-0'), before);
      expect(find.text('slide-2', skipOffstage: false), findsNothing);
      await tester.pumpAndSettle();
      expect(built, [0, 1, 3]);
      expect(completed, [3]);
      expect(find.text('slide-3'), findsOneWidget);
      await tester.pump(coordinator.idleDelay);
      expect(UiInteractionCoordinator.instance.isInteracting, isFalse);
      index.value = 0;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final beforeReturn = _translationFor(tester, 'slide-3');
      index.value = 3;
      await tester.pump();
      expect(_translationFor(tester, 'slide-3'), beforeReturn);
      await tester.pumpAndSettle();
      expect(completed, [3, 3]);
      expect(find.text('slide-3'), findsOneWidget);
      await tester.pump(coordinator.idleDelay);
      expect(UiInteractionCoordinator.instance.isInteracting, isFalse);
      index.value = 1;
      index.value = 3;
      index.value = 0;
      await tester.pumpAndSettle();
      expect(completed, [3, 3, 0]);
      expect(find.text('slide-0'), findsOneWidget);
      index.value = 1;
      index.value = 0;
      index.value = 1;
      await tester.pumpAndSettle();
      expect(completed, [3, 3, 0, 1]);
      expect(find.text('slide-1'), findsOneWidget);
    });
  }

  testWidgets('slide keeps its position when retargeted to the other side', (
    tester,
  ) async {
    final index = ValueNotifier<int>(1);
    addTearDown(index.dispose);
    final completed = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AppFadeThroughIndexedStack.lazy(
          indexListenable: index,
          itemCount: 4,
          duration: kAppMotionSlow,
          onTransitionCompleted: completed.add,
          itemBuilder: (_, page) => Text('opposite-$page'),
        ),
      ),
    );
    index.value = 3;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final before = _translationFor(tester, 'opposite-3');
    index.value = 0;
    await tester.pump();
    expect(
      _translationFor(tester, 'opposite-3').dx,
      closeTo(before.dx, 0.0001),
    );
    await tester.pump();
    expect(find.text('opposite-1'), findsNothing);
    await tester.pump(const Duration(milliseconds: 40));
    final beforeReverse = _translationFor(tester, 'opposite-3');
    index.value = 3;
    await tester.pump();
    expect(_translationFor(tester, 'opposite-3'), beforeReverse);
    await tester.pump(const Duration(milliseconds: 40));
    final beforeResume = _translationFor(tester, 'opposite-3');
    index.value = 0;
    await tester.pump();
    expect(_translationFor(tester, 'opposite-3'), beforeResume);
    await tester.pumpAndSettle();
    expect(completed, [0]);
    expect(find.text('opposite-0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('slide respects reduced motion', (tester) async {
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    final completed = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: AppFadeThroughIndexedStack.lazy(
            indexListenable: index,
            itemCount: 4,
            duration: kAppMotionSlow,
            onTransitionCompleted: completed.add,
            itemBuilder: (_, page) => Text('reduced-$page'),
          ),
        ),
      ),
    );
    index.value = 3;
    await tester.pump();
    expect(find.text('reduced-3'), findsOneWidget);
    expect(find.text('reduced-0'), findsNothing);
    expect(completed, [3]);
    expect(
      tester
          .widgetList<FractionalTranslation>(
            find.ancestor(
              of: find.text('reduced-3'),
              matching: find.byType(FractionalTranslation),
            ),
          )
          .every((widget) => widget.translation == Offset.zero),
      isTrue,
    );
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpAndSettle();
  });

  testWidgets('tabs switch immediately and preserve cached page state', (
    tester,
  ) async {
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    const firstKey = ValueKey<String>('instant-first-state');
    final completed = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AppFadeThroughIndexedStack.lazy(
          indexListenable: index,
          duration: Duration.zero,
          itemCount: 2,
          onTransitionCompleted: completed.add,
          itemBuilder: (_, pageIndex) => pageIndex == 0
              ? const _StateProbe(key: firstKey, label: 'first')
              : const _StateProbe(label: 'second'),
        ),
      ),
    );
    final originalState = tester.state<_StateProbeState>(find.byKey(firstKey));
    index.value = 1;
    await tester.pump();
    expect(find.text('second'), findsOneWidget);
    expect(find.text('first'), findsNothing);
    expect(completed, [1]);
    expect(find.byType(ShaderMask), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AppFadeThroughIndexedStack),
        matching: find.byType(SlideTransition),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(AppFadeThroughIndexedStack),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
    expect(tester.binding.transientCallbackCount, 0);
    index.value = 0;
    await tester.pump();
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsNothing);
    expect(completed, [1, 0]);
    expect(
      tester.state<_StateProbeState>(find.byKey(firstKey)),
      same(originalState),
    );
  });

  testWidgets(
    'slides in index order, keeps page states, and completes latest switch',
    (tester) async {
      final index = ValueNotifier<int>(0);
      addTearDown(index.dispose);
      var completedIndex = -1;
      final firstKey = GlobalKey<_StateProbeState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppFadeThroughIndexedStack(
              indexListenable: index,
              onTransitionCompleted: (value) => completedIndex = value,
              children: [
                _StateProbe(key: firstKey, label: 'first'),
                const _StateProbe(label: 'second'),
                const _StateProbe(label: 'third'),
              ],
            ),
          ),
        ),
      );

      final originalState = firstKey.currentState;
      index.value = 1;
      await tester.pump();

      expect(find.text('first'), findsOneWidget);
      expect(find.text('second'), findsOneWidget);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final outgoingTranslation = _translationFor(tester, 'first');
      final incomingTranslation = _translationFor(tester, 'second');
      expect(outgoingTranslation.dx, lessThan(0));
      expect(incomingTranslation.dx, greaterThan(0));
      expect(
        outgoingTranslation.dx.abs(),
        lessThan(incomingTranslation.dx.abs()),
      );
      expect(_opacityFor(tester, 'second'), 1);
      expect(_paintOrder(tester).last, const ValueKey('app_indexed_page_1'));
      expect(
        find.descendant(
          of: find.byType(AppFadeThroughIndexedStack),
          matching: find.byType(ScaleTransition),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(AppFadeThroughIndexedStack),
          matching: find.byType(PageView),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(AppFadeThroughIndexedStack),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );

      index.value = 2;
      await tester.pump();
      await tester.pump();
      expect(find.text('second'), findsNothing);
      expect(find.text('third'), findsOneWidget);
      await tester.pumpAndSettle();

      expect(completedIndex, 2);
      expect(firstKey.currentState, same(originalState));
      expect(find.text('third'), findsOneWidget);
    },
  );

  testWidgets(
    'lazy stack builds the active item once and preserves cached pages',
    (tester) async {
      final index = ValueNotifier<int>(0);
      addTearDown(index.dispose);
      final coordinator = UiInteractionCoordinator.instance;
      coordinator.resetForTest();
      addTearDown(coordinator.resetForTest);
      final buildCounts = <int>[0, 0, 0];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppFadeThroughIndexedStack.lazy(
              indexListenable: index,
              itemCount: 3,
              itemBuilder: (context, itemIndex) {
                buildCounts[itemIndex]++;
                return Text('lazy-$itemIndex');
              },
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(buildCounts, <int>[1, 0, 0]);
      expect(_paintOrder(tester), [const ValueKey('app_indexed_page_0')]);
      index.value = 1;
      await tester.pump();
      expect(buildCounts, <int>[1, 1, 0]);
      await tester.pump(const Duration(milliseconds: 200));
      expect(buildCounts, <int>[1, 1, 0]);

      await tester.pumpAndSettle();
      expect(buildCounts[2], 0);
      expect(_paintOrder(tester), [
        const ValueKey('app_indexed_page_0'),
        const ValueKey('app_indexed_page_1'),
      ]);

      index.value = 0;
      await tester.pumpAndSettle();
      expect(buildCounts, <int>[1, 1, 0]);
    },
  );

  testWidgets('lazy stack skips unvisited pages during rapid switching', (
    tester,
  ) async {
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    final created = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AppFadeThroughIndexedStack.lazy(
          indexListenable: index,
          itemCount: 3,
          itemBuilder: (_, index) {
            created.add(index);
            return _StateProbe(label: 'lazy-$index');
          },
        ),
      ),
    );
    index.value = 1;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    index.value = 2;
    await tester.pumpAndSettle();
    expect(created, [0, 1, 2]);
    expect(find.text('lazy-2'), findsOneWidget);
    expect(find.text('lazy-1', skipOffstage: false), findsOneWidget);
  });

  testWidgets('cached hidden pages do not layout during switching or resize', (
    tester,
  ) async {
    final index = ValueNotifier<int>(0);
    final size = ValueNotifier<double>(300);
    addTearDown(index.dispose);
    addTearDown(size.dispose);
    final layouts = <int>[0, 0, 0];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: ValueListenableBuilder<double>(
            valueListenable: size,
            builder: (_, extent, _) => SizedBox(
              width: extent,
              height: extent,
              child: AppFadeThroughIndexedStack.lazy(
                indexListenable: index,
                itemCount: 3,
                itemBuilder: (_, page) => LayoutBuilder(
                  builder: (_, constraints) {
                    layouts[page]++;
                    return Text('page-$page width=${constraints.maxWidth}');
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    index.value = 1;
    await tester.pumpAndSettle();
    final hiddenLayouts = layouts[0];
    size.value = 400;
    await tester.pump();
    expect(layouts[0], hiddenLayouts);
    expect(find.text('page-1 width=400.0'), findsOneWidget);
    index.value = 2;
    await tester.pumpAndSettle();
    expect(layouts[0], hiddenLayouts);
    index.value = 0;
    await tester.pumpAndSettle();
    expect(find.text('page-0 width=400.0'), findsOneWidget);
    expect(layouts[0], greaterThan(hiddenLayouts));
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden motion regions reuse their configuration', (
    tester,
  ) async {
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    final builds = [0, 0, 0];
    await tester.pumpWidget(
      MaterialApp(
        home: AppFadeThroughIndexedStack.lazy(
          indexListenable: index,
          itemCount: 3,
          separateHeader: true,
          itemBuilder: (_, page) => Column(
            children: [
              AppPageHeaderTransition(child: Text('cached-header-$page')),
              Expanded(
                child: _BuildCountingContent(
                  onBuild: () => builds[page]++,
                  child: Text('cached-content-$page'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    index.value = 1;
    await tester.pumpAndSettle();
    final hiddenBuilds = builds[0];
    index.value = 2;
    await tester.pumpAndSettle();
    index.value = 1;
    await tester.pumpAndSettle();
    expect(builds[0], hiddenBuilds);
    index.value = 0;
    await tester.pumpAndSettle();
    expect(find.text('cached-content-0'), findsOneWidget);
    expect(builds[0], greaterThan(hiddenBuilds));
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden cached pages pause provider subscriptions until return', (
    tester,
  ) async {
    final index = ValueNotifier<int>(0);
    final updates = StreamController<int>.broadcast();
    final valueProvider = StreamProvider<int>((_) => updates.stream);
    final builds = <int>[0, 0];
    addTearDown(index.dispose);
    addTearDown(updates.close);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AppFadeThroughIndexedStack.lazy(
            indexListenable: index,
            itemCount: 2,
            itemBuilder: (_, page) => Consumer(
              builder: (_, ref, _) {
                builds[page]++;
                return Text(
                  'page-$page value=${ref.watch(valueProvider).value}',
                );
              },
            ),
          ),
        ),
      ),
    );
    updates.add(1);
    await tester.pump();
    index.value = 1;
    await tester.pumpAndSettle();
    final hiddenBuilds = builds[0];
    final activeBuilds = builds[1];
    updates.add(2);
    await tester.pump();
    await tester.pump();
    expect(builds[0], hiddenBuilds);
    expect(builds[1], greaterThan(activeBuilds));
    index.value = 0;
    await tester.pumpAndSettle();
    expect(find.text('page-0 value=2'), findsOneWidget);
  });

  testWidgets('lazy pages preserve scroll and use the latest theme on return', (
    tester,
  ) async {
    final index = ValueNotifier<int>(0);
    final dark = ValueNotifier<bool>(false);
    final scroll = ScrollController();
    addTearDown(index.dispose);
    addTearDown(dark.dispose);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder<bool>(
        valueListenable: dark,
        builder: (_, isDark, _) => MaterialApp(
          theme: ThemeData(
            brightness: isDark ? Brightness.dark : Brightness.light,
          ),
          home: AppFadeThroughIndexedStack.lazy(
            indexListenable: index,
            itemCount: 2,
            itemBuilder: (_, page) => page == 1
                ? const Text('second')
                : Builder(
                    builder: (context) => ListView.builder(
                      controller: scroll,
                      itemExtent: 60,
                      itemCount: 60,
                      itemBuilder: (_, row) =>
                          Text('${Theme.of(context).brightness.name} row-$row'),
                    ),
                  ),
          ),
        ),
      ),
    );
    scroll.jumpTo(600);
    await tester.pump();
    index.value = 1;
    await tester.pumpAndSettle();
    dark.value = true;
    await tester.pumpAndSettle();
    expect(scroll.offset, 600);
    index.value = 0;
    await tester.pumpAndSettle();
    expect(scroll.offset, 600);
    expect(find.text('dark row-10'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lazy stack keeps remaining states when its page count changes', (
    tester,
  ) async {
    final index = ValueNotifier<int>(0);
    final count = ValueNotifier<int>(3);
    addTearDown(index.dispose);
    addTearDown(count.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<int>(
          valueListenable: count,
          builder: (context, itemCount, _) => AppFadeThroughIndexedStack.lazy(
            indexListenable: index,
            itemCount: itemCount,
            duration: Duration.zero,
            itemBuilder: (_, itemIndex) =>
                _StateProbe(label: 'page-$itemIndex'),
          ),
        ),
      ),
    );
    final firstState = tester.state<_StateProbeState>(find.byType(_StateProbe));
    index.value = 1;
    await tester.pumpAndSettle();
    final secondState = tester.state<_StateProbeState>(
      find.byType(_StateProbe),
    );
    index.value = 2;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    count.value = 2;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('page-1'), findsOneWidget);
    expect(
      tester.state<_StateProbeState>(find.byType(_StateProbe)),
      same(secondState),
    );
    index.value = 0;
    await tester.pumpAndSettle();
    expect(
      tester.state<_StateProbeState>(find.byType(_StateProbe)),
      same(firstState),
    );
    count.value = 3;
    await tester.pump();
    expect(
      tester.state<_StateProbeState>(find.byType(_StateProbe)),
      same(firstState),
    );
    count.value = 0;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(_StateProbe), findsNothing);
  });

  testWidgets('lower indexes slide in from the left', (tester) async {
    final index = ValueNotifier<int>(2);
    addTearDown(index.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppFadeThroughIndexedStack(
            indexListenable: index,
            children: const [
              _StateProbe(label: 'first'),
              _StateProbe(label: 'second'),
              _StateProbe(label: 'third'),
            ],
          ),
        ),
      ),
    );

    index.value = 0;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(_translationFor(tester, 'third').dx, greaterThan(0));
    expect(_translationFor(tester, 'first').dx, lessThan(0));
    expect(_paintOrder(tester).last, const ValueKey('app_indexed_page_0'));
    expect(find.text('second'), findsNothing);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'tab semantics and focus resume only after sliding on $platform',
      (tester) async {
        final index = ValueNotifier<int>(0);
        final focus = [FocusNode(), FocusNode()];
        addTearDown(index.dispose);
        for (final node in focus) {
          addTearDown(node.dispose);
        }
        await tester.pumpWidget(
          MaterialApp(
            home: AppFadeThroughIndexedStack.lazy(
              indexListenable: index,
              itemCount: 2,
              duration: kAppMotionSlow,
              separateHeader: true,
              itemBuilder: (_, page) => Focus(
                focusNode: focus[page],
                child: Column(
                  children: [
                    AppPageHeaderTransition(
                      child: Text('semantic-header-$page'),
                    ),
                    Expanded(
                      child: AppPageContentTransition(
                        child: Semantics(
                          container: true,
                          label: 'semantic-content-$page',
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(find.semantics.byLabel('semantic-content-0'), findsOne);
        for (final next in [1, 0]) {
          index.value = next;
          await tester.pump();
          expect(find.semantics.byLabel(RegExp('semantic-')), findsNothing);
          expect(focus.every((node) => !node.canRequestFocus), isTrue);
          await tester.pump(const Duration(milliseconds: 150));
          expect(find.semantics.byLabel(RegExp('semantic-')), findsNothing);
          await tester.pumpAndSettle();
          expect(find.semantics.byLabel('semantic-content-$next'), findsOne);
          expect(
            find.semantics.byLabel('semantic-content-${1 - next}'),
            findsNothing,
          );
          focus[next].requestFocus();
          await tester.pump();
          expect(focus[next].hasFocus, isTrue);
        }
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('inactive pages isolate layout, tickers, focus and semantics', (
    tester,
  ) async {
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppFadeThroughIndexedStack(
            indexListenable: index,
            children: const [
              _StateProbe(label: 'first'),
              _StateProbe(label: 'second'),
            ],
          ),
        ),
      ),
    );

    index.value = 1;
    await tester.pumpAndSettle();
    final hidden = find.text('first', skipOffstage: false);
    expect(hidden, findsOneWidget);
    expect(
      tester
          .widgetList<Offstage>(
            find.ancestor(
              of: hidden,
              matching: find.byWidgetPredicate(
                (widget) => widget is Offstage,
                skipOffstage: false,
              ),
            ),
          )
          .any((widget) => widget.offstage),
      isTrue,
    );
    expect(TickerMode.valuesOf(tester.element(hidden)).enabled, isFalse);
    expect(
      tester
          .widgetList<ExcludeFocus>(
            find.ancestor(
              of: hidden,
              matching: find.byType(ExcludeFocus, skipOffstage: false),
            ),
          )
          .any((widget) => widget.excluding),
      isTrue,
    );
    expect(
      tester
          .widgetList<ExcludeSemantics>(
            find.ancestor(
              of: hidden,
              matching: find.byType(ExcludeSemantics, skipOffstage: false),
            ),
          )
          .any((widget) => widget.excluding),
      isTrue,
    );
    expect(
      tester
          .widgetList<IgnorePointer>(
            find.ancestor(
              of: hidden,
              matching: find.byType(IgnorePointer, skipOffstage: false),
            ),
          )
          .any((widget) => widget.ignoring),
      isTrue,
    );

    index.value = 0;
    await tester.pump();
    expect(TickerMode.valuesOf(tester.element(hidden)).enabled, isTrue);
  });

  testWidgets('reduced motion makes routes, expansion and tabs immediate', (
    tester,
  ) async {
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    var completed = false;
    late PageRoute<void> route;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              route = buildAppPageRoute<void>(
                context: context,
                child: const SizedBox(),
              );
              expect(
                appExpansionAnimationStyle(context),
                AnimationStyle.noAnimation,
              );
              return Scaffold(
                body: AppFadeThroughIndexedStack(
                  indexListenable: index,
                  onTransitionCompleted: (_) => completed = true,
                  children: const [
                    _StateProbe(label: 'first'),
                    _StateProbe(label: 'second'),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );

    index.value = 1;
    await tester.pump();

    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
    expect(completed, isTrue);
    expect(find.text('second'), findsOneWidget);
  });

  group('AppRollingNumber', () {
    testWidgets('rolls upwards when number increments', (tester) async {
      final numberNotifier = ValueNotifier<int>(1);
      addTearDown(numberNotifier.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: numberNotifier,
              builder: (context, value, _) => AppRollingNumber(number: value),
            ),
          ),
        ),
      );

      expect(find.text('1'), findsOneWidget);

      numberNotifier.value = 2;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

      final translations1 = tester
          .widgetList<FractionalTranslation>(
            find.ancestor(
              of: find.text('1'),
              matching: find.byType(FractionalTranslation),
            ),
          )
          .map((w) => w.translation)
          .toList();
      final translations2 = tester
          .widgetList<FractionalTranslation>(
            find.ancestor(
              of: find.text('2'),
              matching: find.byType(FractionalTranslation),
            ),
          )
          .map((w) => w.translation)
          .toList();

      expect(translations1.any((t) => t.dy < 0), isTrue); // outgoing moves up
      expect(
        translations2.any((t) => t.dy > 0),
        isTrue,
      ); // incoming from bottom

      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      expect(find.text('1'), findsNothing);
    });

    testWidgets('rolls downwards when number decrements', (tester) async {
      final numberNotifier = ValueNotifier<int>(5);
      addTearDown(numberNotifier.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: numberNotifier,
              builder: (context, value, _) => AppRollingNumber(number: value),
            ),
          ),
        ),
      );

      expect(find.text('5'), findsOneWidget);

      numberNotifier.value = 4;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('5'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);

      final translations5 = tester
          .widgetList<FractionalTranslation>(
            find.ancestor(
              of: find.text('5'),
              matching: find.byType(FractionalTranslation),
            ),
          )
          .map((w) => w.translation)
          .toList();
      final translations4 = tester
          .widgetList<FractionalTranslation>(
            find.ancestor(
              of: find.text('4'),
              matching: find.byType(FractionalTranslation),
            ),
          )
          .map((w) => w.translation)
          .toList();

      expect(translations5.any((t) => t.dy > 0), isTrue); // outgoing moves down
      expect(translations4.any((t) => t.dy < 0), isTrue); // incoming from top

      await tester.pumpAndSettle();
      expect(find.text('4'), findsOneWidget);
      expect(find.text('5'), findsNothing);
    });

    testWidgets('reduced motion updates number immediately', (tester) async {
      final numberNotifier = ValueNotifier<int>(1);
      addTearDown(numberNotifier.dispose);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<int>(
                valueListenable: numberNotifier,
                builder: (context, value, _) => AppRollingNumber(number: value),
              ),
            ),
          ),
        ),
      );

      expect(find.text('1'), findsOneWidget);

      numberNotifier.value = 2;
      await tester.pump();

      expect(find.text('2'), findsOneWidget);
      expect(find.text('1'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AppRollingNumber),
          matching: find.byType(FractionalTranslation),
        ),
        findsNothing,
      );
    });
  });
}

Offset _translationFor(WidgetTester tester, String label) {
  final finder = find.ancestor(
    of: find.text(label),
    matching: find.byType(FractionalTranslation),
  );
  return tester
      .widgetList<FractionalTranslation>(finder)
      .map((widget) => widget.translation)
      .firstWhere((translation) => translation.dx.abs() > 0.001);
}

double _opacityFor(WidgetTester tester, String label) {
  return tester
      .widgetList<Opacity>(
        find.ancestor(of: find.text(label), matching: find.byType(Opacity)),
      )
      .fold(1.0, (opacity, widget) => opacity * widget.opacity);
}

List<Key?> _paintOrder(WidgetTester tester) {
  final stack = tester
      .widgetList<Stack>(
        find.descendant(
          of: find.byType(AppFadeThroughIndexedStack),
          matching: find.byType(Stack),
        ),
      )
      .firstWhere(
        (candidate) =>
            candidate.children.every((child) => child.key is ValueKey<String>),
      );
  return stack.children.map((child) => child.key).toList(growable: false);
}
