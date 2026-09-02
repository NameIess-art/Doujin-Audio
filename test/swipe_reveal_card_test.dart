import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/swipe_reveal_card.dart';
import 'package:doujin_audio/app/theme/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('default reveal colors follow the active color scheme', (
    tester,
  ) async {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.teal);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: scheme, useMaterial3: true),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 260,
              height: 96,
              child: SwipeRevealCard(
                shape: shape,
                actionLabel: 'Details',
                removeTooltip: 'Details',
                destructive: false,
                onRemove: () {},
                child: const SizedBox.expand(child: Text('Themed card')),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.text('Themed card'), const Offset(-180, 0));
    await tester.pumpAndSettle();
    final revealPane = tester.widget<DecoratedBox>(
      find.byWidgetPredicate((widget) {
        if (widget is! DecoratedBox) return false;
        final decoration = widget.decoration;
        return decoration is ShapeDecoration && decoration.gradient != null;
      }),
    );
    final decoration = revealPane.decoration as ShapeDecoration;
    expect(decoration.gradient!.colors.last, scheme.primary);
  });

  testWidgets(
    'default destructive reveal colors stay consistent in dark mode',
    (tester) async {
      final shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      );
      final lightScheme = ThemeAccentPreset.rose.colorScheme(Brightness.light);
      final darkScheme = ThemeAccentPreset.rose.colorScheme(Brightness.dark);

      Future<Color> revealColor(ThemeData theme) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 260,
                  height: 96,
                  child: SwipeRevealCard(
                    shape: shape,
                    actionLabel: 'Remove',
                    removeTooltip: 'Remove',
                    onRemove: () {},
                    child: const SizedBox.expand(
                      child: Text('Destructive card'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.drag(find.byType(SwipeRevealCard), const Offset(-180, 0));
        await tester.pumpAndSettle();
        final revealPane = tester.widget<DecoratedBox>(
          find.byWidgetPredicate((widget) {
            if (widget is! DecoratedBox) return false;
            final decoration = widget.decoration;
            return decoration is ShapeDecoration && decoration.gradient != null;
          }),
        );
        return (revealPane.decoration as ShapeDecoration).gradient!.colors.last;
      }

      final lightRevealColor = await revealColor(
        ThemeData(colorScheme: lightScheme, useMaterial3: true),
      );
      final darkRevealColor = await revealColor(
        ThemeData(colorScheme: darkScheme, useMaterial3: true),
      );

      expect(lightRevealColor, lightScheme.error);
      expect(darkRevealColor, lightRevealColor);
    },
  );

  testWidgets('closed card surface can differ from reveal action color', (
    tester,
  ) async {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 260,
              height: 96,
              child: SwipeRevealCard(
                shape: shape,
                color: Colors.blue,
                closedColor: Colors.red,
                actionLabel: 'Details',
                removeTooltip: 'Details',
                onRemove: () {},
                child: const SizedBox.expand(child: Text('Closed content')),
              ),
            ),
          ),
        ),
      ),
    );

    final closedSurface = tester.widgetList<ColoredBox>(
      find.byWidgetPredicate((widget) {
        return widget is ColoredBox && widget.color == Colors.red;
      }),
    );
    expect(closedSurface, isNotEmpty);
    expect(
      find.byWidgetPredicate((widget) {
        if (widget is! DecoratedBox) return false;
        final decoration = widget.decoration;
        if (decoration is! ShapeDecoration || decoration.color != Colors.red) {
          return false;
        }
        final shape = decoration.shape;
        return shape is RoundedRectangleBorder && shape.side != BorderSide.none;
      }),
      findsNothing,
      reason: 'The reveal backing must not repaint the child card border.',
    );
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
  });

  testWidgets('inactive page closes an open card before it becomes visible', (
    tester,
  ) async {
    var tickerEnabled = true;
    late StateSetter setHostState;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setHostState = setState;
              return TickerMode(
                enabled: tickerEnabled,
                child: Center(
                  child: SizedBox(
                    width: 260,
                    height: 96,
                    child: SwipeRevealCard(
                      shape: shape,
                      actionLabel: 'Remove',
                      removeTooltip: 'Remove',
                      onRemove: () {},
                      child: const SizedBox.expand(child: Text('Swipe target')),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    await tester.drag(find.text('Swipe target'), const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(find.byType(TweenAnimationBuilder<double>), findsOneWidget);

    setHostState(() => tickerEnabled = false);
    await tester.pump();
    setHostState(() => tickerEnabled = true);
    await tester.pump();

    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
  });

  testWidgets('reveal pane matches card bounds without a second border', (
    tester,
  ) async {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: Colors.red, width: 2),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              height: 148,
              child: SwipeRevealCard(
                shape: shape,
                actionLabel: 'Remove',
                removeTooltip: 'Remove',
                onRemove: () {},
                child: const SizedBox.expand(child: Text('Library card')),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.text('Library card'), const Offset(-180, 0));
    await tester.pumpAndSettle();
    final revealPane = find.byWidgetPredicate((widget) {
      if (widget is! DecoratedBox) return false;
      final decoration = widget.decoration;
      return decoration is ShapeDecoration && decoration.gradient != null;
    });
    final closedSurface = find.descendant(
      of: find.byType(SwipeRevealCard),
      matching: find.byWidgetPredicate((widget) => widget is ColoredBox),
    );
    expect(revealPane, findsOneWidget);
    final decoration = tester.widget<DecoratedBox>(revealPane).decoration;
    final revealShape = (decoration as ShapeDecoration).shape;

    expect(revealShape, isA<RoundedRectangleBorder>());
    expect((revealShape as RoundedRectangleBorder).side, BorderSide.none);
    expect(tester.getSize(revealPane), tester.getSize(closedSurface.first));
  });

  testWidgets('leading action reveals on a right swipe', (tester) async {
    var downloads = 0;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 260,
              height: 96,
              child: SwipeRevealCard(
                shape: shape,
                actionLabel: 'Favorite',
                removeTooltip: 'Favorite',
                onRemove: () {},
                leadingActionLabel: 'Download',
                leadingActionTooltip: 'Download',
                onLeadingAction: () => downloads++,
                child: const SizedBox.expand(child: Text('Downloadable card')),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.text('Downloadable card'), const Offset(180, 0));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Download'), findsOneWidget);
    expect(find.byIcon(Icons.swipe_right_rounded), findsNothing);

    await tester.tap(find.byTooltip('Download'));
    await tester.pump();
    expect(downloads, 1);
  });

  testWidgets(
    'opposite swipe closes a leading action without revealing trailing actions',
    (tester) async {
      final shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 260,
                height: 96,
                child: SwipeRevealCard(
                  shape: shape,
                  actionLabel: 'Favorite',
                  removeTooltip: 'Favorite',
                  onRemove: () {},
                  leadingActionLabel: 'Download',
                  leadingActionTooltip: 'Download',
                  onLeadingAction: () {},
                  child: const SizedBox.expand(child: Text('Swipe target')),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.drag(find.text('Swipe target'), const Offset(180, 0));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Download'), findsOneWidget);

      await tester.drag(find.text('Swipe target'), const Offset(-180, 0));
      await tester.pump();
      expect(find.byIcon(Icons.swipe_left_rounded), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
      expect(find.text('Swipe target'), findsOneWidget);
    },
  );
}
