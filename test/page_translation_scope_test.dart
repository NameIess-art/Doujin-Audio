import 'dart:async';

import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/translation/text_translation_service.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/page_translation_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'WorkPageTranslationHost defers status updates during didChangeDependencies',
    (tester) async {
      final language = AppLanguageProvider();
      final translator = TextTranslationService();
      addTearDown(() {
        language.dispose();
        UiInteractionCoordinator.instance.resetForTest();
      });

      final navigatorKey = GlobalKey<NavigatorState>();
      var tickerEnabled = true;
      late StateSetter updateTicker;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
            textTranslationServiceProvider.overrideWithValue(translator),
          ],
          child: StatefulBuilder(
            builder: (context, setState) {
              updateTicker = setState;
              return MaterialApp(
                navigatorKey: navigatorKey,
                home: TickerMode(
                  enabled: tickerEnabled,
                  child: const WorkPageTranslationHost(
                    child: Scaffold(
                      body: Column(
                        children: [
                          WorkPageTranslationButton(),
                          WorkPageTranslationText('音声作品'),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Trigger didChangeDependencies via route push/pop while button is mounted.
      unawaited(
        navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('next')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Trigger didChangeDependencies via TickerMode toggle.
      updateTicker(() => tickerEnabled = false);
      await tester.pump();
      expect(tester.takeException(), isNull);

      updateTicker(() => tickerEnabled = true);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
