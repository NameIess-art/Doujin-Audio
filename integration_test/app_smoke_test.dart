import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nameless_audio/main.dart' as app;

import 'support/app_startup_test_helper.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app starts and navigates across top-level pages', (
    tester,
  ) async {
    await app.main();
    await enterMainScreen(tester);

    for (final icons in <(IconData, IconData)>[
      (Icons.library_music_outlined, Icons.library_music_rounded),
      (Icons.graphic_eq_outlined, Icons.graphic_eq_rounded),
      (Icons.tune_outlined, Icons.tune_rounded),
    ]) {
      final unselected = find.byIcon(icons.$1);
      final destination = unselected.evaluate().isNotEmpty
          ? unselected
          : find.byIcon(icons.$2);
      expect(destination, findsOneWidget);
      await tester.tap(destination);
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
