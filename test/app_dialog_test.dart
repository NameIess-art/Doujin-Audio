import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/app_buttons.dart';
import 'package:doujin_audio/core/widgets/app_dialog.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';

void main() {
  testWidgets('overlay ink background fades with the panel on dismissal', (
    tester,
  ) async {
    final captureKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAppOverlayPanel<void>(
                  context: context,
                  builder: (_) => Ink(
                    key: const ValueKey('fading_ink'),
                    width: 200,
                    height: 100,
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byKey(const ValueKey('fading_ink')));
    Future<int> redAtCenter() async {
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = boundary.toImageSync();
      final bytes = await tester.runAsync(() => image.toByteData());
      final red = bytes!.getUint8(
        (center.dy.floor() * image.width + center.dx.floor()) * 4,
      );
      image.dispose();
      return red;
    }

    final initialRed = await redAtCenter();
    expect(initialRed, greaterThan(0));
    await tester.tapAt(const Offset(1, 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 225));
    expect(await redAtCenter(), lessThan(initialRed / 2));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fading_ink')), findsNothing);
  });

  testWidgets('shared app dialog renders content and returns a typed result', (
    tester,
  ) async {
    String? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () async {
                  result = await showAppDialog<String>(
                    context: context,
                    builder: (dialogContext) {
                      return AppDialog(
                        title: 'Rename queue',
                        icon: Icons.edit_rounded,
                        content: const Text('Queue name'),
                        actions: AppDialogActions(
                          children: [
                            AppSecondaryButton(
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(),
                              label: 'Cancel',
                            ),
                            AppPrimaryButton(
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop('Night'),
                              label: 'Save',
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
                child: const Text('Show dialog'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show dialog'));
    await tester.pump();

    final dialogScrim = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('app_dialog_scrim')),
    );
    expect(
      dialogScrim.color.a,
      closeTo(kSecondaryOverlayConfig.backgroundOpacity, 0.001),
    );

    await tester.pumpAndSettle();

    expect(find.byType(AppDialog), findsOneWidget);
    expect(find.byKey(const ValueKey('app_dialog_surface')), findsOneWidget);
    final surface = tester.widget<Container>(
      find.byKey(const ValueKey('app_dialog_surface')),
    );
    final surfaceDecoration = surface.decoration! as BoxDecoration;
    expect(surfaceDecoration.color!.a, 1);
    expect(find.byIcon(Icons.edit_rounded), findsOneWidget);
    expect(find.text('Rename queue'), findsOneWidget);
    expect(find.text('Queue name'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('app_dialog_surface')),
        matching: find.byType(ScaleTransition),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Cancel'))
          .style
          ?.shape
          ?.resolve(const <WidgetState>{}),
      isA<StadiumBorder>(),
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .style
          ?.shape
          ?.resolve(const <WidgetState>{}),
      isA<StadiumBorder>(),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    final fadingDialogScrim = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('app_dialog_scrim')),
    );
    expect(
      fadingDialogScrim.color.a,
      inExclusiveRange(0, kSecondaryOverlayConfig.backgroundOpacity),
    );

    await tester.pumpAndSettle();

    expect(result, 'Night');
    expect(find.byType(AppDialog), findsNothing);
  });

  testWidgets('shared app dialog dismisses when tapping background scrim', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppDialog<void>(
                context: context,
                builder: (_) => const AppDialog(
                  title: 'Dismissable dialog',
                  content: Text('Content'),
                ),
              ),
              child: const Text('Open dialog'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open dialog'));
    await tester.pumpAndSettle();
    expect(find.text('Dismissable dialog'), findsOneWidget);

    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(find.text('Dismissable dialog'), findsNothing);
  });

  testWidgets('dialog actions stack on a narrow viewport', (tester) async {
    tester.view.physicalSize = const Size(240, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () {
                  showAppDialog<void>(
                    context: context,
                    builder: (dialogContext) {
                      return AppDialog(
                        title: 'Narrow dialog',
                        content: const Text('Content'),
                        actions: AppDialogActions(
                          children: [
                            AppSecondaryButton(
                              onPressed: () {},
                              label: 'Cancel',
                            ),
                            AppPrimaryButton(
                              onPressed: () {},
                              label: 'Confirm',
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
                child: const Text('Show'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();

    final cancelCenter = tester.getCenter(
      find.widgetWithText(OutlinedButton, 'Cancel'),
    );
    final confirmCenter = tester.getCenter(
      find.widgetWithText(FilledButton, 'Confirm'),
    );
    expect(cancelCenter.dx, confirmCenter.dx);
    expect(confirmCenter.dy, greaterThan(cancelCenter.dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('shared overlay panel fades in and out over 300ms', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppOverlayPanel<void>(
                context: context,
                builder: (_) => const SizedBox(
                  key: ValueKey('overlay_panel_content'),
                  height: 120,
                  child: Text('Overlay content'),
                ),
              ),
              child: const Text('Open overlay'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open overlay'));
    await tester.pump();

    final openingScrim = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('app_overlay_panel_scrim')),
    );
    expect(openingScrim.color.a, closeTo(0, 0.001));
    final route = ModalRoute.of(
      tester.element(find.byKey(const ValueKey('overlay_panel_content'))),
    )!;
    expect(route.transitionDuration, const Duration(milliseconds: 300));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 300));

    double panelOpacity() => tester
        .widget<FadeTransition>(
          find.ancestor(
            of: find.byKey(const ValueKey('overlay_panel_content')),
            matching: find.byType(FadeTransition),
          ),
        )
        .opacity
        .value;
    double scrimOpacity() => tester
        .widget<ColoredBox>(
          find.byKey(const ValueKey('app_overlay_panel_scrim')),
        )
        .color
        .a;
    await tester.pump(const Duration(milliseconds: 150));
    final middleOpacity = Curves.easeInOutCubic.transform(0.5);
    expect(panelOpacity(), closeTo(middleOpacity, 0.001));
    expect(
      scrimOpacity(),
      closeTo(
        panelOpacity() * kSecondaryOverlayConfig.backgroundOpacity,
        0.001,
      ),
    );
    await tester.pump(const Duration(milliseconds: 149));
    expect(panelOpacity(), lessThan(1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(panelOpacity(), 1);

    expect(find.text('Overlay content'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('overlay_panel_content')),
        matching: find.byType(FadeTransition),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('overlay_panel_content')),
        matching: find.byType(ScaleTransition),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('app_overlay_panel_scrim')),
      findsOneWidget,
    );

    await tester.tapAt(const Offset(1, 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    final fadingPanelScrim = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('app_overlay_panel_scrim')),
    );
    expect(
      fadingPanelScrim.color.a,
      closeTo(kSecondaryOverlayConfig.backgroundOpacity * middleOpacity, 0.001),
    );
    expect(panelOpacity(), closeTo(middleOpacity, 0.001));

    await tester.pump(const Duration(milliseconds: 149));
    expect(find.text('Overlay content'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(panelOpacity(), closeTo(0, 0.001));
    await tester.pumpAndSettle();
    expect(find.text('Overlay content'), findsNothing);
  });

  testWidgets('closing a partially opened panel keeps the fade continuous', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppOverlayPanel<void>(
                context: context,
                builder: (_) => const Text('Partial overlay'),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    double opacity() => tester
        .widget<FadeTransition>(
          find.ancestor(
            of: find.text('Partial overlay'),
            matching: find.byType(FadeTransition),
          ),
        )
        .opacity
        .value;
    double scrimOpacity() => tester
        .widget<ColoredBox>(
          find.byKey(const ValueKey('app_overlay_panel_scrim')),
        )
        .color
        .a;

    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final beforeClose = opacity();
    final scrimBeforeClose = scrimOpacity();
    expect(beforeClose, inExclusiveRange(0, 1));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(opacity(), closeTo(beforeClose, 0.001));
    expect(scrimOpacity(), closeTo(scrimBeforeClose, 0.001));
    var previous = beforeClose;
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(opacity(), lessThan(previous));
      expect(
        scrimOpacity(),
        closeTo(opacity() * kSecondaryOverlayConfig.backgroundOpacity, 0.001),
      );
      previous = opacity();
    }
    await tester.pumpAndSettle();
    expect(find.text('Partial overlay'), findsNothing);
  });

  testWidgets('shared overlay panel closes with the back route', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppOverlayPanel<void>(
                context: context,
                builder: (_) => const Text('Back overlay'),
              ),
              child: const Text('Open back overlay'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open back overlay'));
    await tester.pumpAndSettle();
    expect(find.text('Back overlay'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Back overlay'), findsNothing);
  });

  testWidgets('shared overlay panel can be centered on mobile', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppOverlayPanel<void>(
                context: context,
                maxHeight: 560,
                mobileAlignment: Alignment.center,
                mobileOuterPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 24,
                ),
                builder: (_) => const SizedBox(
                  key: ValueKey('centered_mobile_overlay'),
                  height: 560,
                ),
              ),
              child: const Text('Open centered overlay'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open centered overlay'));
    await tester.pumpAndSettle();

    final panel = find.byKey(const ValueKey('centered_mobile_overlay'));
    final panelRect = tester.getRect(panel);
    expect(panelRect.height, 560);
    expect(panelRect.center.dy, 400);
  });

  testWidgets('shared overlay panel honors reduced motion', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: Scaffold(body: _ReducedMotionOverlayLauncher()),
        ),
      ),
    );

    await tester.tap(find.text('Open reduced overlay'));
    await tester.pump();

    expect(find.text('Reduced overlay'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Reduced overlay'),
        matching: find.byType(ScaleTransition),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.text('Reduced overlay'),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
  });
}

class _ReducedMotionOverlayLauncher extends StatelessWidget {
  const _ReducedMotionOverlayLauncher();

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => showAppOverlayPanel<void>(
        context: context,
        builder: (_) => const Text('Reduced overlay'),
      ),
      child: const Text('Open reduced overlay'),
    );
  }
}
