import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/localization/app_language_provider.dart';
import 'package:nameless_audio/app/state/app_runtime_providers.dart';
import 'package:nameless_audio/features/asmr/presentation/asmr_download_details_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('download details follows the selected language', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final languageProvider = AppLanguageProvider();
    addTearDown(languageProvider.dispose);
    await languageProvider.setLanguage(AppLanguage.en);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
          asmrDownloadTaskProvider(404).overrideWithValue(null),
        ],
        child: const MaterialApp(home: AsmrDownloadDetailsPage(workId: 404)),
      ),
    );
    await tester.pump();

    expect(find.text('Download details'), findsOneWidget);
    expect(find.text('Download task not found'), findsOneWidget);

    await languageProvider.setLanguage(AppLanguage.ja);
    await tester.pump();

    expect(find.text('ダウンロード詳細'), findsOneWidget);
    expect(find.text('ダウンロードタスクが見つかりません'), findsOneWidget);
    expect(find.text('Download task not found'), findsNothing);
  });
}
