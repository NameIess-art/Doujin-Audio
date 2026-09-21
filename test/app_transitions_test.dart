import 'dart:async';

import 'package:flutter/material.dart';
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
  Widget regions(String name) => Scaffold(
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
            child: SizedBox.expand(key: ValueKey('$name-body')),
          ),
        ),
      ],
    ),
  );

  testWidgets('route keeps header fixed while content slides horizontally', (
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
    await tester.pumpAndSettle();
    final settledHeader = tester.getRect(header);
    final settledBody = tester.getRect(body);
    final bodyPushOffset = enteringBody.left - settledBody.left;
    expect(enteringHeader, settledHeader);
    expect(bodyPushOffset, greaterThan(0));
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final bodyPopOffset = tester.getRect(body).left - settledBody.left;
    expect(tester.getRect(header), settledHeader);
    expect(bodyPopOffset, greaterThan(0));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('home-header'))),
      expectedHeader,
    );
    expect(find.byKey(const ValueKey('home-header')), findsOneWidget);
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
      tester.widgetList<Opacity>(find.ancestor(
        of: incomingPage,
        matching: find.byType(Opacity),
      )).any((opacity) => opacity.opacity == 0),
      isTrue,
      reason: 'The incoming page surface must not obscure the old header immediately.',
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
      expect(translations2.any((t) => t.dy > 0), isTrue); // incoming from bottom

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
