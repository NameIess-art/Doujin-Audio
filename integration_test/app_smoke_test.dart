import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nameless_audio/app/localization/app_language_provider.dart';
import 'package:nameless_audio/main.dart' as app;
import 'package:nameless_audio/app/presentation/main_screen.dart';
import 'package:nameless_audio/app/presentation/onboarding_page.dart';
import 'package:nameless_audio/features/player/application/subtitle_overlay_controller.dart';
import 'package:provider/provider.dart';

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
      expect(await SubtitleOverlayController.canDrawOverlays(), isTrue);
      await SubtitleOverlayController.updateStyle(
        fontSize: 18,
        backgroundColor: '#cc202020',
        textColor: '#ffffffff',
        backgroundOpacity: 0.8,
        fontFamily: 'sans-serif',
        borderDepth: 1,
      );
      await SubtitleOverlayController.updateSubtitle('Windows overlay test');
      await SubtitleOverlayController.startOverlay();
      await tester.pump(const Duration(milliseconds: 300));
      await SubtitleOverlayController.stopOverlay(immediate: true);
    }

    final context = tester.element(find.byType(MainScreen));
    final i18n = Provider.of<AppLanguageProvider>(context, listen: false);

    for (final label in <String>[
      'nav_library',
      'nav_sessions',
      'nav_settings',
    ]) {
      await tester.tap(find.text(i18n.tr(label)).last);
      await tester.pumpAndSettle();
    }
  });
}
