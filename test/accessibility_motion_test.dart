import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/theme/app_styles.dart';
import 'package:doujin_audio/core/widgets/shimmer_loading.dart';
import 'package:doujin_audio/core/widgets/app_bottom_sheet.dart';
import 'package:doujin_audio/core/widgets/unified_popup_menu.dart';

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

    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    final controller = sheet.animationController;
    expect(controller?.duration, Duration.zero);
    expect(controller?.value, 1);
    expect(
      (sheet.shape! as RoundedRectangleBorder).borderRadius,
      const BorderRadius.vertical(top: Radius.circular(AppRadius.dialog)),
    );
    expect(find.text('Sheet content'), findsOneWidget);
  });

  testWidgets('shared shimmer placeholder uses the compact corner radius', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ShimmerContainer(width: 40, height: 20)),
      ),
    );

    final container = tester.widget<Container>(
      find.descendant(
        of: find.byType(ShimmerContainer),
        matching: find.byType(Container),
      ),
    );
    expect(
      (container.decoration! as BoxDecoration).borderRadius,
      BorderRadius.circular(AppRadius.small),
    );
  });

  testWidgets('bottom sheets size to content below the height limit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => AppBottomSheet.show<void>(
                context: context,
                builder: (_) => const SizedBox(
                  key: ValueKey('short_sheet_content'),
                  height: 120,
                ),
              ),
              child: const Text('Open short sheet'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open short sheet'));
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(BottomSheet)).height, lessThan(600));
    expect(
      tester.getSize(find.byKey(const ValueKey('short_sheet_content'))).height,
      120,
    );
  });

  testWidgets('bottom sheets preserve their default motion timing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => AppBottomSheet.show<void>(
                context: context,
                builder: (_) => const SizedBox(height: 120),
              ),
              child: const Text('Open motion sheet'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open motion sheet'));
    await tester.pump();

    final controller = tester
        .widget<BottomSheet>(find.byType(BottomSheet))
        .animationController!;
    expect(controller.duration, const Duration(milliseconds: 320));
    expect(controller.reverseDuration, const Duration(milliseconds: 250));
  });

  testWidgets('bottom sheets never exceed three quarters of the screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => AppBottomSheet.show<void>(
                context: context,
                builder: (_) => const SizedBox(height: 1000),
              ),
              child: const Text('Open tall sheet'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open tall sheet'));
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(BottomSheet)).height, 600);
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
