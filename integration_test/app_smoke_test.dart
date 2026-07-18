import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nameless_audio/main.dart' as app;
import 'package:nameless_audio/app/presentation/main_screen.dart';
import 'package:nameless_audio/app/presentation/onboarding_page.dart';
import 'package:nameless_audio/features/player/application/subtitle_overlay_controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app starts and navigates across top-level pages', (
    tester,
  ) async {
    await app.main();
    await tester.pumpAndSettle(const Duration(seconds: 3));

    if (find.byType(OnboardingPage).evaluate().isNotEmpty) {
      await tester.tap(find.byType(FilledButton).first);
      await tester.pumpAndSettle();
    }
    expect(find.byType(MainScreen), findsOneWidget);

    if (Platform.isWindows) {
      final overlay = SubtitleOverlayController();
      expect(await overlay.canDrawOverlays(), isTrue);
      await overlay.updateStyle(
        fontSize: 18,
        backgroundColor: '#cc202020',
        textColor: '#ffffffff',
        backgroundOpacity: 0.8,
        fontFamily: 'sans-serif',
        borderDepth: 1,
      );
      await overlay.updateSubtitle('Windows overlay test');
      await overlay.startOverlay();
      await tester.pump(const Duration(milliseconds: 300));
      await overlay.stopOverlay(immediate: true);
      await overlay.dispose();
    }

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
