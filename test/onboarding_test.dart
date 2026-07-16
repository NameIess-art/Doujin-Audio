import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/localization/app_language_provider.dart';
import 'package:nameless_audio/app/presentation/onboarding_page.dart';
import 'package:nameless_audio/features/settings/application/app_preferences.dart';
import 'package:nameless_audio/app/state/app_runtime_providers.dart';
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
  });
}
