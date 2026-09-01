import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/presentation/onboarding_page.dart';
import 'package:doujin_audio/features/settings/application/app_preferences.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fresh install shows onboarding and completion persists', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();

    expect(AppPreferences.shouldShowOnboardingSync(), isTrue);
    expect(await AppPreferences.completeOnboarding(), isTrue);
    expect(AppPreferences.shouldShowOnboardingSync(), isFalse);
  });

  test('existing preferences skip onboarding after an upgrade', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'app_language': 'en',
    });
    await AppPreferences.init();

    expect(AppPreferences.shouldShowOnboardingSync(), isFalse);
  });

  testWidgets('onboarding explains trust and opens privacy summary', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AppPreferences.init();
    final language = AppLanguageProvider();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(language),
        ],
        child: MaterialApp(home: OnboardingPage(onComplete: () async {})),
      ),
    );
    await tester.pump();

    expect(find.text(language.tr('onboarding_local')), findsOneWidget);
    await tester.tap(find.text(language.tr('privacy_summary_action')));
    await tester.pumpAndSettle();
    expect(find.text(language.tr('privacy_summary_title')), findsOneWidget);
    expect(find.byType(TopPageHeader), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(TopPageHeader),
        matching: find.byType(HeaderFloatingSurface),
      ),
      findsNWidgets(2),
    );
  });

  testWidgets(
    'onboarding handles landscape and 200% text scale without overflow',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(640, 360);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      SharedPreferences.setMockInitialValues(const <String, Object>{});
      await AppPreferences.init();
      final language = AppLanguageProvider();
      var completed = false;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
          ],
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData.fromView(
                tester.view,
              ).copyWith(textScaler: const TextScaler.linear(2.0)),
              child: OnboardingPage(
                onComplete: () async {
                  completed = true;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsOneWidget);

      final startButton = find.text(language.tr('onboarding_start'));
      await tester.scrollUntilVisible(
        startButton,
        100,
        scrollable: find.byType(Scrollable),
      );
      await tester.pumpAndSettle();
      await tester.tap(startButton);
      await tester.pump();
      expect(completed, isTrue);

      final privacyAction = find.text(language.tr('privacy_summary_action'));
      await tester.scrollUntilVisible(
        privacyAction,
        100,
        scrollable: find.byType(Scrollable),
      );
      await tester.pumpAndSettle();
      await tester.tap(privacyAction);
      await tester.pumpAndSettle();
      expect(find.text(language.tr('privacy_summary_title')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(TopPageHeader),
          matching: find.byType(HeaderFloatingSurface),
        ),
        findsNWidgets(2),
      );
    },
  );
}
