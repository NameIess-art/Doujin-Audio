import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/widgets/app_transitions.dart';

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
  testWidgets(
    'slides in index order, keeps page states, and completes latest switch',
    (tester) async {
      var index = 0;
      var completedIndex = -1;
      late StateSetter update;
      final firstKey = GlobalKey<_StateProbeState>();

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Scaffold(
                body: AppFadeThroughIndexedStack(
                  index: index,
                  onTransitionCompleted: (value) => completedIndex = value,
                  children: [
                    _StateProbe(key: firstKey, label: 'first'),
                    const _StateProbe(label: 'second'),
                    const _StateProbe(label: 'third'),
                  ],
                ),
              );
            },
          ),
        ),
      );

      final originalState = firstKey.currentState;
      update(() => index = 1);
      await tester.pump();

      expect(find.text('first'), findsOneWidget);
      expect(find.text('second'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 80));
      expect(_translationFor(tester, 'first').dx, lessThan(0));
      expect(_translationFor(tester, 'second').dx, greaterThan(0));
      expect(
        find.descendant(
          of: find.byType(AppFadeThroughIndexedStack),
          matching: find.byType(ScaleTransition),
        ),
        findsNothing,
      );

      update(() => index = 2);
      await tester.pump();
      expect(find.text('second'), findsNothing);
      expect(find.text('third'), findsOneWidget);
      await tester.pumpAndSettle();

      expect(completedIndex, 2);
      expect(firstKey.currentState, same(originalState));
      expect(find.text('third'), findsOneWidget);
    },
  );

  testWidgets('lower indexes slide in from the left', (tester) async {
    var index = 2;
    late StateSetter update;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Scaffold(
              body: AppFadeThroughIndexedStack(
                index: index,
                children: const [
                  _StateProbe(label: 'first'),
                  _StateProbe(label: 'second'),
                  _StateProbe(label: 'third'),
                ],
              ),
            );
          },
        ),
      ),
    );

    update(() => index = 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(_translationFor(tester, 'third').dx, greaterThan(0));
    expect(_translationFor(tester, 'first').dx, lessThan(0));
    expect(find.text('second'), findsNothing);
  });

  testWidgets('shared-axis styles use horizontal and depth transforms', (
    tester,
  ) async {
    Future<Matrix4> matrixFor(AppPageTransitionStyle style) async {
      final key = UniqueKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => buildAppPageTransition(
              context: context,
              animation: const AlwaysStoppedAnimation<double>(0.5),
              secondaryAnimation: const AlwaysStoppedAnimation<double>(0),
              style: style,
              child: SizedBox(key: key),
            ),
          ),
        ),
      );
      return tester
          .widget<Transform>(
            find.ancestor(
              of: find.byKey(key),
              matching: find.byType(Transform),
            ),
          )
          .transform;
    }

    final horizontal = await matrixFor(AppPageTransitionStyle.sharedAxisX);
    expect(horizontal.storage[12], greaterThan(0));
    expect(horizontal.storage[0], 1);

    final depth = await matrixFor(AppPageTransitionStyle.sharedAxisZ);
    expect(depth.storage[12], 0);
    expect(depth.storage[0], inExclusiveRange(0.94, 1));
  });

  testWidgets('reduced motion makes routes, expansion and tabs immediate', (
    tester,
  ) async {
    var index = 0;
    var completed = false;
    late StateSetter update;
    late PageRoute<void> route;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
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
                  index: index,
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

    update(() => index = 1);
    await tester.pump();

    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
    expect(completed, isTrue);
    expect(find.text('second'), findsOneWidget);
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
