import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/features/video_converter/application/video_conversion_runner.dart';
import 'package:doujin_audio/features/video_converter/presentation/video_conversion_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'conversion failure dialog uses localized text in every language',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final language = AppLanguageProvider();
      addTearDown(language.dispose);

      for (final locale in AppLanguage.values) {
        await language.setLanguage(locale);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showVideoConversionResultDialog(
                    context,
                    result: const VideoConversionResult.failed(
                      'ffmpeg: raw English error',
                    ),
                    i18n: language,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(find.text(language.tr('conversion_failed')), findsOneWidget);
        expect(find.textContaining('ffmpeg: raw English error'), findsNothing);

        await tester.tap(find.text(language.tr('done')));
        await tester.pumpAndSettle();
      }
    },
  );
}
