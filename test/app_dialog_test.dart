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
    expect(find.byIcon(Icons.edit_rounded), findsOneWidget);
    expect(find.text('Rename queue'), findsOneWidget);
    expect(find.text('Queue name'), findsOneWidget);

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
}
