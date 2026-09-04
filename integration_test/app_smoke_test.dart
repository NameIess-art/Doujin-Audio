import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:doujin_audio/main.dart' as app;

import 'support/app_startup_test_helper.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app starts and navigates across top-level pages', (
    tester,
  ) async {
    await startAppForTest(tester, app.main);
    await enterMainScreen(tester);

    for (final key in <String>[
      'music_library',
      'nav_sessions',
      'nav_settings',
    ]) {
      final ink = find.byKey(ValueKey<String>('main_destination_ink_$key'));
      final destination = ink.evaluate().isNotEmpty
          ? ink
          : find.byKey(ValueKey<String>('main_destination_$key'));
      expect(destination, findsOneWidget);
      await tester.tap(destination);
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
