import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/widgets/shimmer_loading.dart';
import 'package:nameless_audio/core/widgets/app_bottom_sheet.dart';
import 'package:nameless_audio/core/widgets/unified_popup_menu.dart';

void main() {
  testWidgets('reduced motion disables shimmer animation', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: ShimmerLoader(child: SizedBox(width: 40, height: 40)),
        ),
      ),
    );

    expect(find.byType(ShaderMask), findsNothing);
  });

  testWidgets('reduced motion opens bottom sheets without a timed transition', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => AppBottomSheet.show<void>(
                  context: context,
                  builder: (_) =>
                      const SizedBox(height: 120, child: Text('Sheet content')),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();

    final controller = tester
        .widget<BottomSheet>(find.byType(BottomSheet))
        .animationController;
    expect(controller?.duration, Duration.zero);
    expect(controller?.value, 1);
    expect(find.text('Sheet content'), findsOneWidget);
  });

  testWidgets('bottom sheets keep a visible reverse transition', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => AppBottomSheet.show<void>(
                context: context,
                builder: (_) =>
                    const SizedBox(height: 120, child: Text('Sheet content')),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    final openValue = sheet.animationController!.value;
    expect(openValue, greaterThan(0));
    expect(openValue, lessThan(1));

    Navigator.of(tester.element(find.text('Sheet content'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final closingSheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(closingSheet.animationController!.value, lessThan(openValue));
  });

  testWidgets('popup menu button exposes a labeled button semantic', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedPopupMenuButton<int>(
            icon: Icons.more_vert,
            tooltip: 'More actions',
            entries: const <UnifiedMenuEntry<int>>[
              UnifiedMenuEntry<int>.action(
                value: 1,
                icon: Icons.play_arrow,
                label: 'Play',
              ),
            ],
            onSelected: (_) {},
          ),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.byTooltip('More actions')),
      matchesSemantics(
        tooltip: 'More actions',
        isButton: true,
        hasTapAction: true,
        hasFocusAction: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
      ),
    );
  });
}
