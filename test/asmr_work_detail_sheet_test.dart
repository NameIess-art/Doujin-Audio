import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_page.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_work_detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  testWidgets('detail download button opens the work download page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    await fixture.languageProvider.setLanguage(AppLanguage.en);
    final work = _work();

    await tester.pumpWidget(
      fixture.build(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAsmrWorkDetailSheet(context, work),
            child: const Text('Open detail'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open detail'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('asmr_work_detail_download')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AsmrDownloadPage), findsOneWidget);
    expect(find.byType(TopPageHeader), findsOneWidget);
    expect(find.byType(HeaderFloatingSurface), findsWidgets);
    expect(
      tester.widget<AsmrDownloadPage>(find.byType(AsmrDownloadPage)).work.id,
      work.id,
    );
    expect(find.text('Work details'), findsNothing);
  });
}

AsmrWork _work() => AsmrWork(
  id: 123,
  title: 'Test work',
  circleName: 'Test circle',
  sourceId: 'RJ000123',
  sourceType: 'asmr',
  sourceUrl: '',
  coverUrl: '',
  thumbnailUrl: '',
  mainCoverUrl: '',
  releaseDate: null,
  createDate: null,
  duration: Duration.zero,
  dlCount: 0,
  reviewCount: 0,
  rating: 0,
  voiceActors: const <String>[],
  tags: const <String>[],
);
