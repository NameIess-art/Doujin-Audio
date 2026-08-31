import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/core/widgets/app_dialog.dart';
import 'support/runtime_test_models.dart';
import 'package:doujin_audio/features/library/presentation/audio_detail_sheet.dart';
import 'package:doujin_audio/features/library/presentation/dlsite_metadata_batch_page.dart';
import 'package:doujin_audio/features/library/presentation/dlsite_metadata_review_page.dart';
import 'package:doujin_audio/features/asmr/application/asmr_metadata_service.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/dlsite_metadata_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';

class _FakeDlsiteMetadataService extends DlsiteMetadataService {
  @override
  Future<DlsiteMetadata> fetchByRjCode(
    String rjCode, {
    AppLanguage language = AppLanguage.ja,
  }) async {
    return DlsiteMetadata(
      rjCode: rjCode,
      workTitle: 'Fetched title',
      circleName: 'Circle',
      voiceActors: const <String>['Voice'],
      tags: const <String>['ASMR'],
      releaseDate: DateTime(2024, 5, 6),
      duration: const Duration(hours: 1, minutes: 2, seconds: 3),
      salesCount: 1234,
      rating: 4.5,
    );
  }

  @override
  Future<List<DlsiteMetadata>> searchByTitleCandidates(
    Iterable<String> titles, {
    AppLanguage language = AppLanguage.ja,
    int limit = 6,
  }) async {
    return <DlsiteMetadata>[await fetchByRjCode('RJ123456')];
  }
}

class _FakeAsmrMetadataService extends AsmrMetadataService {
  @override
  Future<DlsiteMetadata> fetchByRjCode(
    String rjCode, {
    AppLanguage language = AppLanguage.zh,
  }) async {
    return DlsiteMetadata(
      rjCode: rjCode,
      workTitle: 'ASMR fetched title',
      circleName: '',
      voiceActors: const <String>['ASMR Voice'],
      tags: const <String>['ASMR'],
    );
  }

  @override
  Future<List<DlsiteMetadata>> searchByTitleCandidates(
    Iterable<String> titles, {
    AppLanguage language = AppLanguage.zh,
  }) async {
    return <DlsiteMetadata>[await fetchByRjCode('RJ123456')];
  }
}

class _DetailCoverCacheService extends CoverArtworkCacheService {
  _DetailCoverCacheService() : super(libraryService: LibraryService());

  @override
  Future<String?> futureForFolder(String folderPath) async => null;

  @override
  Future<List<String>> discoverCoverCandidatesInFolder(
    String folderPath, {
    String? selectedCoverPath,
  }) async => const <String>['/covers/candidate.jpg'];
}

void _expectPrimaryFilledButton(WidgetTester tester, Finder finder) {
  expect(finder, findsOneWidget);
  final element = tester.element(finder);
  final scheme = Theme.of(element).colorScheme;
  final button = tester.widget<FilledButton>(finder);
  final style = button.defaultStyleOf(element);
  expect(style.backgroundColor?.resolve(const <WidgetState>{}), scheme.primary);
  expect(
    style.foregroundColor?.resolve(const <WidgetState>{}),
    scheme.onPrimary,
  );
  expect(button.style?.shape, isNull);
}

