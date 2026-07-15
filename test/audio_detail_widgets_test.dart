import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/localization/app_language_provider.dart';
import 'package:nameless_audio/app/state/audio_provider.dart';
import 'package:nameless_audio/features/library/presentation/audio_detail_sheet.dart';
import 'package:nameless_audio/features/library/presentation/dlsite_metadata_batch_page.dart';
import 'package:nameless_audio/features/library/presentation/dlsite_metadata_review_page.dart';
import 'package:nameless_audio/features/asmr/application/asmr_metadata_service.dart';
import 'package:nameless_audio/features/library/application/dlsite_metadata_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/audio_provider_test_fixture.dart';

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

void main() {
  AudioProviderTestFixture.initialize();
  late Database testDatabase;

  setUpAll(() async {
    testDatabase = await AudioProviderTestFixture.installSharedDatabase();
  });

  tearDownAll(() async {
    await AudioProviderTestFixture.disposeSharedDatabase(testDatabase);
  });

  testWidgets(
    'batch metadata page defaults to missing works and shows counts',
    (WidgetTester tester) async {
      final fixture = AudioProviderWidgetTestFixture();
      addTearDown(fixture.dispose);
      final audioProvider = fixture.audioProvider;
      final audioDatabaseRepository = fixture.audioDatabaseRepository;
      final nativePlaybackRepository = fixture.nativePlaybackRepository;
      const playbackCommandRunner =
          AudioProviderWidgetTestFixture.playbackCommandRunner;
      final libraryService = fixture.libraryService;
      final playbackService = fixture.playbackService;
      final timerService = fixture.timerService;
      final notificationCoordinatorService =
          fixture.notificationCoordinatorService;
      final settingsRepository = fixture.settingsRepository;
      final languageProvider = fixture.languageProvider;

      await tester.pumpWidget(
        buildAudioProviderTestApp(
          audioProvider: audioProvider,
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
    final fixture = AudioProviderWidgetTestFixture(
      dlsiteMetadataService: _FakeDlsiteMetadataService(),
      asmrMetadataService: _FakeAsmrMetadataService(),
    );
    addTearDown(fixture.dispose);
    final audioProvider = fixture.audioProvider;
    final audioDatabaseRepository = fixture.audioDatabaseRepository;
    final nativePlaybackRepository = fixture.nativePlaybackRepository;
    const playbackCommandRunner =
        AudioProviderWidgetTestFixture.playbackCommandRunner;
    final libraryService = fixture.libraryService;
    final playbackService = fixture.playbackService;
    final timerService = fixture.timerService;
    final notificationCoordinatorService =
        fixture.notificationCoordinatorService;
    final settingsRepository = fixture.settingsRepository;
    final languageProvider = fixture.languageProvider;

    await tester.pumpWidget(
      buildAudioProviderTestApp(
        audioProvider: audioProvider,
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
      final fixture = AudioProviderWidgetTestFixture(
        dlsiteMetadataService: _FakeDlsiteMetadataService(),
        asmrMetadataService: _FakeAsmrMetadataService(),
      );
      addTearDown(fixture.dispose);
      final audioProvider = fixture.audioProvider;

      final metadata =
          (await audioProvider.libraryFacade.searchPreferredMetadataByTitles(
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
      final fixture = AudioProviderWidgetTestFixture();
      addTearDown(fixture.dispose);
      final audioProvider = fixture.audioProvider;
      final audioDatabaseRepository = fixture.audioDatabaseRepository;
      final nativePlaybackRepository = fixture.nativePlaybackRepository;
      const playbackCommandRunner =
          AudioProviderWidgetTestFixture.playbackCommandRunner;
      final libraryService = fixture.libraryService;
      final playbackService = fixture.playbackService;
      final timerService = fixture.timerService;
      final notificationCoordinatorService =
          fixture.notificationCoordinatorService;
      final settingsRepository = fixture.settingsRepository;
      final languageProvider = fixture.languageProvider;

      const folderPath = r'C:\library\Work';
      const target = AudioDetailTarget(
        targetType: AudioDetailTargetType.libraryRootFolder,
        targetPath: folderPath,
      );
      audioProvider.addWatchedFolder(folderPath, notify: false);
      audioProvider.addTracks(
        const <MusicTrack>[
          MusicTrack(
            path: r'C:\library\Work\01.mp3',
            displayName: '01',
            groupKey: folderPath,
            groupTitle: 'Work',
            groupSubtitle: folderPath,
            isSingle: false,
            duration: Duration(minutes: 2),
          ),
          MusicTrack(
            path: r'C:\library\Work\02.mp3',
            displayName: '02',
            groupKey: folderPath,
            groupTitle: 'Work',
            groupSubtitle: folderPath,
            isSingle: false,
            duration: Duration(minutes: 4),
          ),
        ],
        notify: false,
        persist: false,
      );
      await tester.runAsync(
        () => audioProvider.saveAudioDetail(
          AudioDetail.empty(
            target,
          ).copyWith(duration: const Duration(minutes: 9)),
        ),
      );

      await tester.pumpWidget(
        buildAudioProviderTestApp(
          audioProvider: audioProvider,
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
      await pumpUntilLibraryTreeReady(tester, audioProvider);
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
        () => audioProvider.loadAudioDetail(target),
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
    final fixture = AudioProviderWidgetTestFixture();
    addTearDown(fixture.dispose);
    final audioProvider = fixture.audioProvider;
    final audioDatabaseRepository = fixture.audioDatabaseRepository;
    final nativePlaybackRepository = fixture.nativePlaybackRepository;
    const playbackCommandRunner =
        AudioProviderWidgetTestFixture.playbackCommandRunner;
    final libraryService = fixture.libraryService;
    final playbackService = fixture.playbackService;
    final timerService = fixture.timerService;
    final notificationCoordinatorService =
        fixture.notificationCoordinatorService;
    final settingsRepository = fixture.settingsRepository;
    final languageProvider = fixture.languageProvider;
    final target = AudioDetailTarget.libraryRootFolder('/library/Work');
    await tester.runAsync(
      () => audioProvider.saveAudioDetail(AudioDetail.empty(target)),
    );
    final durationCompleter = Completer<Duration?>();

    await tester.pumpWidget(
      buildAudioProviderTestApp(
        audioProvider: audioProvider,
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

  testWidgets('audio detail fetch opens metadata scope page', (
    WidgetTester tester,
  ) async {
    final fixture = AudioProviderWidgetTestFixture();
    addTearDown(fixture.dispose);
    final audioProvider = fixture.audioProvider;
    final audioDatabaseRepository = fixture.audioDatabaseRepository;
    final nativePlaybackRepository = fixture.nativePlaybackRepository;
    const playbackCommandRunner =
        AudioProviderWidgetTestFixture.playbackCommandRunner;
    final libraryService = fixture.libraryService;
    final playbackService = fixture.playbackService;
    final timerService = fixture.timerService;
    final notificationCoordinatorService =
        fixture.notificationCoordinatorService;
    final settingsRepository = fixture.settingsRepository;
    final languageProvider = fixture.languageProvider;

    const target = AudioDetailTarget(
      targetType: AudioDetailTargetType.libraryRootFolder,
      targetPath: '/library/Work',
    );
    await tester.runAsync(
      () => audioProvider.saveAudioDetail(AudioDetail.empty(target)),
    );

    await tester.pumpWidget(
      buildAudioProviderTestApp(
        audioProvider: audioProvider,
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
}
