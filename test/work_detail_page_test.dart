import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:doujin_audio/features/library/presentation/work_image_viewer_page.dart';
import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();
  late Database testDatabase;

  setUpAll(() async {
    testDatabase = await AppRuntimeTestFixture.installSharedDatabase();
  });

  tearDownAll(() async {
    await AppRuntimeTestFixture.disposeSharedDatabase(testDatabase);
  });

  group('WorkDetailPage', () {
    testWidgets('renders local work detail header, pinned RJ row and action buttons', (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);

      const folderPath = r'C:\library\RJ123456 - Test Work';
      const target = AudioDetailTarget(
        targetType: AudioDetailTargetType.libraryRootFolder,
        targetPath: folderPath,
      );

      final detail = AudioDetail(
        target: target,
        rjCode: 'RJ123456',
        workTitle: 'Test Local Work Title',
        circleName: 'Test Circle',
        voiceActors: const <String>['CV Alice', 'CV Bob'],
        tags: const <String>['ASMR', 'Ear Cleaning', 'Whisper'],
      );
      await tester.runAsync(
        () => fixture.runtimeGraph.library.saveAudioDetail(detail),
      );

      await tester.pumpWidget(
        fixture.build(
          const WorkDetailPage.forLocal(target: target),
        ),
      );
      for (var i = 0; i < 20 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pump();

      // Top-left floating back button
      expect(find.byKey(const ValueKey<String>('work_detail_back_button')), findsOneWidget);

      // Title at bottom of cover
      expect(find.text('Test Local Work Title'), findsOneWidget);

      // Pinned RJ | Circle row
      expect(find.text('RJ123456'), findsOneWidget);
      expect(find.text('Test Circle'), findsOneWidget);

      // CVs & Tags
      expect(find.text('CV Alice'), findsOneWidget);
      expect(find.text('CV Bob'), findsOneWidget);
      expect(find.text('#ASMR'), findsOneWidget);
      expect(find.text('#Ear Cleaning'), findsOneWidget);
      expect(find.text('#Whisper'), findsOneWidget);

      // Local action buttons: 补充信息, 下载, 置顶
      expect(find.byKey(const ValueKey<String>('work_detail_fetch_info')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('work_detail_download')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('work_detail_pin')), findsOneWidget);
    });

    testWidgets('renders ASMR.ONE work detail header and actions', (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);

      final asmrWork = AsmrWork(
        id: 9999,
        title: 'ASMR Remote Work Title',
        circleName: 'Remote Circle',
        sourceId: 'RJ9999',
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
        voiceActors: const <String>['Remote CV'],
        tags: const <String>['Roleplay'],
      );

      await tester.pumpWidget(
        fixture.build(
          WorkDetailPage.forAsmr(work: asmrWork),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Title & pinned row
      expect(find.text('ASMR Remote Work Title'), findsOneWidget);
      expect(find.text('RJ9999'), findsOneWidget);
      expect(find.text('Remote Circle'), findsOneWidget);

      // CV & tags
      expect(find.text('Remote CV'), findsOneWidget);
      expect(find.text('#Roleplay'), findsOneWidget);

      // ASMR.ONE buttons: 下载, 收藏/取消收藏
      expect(find.byKey(const ValueKey<String>('asmr_work_detail_download')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('asmr_work_detail_favorite')), findsOneWidget);
    });

    testWidgets('back button navigates back', (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);

      final asmrWork = AsmrWork(
        id: 8888,
        title: 'Nav Work',
        circleName: 'Nav Circle',
        sourceId: 'RJ8888',
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

      await tester.pumpWidget(
        fixture.build(
          Navigator(
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => WorkDetailPage.forAsmr(work: asmrWork),
                        ),
                      );
                    },
                    child: const Text('Go'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const ValueKey<String>('work_detail_back_button')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('work_detail_back_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Go'), findsOneWidget);
    });
  });

  group('WorkImageViewerPage', () {
    testWidgets('displays images, switches with prev/next, and sets manual cover', (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);

      var coverSelected = '';

      final images = [
        const WorkImageItem(name: '01.jpg', path: 'path/to/01.jpg', relativePath: '01.jpg'),
        const WorkImageItem(name: '02.jpg', path: 'path/to/02.jpg', relativePath: '02.jpg'),
      ];

      await tester.pumpWidget(
        fixture.build(
          WorkImageViewerPage(
            images: images,
            onSetAsCover: (img) async {
              coverSelected = img.path;
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('01.jpg'), findsOneWidget);

      // Next button
      final nextBtn = find.byKey(const ValueKey<String>('image_viewer_next_button'));
      expect(nextBtn, findsOneWidget);
      await tester.tap(nextBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.text('02.jpg'), findsOneWidget);

      // Set as cover button
      final setCoverBtn = find.byKey(const ValueKey<String>('viewer_set_as_cover_button'));
      expect(setCoverBtn, findsOneWidget);
      await tester.tap(setCoverBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(coverSelected, 'path/to/02.jpg');
    });
  });
}
