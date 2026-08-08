import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/widgets/app_buttons.dart';
import 'package:nameless_audio/core/widgets/app_dialog.dart';

void main() {
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
    await tester.pumpAndSettle();

    expect(result, 'Night');
    expect(find.byType(AppDialog), findsNothing);
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

  testWidgets('shared overlay panel uses scale fade and dismisses by scrim', (
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
    await tester.pumpAndSettle();

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
    await tester.pumpAndSettle();
    expect(find.text('Overlay content'), findsNothing);
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

  testWidgets('overlay panel can reuse an already visible scrim', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppOverlayPanel<void>(
                context: context,
                showScrim: false,
                builder: (_) => const Text('Transparent overlay'),
              ),
              child: const Text('Open transparent overlay'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open transparent overlay'));
    await tester.pumpAndSettle();

    final scrim = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('app_overlay_panel_scrim')),
    );
    final decoration = scrim.decoration as BoxDecoration;
    expect(decoration.color, Colors.transparent);
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
