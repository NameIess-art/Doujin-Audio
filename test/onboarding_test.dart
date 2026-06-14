import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/i18n/app_language_provider.dart';
import 'package:nameless_audio/screens/onboarding_page.dart';
import 'package:nameless_audio/services/app_preferences.dart';
import 'package:provider/provider.dart';
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
      ChangeNotifierProvider.value(
        value: language,
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