void main() {
  test('metadata review work navigation results retain their direction', () {
    expect(
      const DlsiteMetadataReviewResult.previousWork().workNavigationOffset,
      -1,
    );
    expect(const DlsiteMetadataReviewResult.nextWork().workNavigationOffset, 1);
  });

  AppRuntimeTestFixture.initialize();
  late Database testDatabase;

  setUpAll(() async {
    testDatabase = await AppRuntimeTestFixture.installSharedDatabase();
  });

  tearDownAll(() async {
    await AppRuntimeTestFixture.disposeSharedDatabase(testDatabase);
  });

  testWidgets(
    'batch metadata page defaults to missing works and shows counts',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      final persistenceRepository = fixture.persistenceRepository;
      final nativePlaybackRepository = fixture.nativePlaybackRepository;
      const playbackCommandRunner =
          AppRuntimeWidgetTestFixture.playbackCommandRunner;
      final libraryService = fixture.libraryService;
      final playbackService = fixture.playbackService;
      final timerService = fixture.timerService;
      final notificationCoordinatorService =
          fixture.notificationCoordinatorService;
      final settingsRepository = fixture.settings;
      final languageProvider = fixture.languageProvider;

      await tester.pumpWidget(
        buildAppRuntimeTestApp(
          runtimeGraph: runtimeGraph,
          persistenceRepository: persistenceRepository,
          nativePlaybackRepository: nativePlaybackRepository,
          playbackCommandRunner: playbackCommandRunner,
          libraryService: libraryService,
          playbackService: playbackService,
          timerService: timerService,
          notificationCoordinatorService: notificationCoordinatorService,
          settingsRepository: settingsRepository,
          languageProvider: languageProvider,
          child: DlsiteMetadataBatchPage(
            entries: [
              AudioLibraryCategoryEntry(
                target: const AudioDetailTarget(
                  targetType: AudioDetailTargetType.libraryRootFolder,
                  targetPath: '/library/Complete',
                ),
                title: 'Complete',
                path: '/library/Complete',
                isFolder: true,
                detail: AudioDetail(
                  target: const AudioDetailTarget(
                    targetType: AudioDetailTargetType.libraryRootFolder,
                    targetPath: '/library/Complete',
                  ),
                  rjCode: 'RJ123456',
                  workTitle: 'Complete',
                  circleName: 'Circle',
                  voiceActors: const <String>['Voice'],
                  tags: const <String>['ASMR'],
                  releaseDate: DateTime(2024, 5, 6),
                  salesCount: 1234,
                  rating: 4.5,
                ),
                tracks: <MusicTrack>[],
              ),
              AudioLibraryCategoryEntry(
                target: const AudioDetailTarget(
                  targetType: AudioDetailTargetType.libraryRootFolder,
                  targetPath: '/library/Missing',
                ),
                title: 'Missing',
                path: '/library/Missing',
                isFolder: true,
                detail: AudioDetail.empty(
                  const AudioDetailTarget(
                    targetType: AudioDetailTargetType.libraryRootFolder,
                    targetPath: '/library/Missing',
                  ),
                ),
                tracks: const <MusicTrack>[],
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.text('${languageProvider.tr('batch_metadata_any_missing')} (1)'),
        findsOneWidget,
      );
      expect(
        find.text('${languageProvider.tr('batch_metadata_no_metadata')} (1)'),
        findsOneWidget,
      );
      expect(
        find.text('${languageProvider.tr('batch_metadata_has_rj_code')} (1)'),
        findsOneWidget,
      );
      expect(
        find.text('${languageProvider.tr('batch_metadata_all')} (2)'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<RadioGroup<Object?>>(
              find.byKey(const ValueKey('batch_metadata_scope_group')),
            )
            .groupValue
            .toString(),
        contains('anyMissing'),
      );
    },
  );

  testWidgets('metadata review batch mode shows progress and skip action', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final fixture = AppRuntimeWidgetTestFixture(
      dlsiteMetadataService: _FakeDlsiteMetadataService(),
      asmrMetadataService: _FakeAsmrMetadataService(),
    );
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final persistenceRepository = fixture.persistenceRepository;
    final nativePlaybackRepository = fixture.nativePlaybackRepository;
    const playbackCommandRunner =
        AppRuntimeWidgetTestFixture.playbackCommandRunner;
    final libraryService = fixture.libraryService;
    final playbackService = fixture.playbackService;
    final timerService = fixture.timerService;
    final notificationCoordinatorService =
        fixture.notificationCoordinatorService;
    final settingsRepository = fixture.settings;
    final languageProvider = fixture.languageProvider;

    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: runtimeGraph,
        persistenceRepository: persistenceRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        playbackCommandRunner: playbackCommandRunner,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationCoordinatorService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
        languageProvider: languageProvider,
        child: DlsiteMetadataReviewPage(
          detail: AudioDetail.empty(
            const AudioDetailTarget(
              targetType: AudioDetailTargetType.libraryRootFolder,
              targetPath:
                  '/library/A very long folder name that wraps across multiple lines so the floating title surface must size itself before the metadata content begins below it',
            ),
          ),
          rjCode: 'RJ123456',
          batchIndex: 2,
          batchTotal: 3,
          allowSkip: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      find.text(
        '${languageProvider.tr('dlsite_review_title')} · ${languageProvider.tr('batch_metadata_progress', {'current': 2, 'total': 3})}',
      ),
      findsOneWidget,
    );
    expect(find.text(languageProvider.tr('skip')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('dlsite_review_header')),
      findsOneWidget,
    );
    final confirm = find.byKey(const ValueKey<String>('dlsite_review_confirm'));
    expect(confirm, findsOneWidget);
    final skip = find.byKey(const ValueKey<String>('dlsite_review_skip'));
    expect(skip, findsOneWidget);
    expect(
      find.descendant(of: find.byType(ListView), matching: confirm),
      findsNothing,
    );
    expect(
      tester.getSize(skip).width,
      closeTo(tester.getSize(confirm).width, 0.001),
    );
    final previousWork = tester.widget<IconButton>(
      find.byKey(const ValueKey<String>('dlsite_review_previous_work')),
    );
    final nextWork = tester.widget<IconButton>(
      find.byKey(const ValueKey<String>('dlsite_review_next_work')),
    );
    expect(previousWork.onPressed, isNotNull);
    expect(nextWork.onPressed, isNotNull);
    final targetName = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('dlsite_review_target_name')),
        matching: find.byType(Text),
      ),
    );
    expect(targetName.maxLines, 3);
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey<String>('dlsite_review_target_name')),
          )
          .height,
      greaterThan(44),
    );
    expect(
      tester
              .getRect(
                find.text(languageProvider.tr('audio_detail_work_title')),
              )
              .top -
          tester
              .getRect(
                find.byKey(const ValueKey<String>('dlsite_review_target_name')),
              )
              .bottom,
      greaterThanOrEqualTo(8),
    );
    expect(
      find.text(languageProvider.tr('audio_detail_release_date')),
      findsOneWidget,
    );
    await tester.dragUntilVisible(
      find.text(languageProvider.tr('audio_detail_sales_count')),
      find.byType(ListView),
      const Offset(0, -200),
    );
    expect(
      find.text(languageProvider.tr('audio_detail_sales_count')),
      findsOneWidget,
    );
    final visibleTextFieldValues = tester
        .widgetList<TextField>(find.byType(TextField))
        .map((field) => field.controller?.text)
        .whereType<String>()
        .toSet();
    expect(visibleTextFieldValues, contains('ASMR fetched title'));
    expect(visibleTextFieldValues, contains('Circle'));
    expect(visibleTextFieldValues, contains('2024-05-06'));
    expect(visibleTextFieldValues, contains('01:02:03'));
    expect(visibleTextFieldValues, contains('1234'));

    await tester.dragUntilVisible(
      find.text(languageProvider.tr('audio_detail_rating')),
      find.byType(ListView),
      const Offset(0, -200),
    );
    expect(
      find.text(languageProvider.tr('audio_detail_rating')),
      findsOneWidget,
    );
    final ratingField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText ==
                languageProvider.tr('audio_detail_rating'),
      ),
    );
    expect(ratingField.controller?.text, '4.5');
  });

  test(
    'preferred title metadata fills missing ASMR fields from DLsite',
    () async {
      final fixture = AppRuntimeWidgetTestFixture(
        dlsiteMetadataService: _FakeDlsiteMetadataService(),
        asmrMetadataService: _FakeAsmrMetadataService(),
      );
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;

      final metadata =
          (await runtimeGraph.library.searchPreferredMetadataByTitles(
            const <String>['Work'],
            language: AppLanguage.zh,
          )).single;

      expect(metadata.workTitle, 'ASMR fetched title');
      expect(metadata.circleName, 'Circle');
      expect(metadata.releaseDate, DateTime(2024, 5, 6));
      expect(
        metadata.duration,
        const Duration(hours: 1, minutes: 2, seconds: 3),
      );
      expect(metadata.salesCount, 1234);
      expect(metadata.rating, 4.5);
    },
  );

  testWidgets(
    'clearing a manual folder duration shows the calculated track total',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      final persistenceRepository = fixture.persistenceRepository;
      final nativePlaybackRepository = fixture.nativePlaybackRepository;
      const playbackCommandRunner =
          AppRuntimeWidgetTestFixture.playbackCommandRunner;
      final libraryService = fixture.libraryService;
      final playbackService = fixture.playbackService;
      final timerService = fixture.timerService;
      final notificationCoordinatorService =
          fixture.notificationCoordinatorService;
      final settingsRepository = fixture.settings;
      final languageProvider = fixture.languageProvider;

      const folderPath = r'C:\library\Work';
      const target = AudioDetailTarget(
        targetType: AudioDetailTargetType.libraryRootFolder,
        targetPath: folderPath,
      );
      runtimeGraph.library.addWatchedFolder(folderPath, notify: false);
      runtimeGraph.library.addTracks(
        <MusicTrack>[
          MusicTrack(
            path: r'C:\library\Work\01.mp3',
            displayName: '01',
            groupKey: folderPath,
            groupTitle: 'Work',
            groupSubtitle: folderPath,
            isSingle: false,
            duration: const Duration(minutes: 2),
          ),
          MusicTrack(
            path: r'C:\library\Work\02.mp3',
            displayName: '02',
            groupKey: folderPath,
            groupTitle: 'Work',
            groupSubtitle: folderPath,
            isSingle: false,
            duration: const Duration(minutes: 4),
          ),
        ],
        notify: false,
        persist: false,
      );
      await tester.runAsync(
        () => runtimeGraph.library.saveAudioDetail(
          AudioDetail.empty(
            target,
          ).copyWith(duration: const Duration(minutes: 9)),
        ),
      );

      await tester.pumpWidget(
        buildAppRuntimeTestApp(
          runtimeGraph: runtimeGraph,
          persistenceRepository: persistenceRepository,
          nativePlaybackRepository: nativePlaybackRepository,
          playbackCommandRunner: playbackCommandRunner,
          libraryService: libraryService,
          playbackService: playbackService,
          timerService: timerService,
          notificationCoordinatorService: notificationCoordinatorService,
          settingsRepository: settingsRepository,
          languageProvider: languageProvider,
          child: const AudioDetailSheet(target: target),
        ),
      );
      await pumpUntilLibraryTreeReady(tester, runtimeGraph.library);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      final durationLabel = find.text(
        languageProvider.tr('card_info_duration'),
      );
      await tester.ensureVisible(durationLabel);
      await tester.pumpAndSettle();
      final durationRow = find
          .ancestor(of: durationLabel, matching: find.byType(Row))
          .first;
      await tester.tap(
        find.descendant(
          of: durationRow,
          matching: find.byIcon(Icons.edit_rounded),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '');
      final saveLabel = MaterialLocalizations.of(
        tester.element(find.byType(AppDialog)),
      ).saveButtonLabel;
      await tester.tap(find.widgetWithText(FilledButton, saveLabel));
      await pumpUntilNotFound(tester, find.byType(AppDialog));
      for (
        var i = 0;
        i < 100 && find.text('00:06:00').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }

      final saved = await tester.runAsync(
        () => runtimeGraph.library.loadAudioDetail(target),
      );
      expect(saved?.detail.duration, isNull);
      expect(
        find.text('00:06:00'),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data)
            .whereType<String>()
            .join(' | '),
      );
    },
  );

  testWidgets('audio detail renders before automatic duration completes', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final persistenceRepository = fixture.persistenceRepository;
    final nativePlaybackRepository = fixture.nativePlaybackRepository;
    const playbackCommandRunner =
        AppRuntimeWidgetTestFixture.playbackCommandRunner;
    final libraryService = fixture.libraryService;
    final playbackService = fixture.playbackService;
    final timerService = fixture.timerService;
    final notificationCoordinatorService =
        fixture.notificationCoordinatorService;
    final settingsRepository = fixture.settings;
    final languageProvider = fixture.languageProvider;
    final target = AudioDetailTarget.libraryRootFolder('/library/Work');
    await tester.runAsync(
      () => runtimeGraph.library.saveAudioDetail(AudioDetail.empty(target)),
    );
    final durationCompleter = Completer<Duration?>();

    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: runtimeGraph,
        persistenceRepository: persistenceRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        playbackCommandRunner: playbackCommandRunner,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationCoordinatorService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
        languageProvider: languageProvider,
        child: AudioDetailSheet(
          target: target,
          durationCalculator: (_, _) => durationCompleter.future,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    for (
      var i = 0;
      i < 20 &&
          find
              .text(languageProvider.tr('asmr_detail_basic_info'))
              .evaluate()
              .isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(
      find.text(languageProvider.tr('asmr_detail_basic_info')),
      findsOneWidget,
    );
    expect(durationCompleter.isCompleted, isFalse);

    durationCompleter.complete(const Duration(minutes: 3));
    await tester.pump();
  });

  testWidgets(
    'duration calculation failure clears busy state and is retryable',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      final target = AudioDetailTarget.libraryRootFolder(
        '/library/DurationError',
      );
      await tester.runAsync(
        () => runtimeGraph.library.saveAudioDetail(AudioDetail.empty(target)),
      );

      await tester.pumpWidget(
        fixture.build(
          AudioDetailSheet(
            target: target,
            durationCalculator: (_, _) async {
              throw StateError('duration probe failed');
            },
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.text(
          fixture.languageProvider.tr(
            'audio_detail_duration_calculation_failed',
          ),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('audio detail fetch opens metadata scope page', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final persistenceRepository = fixture.persistenceRepository;
    final nativePlaybackRepository = fixture.nativePlaybackRepository;
    const playbackCommandRunner =
        AppRuntimeWidgetTestFixture.playbackCommandRunner;
    final libraryService = fixture.libraryService;
    final playbackService = fixture.playbackService;
    final timerService = fixture.timerService;
    final notificationCoordinatorService =
        fixture.notificationCoordinatorService;
    final settingsRepository = fixture.settings;
    final languageProvider = fixture.languageProvider;

    const target = AudioDetailTarget(
      targetType: AudioDetailTargetType.libraryRootFolder,
      targetPath: '/library/Work',
    );
    await tester.runAsync(
      () => runtimeGraph.library.saveAudioDetail(AudioDetail.empty(target)),
    );

    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: runtimeGraph,
        persistenceRepository: persistenceRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        playbackCommandRunner: playbackCommandRunner,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationCoordinatorService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
        languageProvider: languageProvider,
        child: const AudioDetailSheet(target: target),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    final fetchInfoButton = find.byTooltip(
      languageProvider.tr('audio_detail_fetch_info'),
    );
    final fetchInfoIconButton = find.byKey(
      const ValueKey<String>('audio_detail_fetch_info'),
    );
    final collapseButton = find.byTooltip(
      MaterialLocalizations.of(
        tester.element(find.byType(AudioDetailSheet)),
      ).closeButtonTooltip,
    );
    expect(fetchInfoButton, findsOneWidget);
    expect(fetchInfoIconButton, findsOneWidget);
    expect(collapseButton, findsOneWidget);
    expect(tester.widget<IconButton>(fetchInfoIconButton).style, isNull);
    expect(
      tester.getCenter(fetchInfoButton).dx,
      lessThan(tester.getCenter(collapseButton).dx),
    );
    expect(tester.getSize(fetchInfoButton), const Size.square(48));
    expect(find.byIcon(Icons.drive_file_rename_outline), findsNothing);

    await tester.tap(fetchInfoButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.text(languageProvider.tr('audio_detail_fetch_scope_title')),
      findsOneWidget,
    );
    expect(
      find.text(languageProvider.tr('batch_metadata_all')),
      findsOneWidget,
    );
    expect(
      find.text(languageProvider.tr('metadata_scope_missing')),
      findsOneWidget,
    );
  });

  testWidgets('audio detail cover action uses the primary button color', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: _DetailCoverCacheService(),
    );
    addTearDown(fixture.dispose);
    const target = AudioDetailTarget(
      targetType: AudioDetailTargetType.libraryRootFolder,
      targetPath: '/library/Work',
    );
    await tester.runAsync(
      () => fixture.runtimeGraph.library.saveAudioDetail(
        AudioDetail.empty(target),
      ),
    );

    await tester.pumpWidget(
      fixture.build(const AudioDetailSheet(target: target)),
    );
    final label = fixture.languageProvider.tr('audio_detail_set_cover');
    final button = find.widgetWithText(FilledButton, label);
    for (var i = 0; i < 40 && button.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    _expectPrimaryFilledButton(tester, button);
  });

  testWidgets('single audio detail keeps the title rename action', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    const target = AudioDetailTarget(
      targetType: AudioDetailTargetType.singleAudioFile,
      targetPath: '/library/track.mp3',
    );
    await tester.runAsync(
      () => fixture.runtimeGraph.library.saveAudioDetail(
        AudioDetail.empty(target),
      ),
    );

    await tester.pumpWidget(
      fixture.build(const AudioDetailSheet(target: target)),
    );
    final button = find.widgetWithText(
      FilledButton,
      fixture.languageProvider.tr('audio_detail_rename_file_from_title'),
    );
    for (var i = 0; i < 40 && button.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    _expectPrimaryFilledButton(tester, button);
  });
}
