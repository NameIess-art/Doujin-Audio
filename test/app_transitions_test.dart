import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

void main() {
  testWidgets('page routes use main tab duration', (tester) async {
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

  testWidgets('route content reveals while headers change in place', (
    tester,
  ) async {
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
    expect(enteringBody, settledBody);
    expect(
      find.byKey(const ValueKey('home-header'), skipOffstage: false),
      findsOneWidget,
    );
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getRect(header), settledHeader);
    expect(tester.getRect(body), settledBody);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('home-header'))),
      expectedHeader,
    );
    expect(find.byKey(const ValueKey('home-header')), findsOneWidget);
  });

  testWidgets('detail routes reveal body and fade header', (tester) async {
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
    await tester.pump(const Duration(milliseconds: 60));

    final body = find.byKey(const ValueKey('detail-body'));
    final header = find.byKey(const ValueKey('detail-header'));
    final midBody = tester.getRect(body);
    final midHeader = tester.getRect(header);
    expect(find.byKey(const ValueKey('home-body')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-header')), findsOneWidget);
    expect(await pixelAt(0.1), const Color(0xff2196f3));
    expect(await pixelAt(0.9), const Color(0xfff44336));
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
      find.ancestor(of: body, matching: find.byType(ShaderMask)),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    final settledBody = tester.getRect(body);
    final settledHeader = tester.getRect(header);
    expect(midBody, settledBody);
    expect(midHeader.left - settledHeader.left, closeTo(0, 0.01));

    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    final popBody = tester.getRect(body);
    final popHeader = tester.getRect(header);
    expect(find.byKey(const ValueKey('home-body')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-header')), findsOneWidget);
    expect(await pixelAt(0.1), const Color(0xff2196f3));
    expect(await pixelAt(0.9), const Color(0xfff44336));
    expect(popBody, settledBody);
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
      find.ancestor(of: incoming, matching: find.byType(ShaderMask)),
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
    final incomingPage = find.ancestor(
      of: find.byKey(const ValueKey('second-header')),
      matching: find.byType(Scaffold),
    );
    expect(
      tester
          .widgetList<Opacity>(
            find.ancestor(of: incomingPage, matching: find.byType(Opacity)),
          )
          .any((opacity) => opacity.opacity == 0),
      isTrue,
      reason:
          'The incoming page surface must not obscure the old header immediately.',
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

  testWidgets('none style switches immediately without motion transitions', (
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
            style: AppIndexedStackTransitionStyle.none,
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

  testWidgets('gradient tabs reveal the new page without dimming either page', (
    tester,
  ) async {
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    final firstKey = GlobalKey<_StateProbeState>();
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
      MaterialApp(
        home: RepaintBoundary(
          key: surface,
          child: AppFadeThroughIndexedStack(
            indexListenable: index,
            style: AppIndexedStackTransitionStyle.gradient,
            duration: const Duration(milliseconds: 300),
            separateHeader: true,
            children: [
              Container(
                key: const ValueKey('gradient-old'),
                color: Colors.red,
                child: _StateProbe(key: firstKey, label: 'first'),
              ),
              const ColoredBox(
                key: ValueKey('gradient-new'),
                color: Colors.blue,
              ),
            ],
          ),
        ),
      ),
    );
    final originalState = firstKey.currentState;

    index.value = 1;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(await pixelAt(0.1), const Color(0xff2196f3));
    expect(await pixelAt(0.9), const Color(0xfff44336));
    expect(find.byType(ShaderMask), findsNWidgets(2));
    expect(find.byKey(const ValueKey('gradient-old')), findsOneWidget);
    expect(find.byKey(const ValueKey('gradient-new')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppFadeThroughIndexedStack),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
    await tester.pumpAndSettle();
    expect(find.byType(ShaderMask), findsNWidgets(2));

    index.value = 0;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(await pixelAt(0.1), const Color(0xff2196f3));
    expect(await pixelAt(0.9), const Color(0xfff44336));
    expect(find.byType(ShaderMask), findsNWidgets(2));
    expect(find.byKey(const ValueKey('gradient-old')), findsOneWidget);
    expect(find.byKey(const ValueKey('gradient-new')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(ShaderMask), findsNWidgets(2));
    expect(firstKey.currentState, same(originalState));
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
      coordinator.beginGeneration();
      final interaction = Object();
      coordinator.beginInteraction(interaction);
      addTearDown(() {
        coordinator.cancelInteraction(interaction);
        coordinator.resetForTest();
      });
      final buildCounts = <int>[0, 0, 0];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppFadeThroughIndexedStack.lazy(
              indexListenable: index,
              itemCount: 3,
              preloadUnvisited: false,
              itemBuilder: (context, itemIndex) {
                buildCounts[itemIndex]++;
                return Text('lazy-$itemIndex');
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(buildCounts, <int>[1, 0, 0]);
      index.value = 1;
      await tester.pump();
      expect(buildCounts, <int>[1, 1, 0]);

      coordinator.beginGeneration();
      coordinator.finishInteractionsForTest();
      await tester.pumpAndSettle();
      expect(buildCounts[2], 0);

      index.value = 0;
      await tester.pumpAndSettle();
      expect(buildCounts, <int>[1, 1, 0]);
    },
  );

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
    await tester.pump(const Duration(milliseconds: 80));

    expect(_translationFor(tester, 'third').dx, greaterThan(0));
    expect(_translationFor(tester, 'first').dx, lessThan(0));
    expect(_paintOrder(tester).last, const ValueKey('app_indexed_page_0'));
    expect(find.text('second'), findsNothing);
  });

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
              matching: find.byType(Offstage, skipOffstage: false),
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
      .widget<Opacity>(
        find.ancestor(of: find.text(label), matching: find.byType(Opacity)),
      )
      .opacity;
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
