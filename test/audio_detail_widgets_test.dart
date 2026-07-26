import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/localization/app_language_provider.dart';
import 'support/runtime_test_models.dart';
import 'package:nameless_audio/features/library/presentation/audio_detail_sheet.dart';
import 'package:nameless_audio/features/library/presentation/dlsite_metadata_batch_page.dart';
import 'package:nameless_audio/features/library/presentation/dlsite_metadata_review_page.dart';
import 'package:nameless_audio/features/asmr/application/asmr_metadata_service.dart';
import 'package:nameless_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:nameless_audio/features/library/application/dlsite_metadata_service.dart';
import 'package:nameless_audio/features/library/application/library_service.dart';
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
}

void main() {
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
      final audioDatabaseRepository = fixture.audioDatabaseRepository;
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
          audioDatabaseRepository: audioDatabaseRepository,
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
    final fixture = AppRuntimeWidgetTestFixture(
      dlsiteMetadataService: _FakeDlsiteMetadataService(),
      asmrMetadataService: _FakeAsmrMetadataService(),
    );
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final audioDatabaseRepository = fixture.audioDatabaseRepository;
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
        audioDatabaseRepository: audioDatabaseRepository,
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
              targetPath: '/library/Work',
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
      find.text(languageProvider.tr('audio_detail_release_date')),
      findsOneWidget,
    );
    expect(
      find.text(languageProvider.tr('audio_detail_sales_count')),
      findsOneWidget,
    );
    expect(
      find.text(languageProvider.tr('audio_detail_rating')),
      findsOneWidget,
    );
    final textFieldValues = tester
        .widgetList<TextField>(find.byType(TextField))
        .map((field) => field.controller?.text)
        .whereType<String>()
        .toSet();
    expect(textFieldValues, contains('ASMR fetched title'));
    expect(textFieldValues, contains('Circle'));
    expect(textFieldValues, contains('2024-05-06'));
    expect(textFieldValues, contains('01:02:03'));
    expect(textFieldValues, contains('1234'));
    expect(textFieldValues, contains('4.5'));
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
      final audioDatabaseRepository = fixture.audioDatabaseRepository;
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
          audioDatabaseRepository: audioDatabaseRepository,
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
        tester.element(find.byType(AlertDialog)),
      ).saveButtonLabel;
      await tester.tap(find.widgetWithText(FilledButton, saveLabel));
      await pumpUntilNotFound(tester, find.byType(AlertDialog));
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
    final audioDatabaseRepository = fixture.audioDatabaseRepository;
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
        audioDatabaseRepository: audioDatabaseRepository,
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

  testWidgets('duration calculation failure clears busy state and is retryable', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final target = AudioDetailTarget.libraryRootFolder('/library/DurationError');
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
        fixture.languageProvider.tr('audio_detail_duration_calculation_failed'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('audio detail fetch opens metadata scope page', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final audioDatabaseRepository = fixture.audioDatabaseRepository;
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
        audioDatabaseRepository: audioDatabaseRepository,
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

    _expectPrimaryFilledButton(
      tester,
      find.widgetWithText(
        FilledButton,
        languageProvider.tr('audio_detail_fetch_info'),
      ),
    );
    _expectPrimaryFilledButton(
      tester,
      find.widgetWithText(
        FilledButton,
        languageProvider.tr('audio_detail_rename_folder_from_title'),
      ),
    );

    await tester.tap(find.text(languageProvider.tr('audio_detail_fetch_info')));
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
}
