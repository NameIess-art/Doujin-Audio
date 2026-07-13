import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    show ProviderContainer, ProviderScope;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/i18n/app_language_provider.dart';
import 'package:nameless_audio/providers/audio_provider.dart';
import 'package:nameless_audio/providers/audio_provider_riverpod.dart';
import 'package:nameless_audio/screens/audio_detail_sheet.dart';
import 'package:nameless_audio/screens/dlsite_metadata_batch_page.dart';
import 'package:nameless_audio/screens/dlsite_metadata_review_page.dart';
import 'package:nameless_audio/screens/library_tab.dart';
import 'package:nameless_audio/screens/playlist_tab.dart';
import 'package:nameless_audio/screens/settings_tab.dart';
import 'package:nameless_audio/services/app_database.dart';
import 'package:nameless_audio/services/asmr_metadata_service.dart';
import 'package:nameless_audio/services/audio_database_repository.dart';
import 'package:nameless_audio/services/audio_state_services.dart';
import 'package:nameless_audio/services/cover_artwork_cache_service.dart';
import 'package:nameless_audio/services/dlsite_metadata_service.dart';
import 'package:nameless_audio/services/library_scan_models.dart';
import 'package:nameless_audio/services/native_playback_repository.dart';
import 'package:nameless_audio/services/playback_command_runner.dart';
import 'package:nameless_audio/services/playback_notification_service.dart';
import 'package:nameless_audio/theme/theme_provider.dart';
import 'package:nameless_audio/widgets/async_cover_image.dart';
import 'package:nameless_audio/widgets/content_bound_reorder_area.dart';
import 'package:nameless_audio/widgets/duration_overlay.dart';
import 'package:nameless_audio/widgets/top_page_header.dart';
import 'package:provider/provider.dart' as legacy_provider;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

MusicTrack _track({
  required String name,
  required String path,
  required String groupKey,
  required String groupTitle,
  bool isSingle = false,
}) {
  return MusicTrack(
    path: path,
    displayName: name,
    groupKey: groupKey,
    groupTitle: groupTitle,
    groupSubtitle: groupKey,
    isSingle: isSingle,
  );
}

Future<void> _pumpUntilNotFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final ticks = timeout.inMilliseconds ~/ 50;
  for (var i = 0; i < ticks; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Timed out waiting for $finder to disappear');
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final ticks = timeout.inMilliseconds ~/ 50;
  for (var i = 0; i < ticks; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Timed out waiting for $finder to appear');
}

Future<void> _pumpUntilLibraryTreeReady(
  WidgetTester tester,
  AudioProvider audioProvider, {
  Duration timeout = const Duration(seconds: 10),
  bool waitForCategorySnapshot = false,
}) async {
  final ticks = timeout.inMilliseconds ~/ 50;
  for (var i = 0; i < ticks; i++) {
    if (audioProvider.libraryTree.isNotEmpty &&
        (!waitForCategorySnapshot ||
            audioProvider.audioLibraryCategorySnapshotSync != null)) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Timed out waiting for library tree');
}

Widget _buildTestApp({
  required AudioProvider audioProvider,
  required AudioDatabaseRepository audioDatabaseRepository,
  required NativePlaybackRepository nativePlaybackRepository,
  required PlaybackCommandRunner playbackCommandRunner,
  required LibraryService libraryService,
  required PlaybackSessionService playbackService,
  required TimerService timerService,
  required NotificationCoordinatorService notificationCoordinatorService,
  required SettingsRepository settingsRepository,
  required AppLanguageProvider languageProvider,
  required Widget child,
}) {
  return ProviderScope(
    overrides: createAudioProviderOverrides(
      audioProvider: audioProvider,
      audioDatabaseRepository: audioDatabaseRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      playbackCommandRunner: playbackCommandRunner,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationCoordinatorService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
    ),
    child: legacy_provider.MultiProvider(
      providers: [
        legacy_provider.ChangeNotifierProvider.value(value: languageProvider),
        legacy_provider.ChangeNotifierProvider.value(value: audioProvider),
        legacy_provider.ChangeNotifierProvider<ThemeProvider>(
          create: (_) => ThemeProvider(),
        ),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
}

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

class _RecordingPlaybackCoverCacheService extends CoverArtworkCacheService {
  _RecordingPlaybackCoverCacheService()
    : super(libraryService: LibraryService());

  final List<String> requestedPaths = <String>[];

  @override
  String? resolvedForPlaybackTrack(MusicTrack? track, {String? trackPath}) {
    return null;
  }

  @override
  Future<String?> futureForPlaybackTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    final path = track?.path ?? trackPath;
    if (path != null) {
      requestedPaths.add(path);
    }
    return SynchronousFuture<String?>(null);
  }
}

void main() {
  late Database testDatabase;

  test('equalizer badge only appears while equalizer is enabled', () {
    final disabledIcons = sessionFeatureBadgeIcons(
      showSubtitles: false,
      channelSwapEnabled: false,
      audioEffects: const AudioEffectsState(eqPresetId: 'voice_clear'),
      speed: 1,
    );
    final enabledIcons = sessionFeatureBadgeIcons(
      showSubtitles: false,
      channelSwapEnabled: false,
      audioEffects: const AudioEffectsState(eqEnabled: true),
      speed: 1,
    );

    expect(disabledIcons, isNot(contains(Icons.tune_rounded)));
    expect(enabledIcons, contains(Icons.tune_rounded));
  });

  test('active track path provider exposes current session paths', () {
    final playbackService = PlaybackSessionService();
    addTearDown(playbackService.dispose);
    final active = PlaybackSession(
      id: 'active',
      currentTrackPath: '/tracks/active.mp3',
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(false, ProcessingState.ready),
    );
    final empty = PlaybackSession(
      id: 'empty',
      currentTrackPath: '',
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(false, ProcessingState.ready),
    );
    addTearDown(active.dispose);
    addTearDown(empty.dispose);
    playbackService.syncSlice(
      activeSessions: [active, empty],
      playingSessionCount: 0,
      focusedSessionId: null,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );
    final container = ProviderContainer(
      overrides: [
        playbackSessionServiceProvider.overrideWithValue(playbackService),
      ],
    );
    addTearDown(container.dispose);

    final paths = container.read(activeTrackPathsProvider);

    expect(paths.contains('/tracks/active.mp3'), isTrue);
    expect(paths.contains(''), isFalse);
    expect(container.read(isTrackActiveProvider('/tracks/active.mp3')), isTrue);
    expect(container.read(isTrackActiveProvider('/tracks/other.mp3')), isFalse);
  });

  testWidgets('playlist cards freeze background updates while reordering', (
    WidgetTester tester,
  ) async {
    final notificationService = PlaybackNotificationService();
    final audioDatabaseRepository = AudioDatabaseRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    const playbackCommandRunner = PlaybackCommandRunner();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository()
      ..cardPositionsLocked = false
      ..syncSlice();
    final languageProvider = AppLanguageProvider();
    final audioProvider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: audioDatabaseRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
    );
    final track = _track(
      name: 'Frozen card',
      path: '/library/frozen/card.mp3',
      groupKey: '/library/frozen',
      groupTitle: 'Frozen',
    );
    final session = PlaybackSession(
      id: 'frozen-session',
      currentTrackPath: track.path,
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(false, ProcessingState.ready),
    );

    addTearDown(audioProvider.dispose);
    addTearDown(session.dispose);
    audioProvider.addTracks([track], notify: false, persist: false);
    playbackService.syncSlice(
      activeSessions: [session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );
    audioProvider.scheduleUiWarmup(currentPageIndex: 2, immediate: true);

    await tester.pumpWidget(
      _buildTestApp(
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
        child: const PlaylistTab(),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    final reorderable = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    reorderable.onReorderStart?.call(0);
    await tester.pump();

    session.state = PlayerState(true, ProcessingState.ready);
    playbackService.markSessionStateDirty();
    playbackService.syncSlice(
      activeSessions: [session],
      playingSessionCount: 1,
      focusedSessionId: session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );
    await tester.pump();

    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsNothing);

    reorderable.onReorderEnd?.call(0);
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
  });

  testWidgets('playlist cards keep track and single-file durations separate', (
    WidgetTester tester,
  ) async {
    final notificationService = PlaybackNotificationService();
    final audioDatabaseRepository = AudioDatabaseRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    const playbackCommandRunner = PlaybackCommandRunner();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository();
    final languageProvider = AppLanguageProvider();
    final audioProvider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: audioDatabaseRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
    );
    final workTrack = _track(
      name: 'Work track',
      path: Platform.isWindows
          ? r'C:\library\duration\work-track.mp3'
          : '/library/duration/work-track.mp3',
      groupKey: Platform.isWindows
          ? r'C:\library\duration'
          : '/library/duration',
      groupTitle: 'Duration',
    );
    final singleTrack = _track(
      name: 'Single track',
      path: Platform.isWindows
          ? r'C:\imports\single-track.mp3'
          : '/imports/single-track.mp3',
      groupKey: Platform.isWindows
          ? r'C:\imports\single-track.mp3'
          : '/imports/single-track.mp3',
      groupTitle: 'Single track',
      isSingle: true,
    ).copyWith(manualCoverPath: '/covers/single.jpg');
    final workSession = PlaybackSession(
      id: 'work-duration-session',
      currentTrackPath: workTrack.path,
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(false, ProcessingState.ready),
    );
    final singleSession = PlaybackSession(
      id: 'single-duration-session',
      currentTrackPath: singleTrack.path,
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026, 1, 2),
      state: PlayerState(false, ProcessingState.ready),
    );
    addTearDown(audioProvider.dispose);
    audioProvider.addTracks([workTrack, singleTrack], persist: false);
    playbackService.registerSession(workSession);
    playbackService.registerSession(singleSession);
    playbackService.syncSlice(
      activeSessions: [workSession, singleSession],
      playingSessionCount: 0,
      focusedSessionId: workSession.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(
      _buildTestApp(
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
        child: const PlaylistTab(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('02:05'), findsNothing);

    workSession.setOptimisticDuration(const Duration(minutes: 2, seconds: 5));
    singleSession.setOptimisticDuration(
      const Duration(minutes: 1, seconds: 10),
    );
    await tester.pumpAndSettle();

    expect(find.text('02:05'), findsOneWidget);
    expect(find.text('01:10'), findsOneWidget);

    final workDetailTarget = AudioDetailTarget.libraryRootFolder(
      workTrack.groupKey,
    );
    final singleDetailTarget = AudioDetailTarget.singleAudioFile(
      singleTrack.path,
    );
    await tester.runAsync(() async {
      await audioProvider.saveAudioDetail(
        AudioDetail.empty(
          workDetailTarget,
        ).copyWith(duration: const Duration(minutes: 3, seconds: 40)),
      );
      await audioProvider.saveAudioDetail(
        AudioDetail.empty(
          singleDetailTarget,
        ).copyWith(duration: const Duration(minutes: 4, seconds: 50)),
      );
    });
    playbackService.syncSlice(
      activeSessions: [workSession, singleSession],
      playingSessionCount: 0,
      focusedSessionId: workSession.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );
    await tester.pumpAndSettle();

    expect(
      audioProvider.resolvedAudioDetail(workDetailTarget)?.duration,
      const Duration(minutes: 3, seconds: 40),
    );
    expect(
      audioProvider.resolvedAudioDetail(singleDetailTarget)?.duration,
      const Duration(minutes: 4, seconds: 50),
    );
    final shownDurations = tester
        .widgetList<DurationOverlay>(find.byType(DurationOverlay))
        .map((overlay) => overlay.duration)
        .toList(growable: false);
    expect(shownDurations, contains(const Duration(minutes: 2, seconds: 5)));
    expect(shownDurations, contains(const Duration(minutes: 4, seconds: 50)));
    expect(
      shownDurations,
      isNot(contains(const Duration(minutes: 3, seconds: 40))),
    );
    expect(find.text('02:05'), findsOneWidget);
    expect(find.text('04:50'), findsOneWidget);
    expect(find.text('03:40'), findsNothing);
    expect(find.text('01:10'), findsNothing);
  });

  testWidgets('playlist reordering does not trigger additional cover futures', (
    WidgetTester tester,
  ) async {
    final notificationService = PlaybackNotificationService();
    final audioDatabaseRepository = AudioDatabaseRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    const playbackCommandRunner = PlaybackCommandRunner();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository()
      ..cardPositionsLocked = false;
    final languageProvider = AppLanguageProvider();
    final coverCache = _RecordingPlaybackCoverCacheService();
    final audioProvider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: audioDatabaseRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
      coverArtworkCacheService: coverCache,
    );
    final track = _track(
      name: 'Warmup card',
      path: '/library/warmup/card.mp3',
      groupKey: '/library/warmup',
      groupTitle: 'Warmup',
    );
    final session = PlaybackSession(
      id: 'warmup-session',
      currentTrackPath: track.path,
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(false, ProcessingState.ready),
    );

    addTearDown(audioProvider.dispose);
    addTearDown(session.dispose);
    audioProvider.addTracks([track], notify: false, persist: false);
    playbackService.syncSlice(
      activeSessions: [session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(
      _buildTestApp(
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
        child: const PlaylistTab(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();

    // Clear any previously requested paths to isolate this test action
    coverCache.requestedPaths.clear();

    final reorderable = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    reorderable.onReorderStart?.call(0);
    await tester.pump();

    playbackService.syncSlice(
      activeSessions: [session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 1,
      isInitialized: true,
    );
    await tester.pump();

    expect(coverCache.requestedPaths, isEmpty);
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(const <String, Object>{});

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    testDatabase = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchemaForTest(testDatabase);
    AppDatabase.setInstanceForTest(AppDatabase.test(testDatabase));
  });

  tearDownAll(() async {
    AppDatabase.setInstanceForTest(null);
    await testDatabase.close();
  });

  testWidgets('top page header tolerates transient multiple scroll positions', (
    WidgetTester tester,
  ) async {
    final notificationService = PlaybackNotificationService();
    final audioDatabaseRepository = AudioDatabaseRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    const playbackCommandRunner = PlaybackCommandRunner();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository();
    final languageProvider = AppLanguageProvider();
    final audioProvider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: audioDatabaseRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
    );
    final controller = ScrollController();

    addTearDown(audioProvider.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _buildTestApp(
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
        child: Stack(
          children: [
            ListView(controller: controller, children: const [SizedBox()]),
            ListView(controller: controller, children: const [SizedBox()]),
            TopPageHeader(title: 'Library', collapseController: controller),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('top page header expands after reverse scroll away from top', (
    WidgetTester tester,
  ) async {
    final notificationService = PlaybackNotificationService();
    final audioDatabaseRepository = AudioDatabaseRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    const playbackCommandRunner = PlaybackCommandRunner();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository();
    final languageProvider = AppLanguageProvider();
    final audioProvider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: audioDatabaseRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
    );
    final controller = ScrollController();

    addTearDown(audioProvider.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _buildTestApp(
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
        child: Stack(
          children: [
            ListView.builder(
              controller: controller,
              itemCount: 80,
              itemBuilder: (context, index) => const SizedBox(height: 48),
            ),
            TopPageHeader(
              title: 'Library',
              subtitle: '198 audio',
              collapseController: controller,
              collapseDistance: 56,
              floatingReveal: true,
              floatingRevealDistance: 40,
              floatingRevealTriggerDistance: 40,
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    controller.jumpTo(120);
    await tester.pump();
    final collapsedHeight = tester.getSize(find.byType(TopPageHeader)).height;

    controller.jumpTo(104);
    await tester.pump();
    final beforeThresholdHeight = tester
        .getSize(find.byType(TopPageHeader))
        .height;

    controller.jumpTo(40);
    await tester.pump();
    final revealedHeight = tester.getSize(find.byType(TopPageHeader)).height;

    if (Platform.isWindows) {
      expect(beforeThresholdHeight, collapsedHeight);
      expect(revealedHeight, collapsedHeight);
    } else {
      expect(beforeThresholdHeight, collapsedHeight);
      expect(revealedHeight, greaterThan(collapsedHeight));
    }
  });

  testWidgets('library tab search submits asynchronously and removes misses', (
    WidgetTester tester,
  ) async {
    final notificationService = PlaybackNotificationService();
    final audioDatabaseRepository = AudioDatabaseRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    const playbackCommandRunner = PlaybackCommandRunner();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository();
    final languageProvider = AppLanguageProvider();
    final audioProvider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: audioDatabaseRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
    );

    addTearDown(audioProvider.dispose);

    audioProvider.addTracks(
      [
        _track(
          name: 'Soft Rain',
          path: '/library/rain/soft_rain.mp3',
          groupKey: '/library/rain/soft_rain.mp3',
          groupTitle: 'Soft Rain',
          isSingle: true,
        ),
        _track(
          name: 'Ocean Waves',
          path: '/library/rain/ocean_waves.mp3',
          groupKey: '/library/rain/ocean_waves.mp3',
          groupTitle: 'Ocean Waves',
          isSingle: true,
        ),
      ],
      notify: false,
      persist: false,
    );
    libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(
      _buildTestApp(
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
        child: const LibraryTab(),
      ),
    );
    await tester.pump();
    await _pumpUntilLibraryTreeReady(
      tester,
      audioProvider,
      waitForCategorySnapshot: true,
    );
    await tester.pump(const Duration(milliseconds: 500));

    if (Platform.isWindows) {
      final reorderArea = tester.widget<ContentBoundReorderArea>(
        find.byType(ContentBoundReorderArea),
      );
      expect(reorderArea.bottomExpansion, 320);
      final scrollbar = find.descendant(
        of: find.byType(ContentBoundReorderArea),
        matching: find.byType(Scrollbar),
      );
      expect(scrollbar, findsOneWidget);
      expect(
        MediaQuery.paddingOf(tester.element(scrollbar)).bottom,
        reorderArea.bottomInset +
            reorderArea.topExpansion +
            reorderArea.bottomExpansion,
      );
    }

    expect(find.byType(TextField), findsOneWidget);

    final scanGeneration = audioProvider.tryBeginScan(source: 'Music');
    audioProvider.setScanProgress(
      generation: scanGeneration,
      stage: FolderScanStage.enumerating,
      processed: 120,
      total: 500,
      foundCount: 120,
    );
    await tester.pump(const Duration(milliseconds: 180));
    expect(
      find.byKey(const ValueKey('library_scan_progress_card')),
      findsOneWidget,
    );
    final progress = tester.widget<LinearProgressIndicator>(
      find.descendant(
        of: find.byKey(const ValueKey('library_scan_progress_card')),
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    expect(progress.value, closeTo(0.24, 0.001));
    expect(
      find.text(
        languageProvider.tr('scan_processed_total', {
          'processed': 120,
          'total': 500,
        }),
      ),
      findsOneWidget,
    );
    audioProvider.finishScan(scanGeneration);
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'ocean');
    await _pumpUntilNotFound(
      tester,
      find.text('Soft Rain', findRichText: true),
    );

    expect(find.text('Soft Rain', findRichText: true), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('expanding a library folder keeps its resolved cover visible', (
    WidgetTester tester,
  ) async {
    Future<String?> coverFuture = SynchronousFuture<String?>('cover-path');

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: StatefulBuilder(
            builder: (context, setState) => ExpansionTile(
              onExpansionChanged: (expanded) {
                if (!expanded) return;
                setState(() {
                  coverFuture = SynchronousFuture<String?>(null);
                });
              },
              title: SizedBox(
                width: 80,
                height: 64,
                child: AsyncCoverImage(
                  requestKey: 'library-folder',
                  initialPath: 'cover-path',
                  future: coverFuture,
                  retryFutureBuilder: () => SynchronousFuture<String?>(null),
                  imageBuilder: (_, _) => const ColoredBox(
                    key: ValueKey('resolved-cover'),
                    color: Colors.blue,
                  ),
                  fallbackBuilder: (_) =>
                      const SizedBox(key: ValueKey('cover-fallback')),
                ),
              ),
              children: const [SizedBox(height: 40)],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('resolved-cover')), findsOneWidget);

    await tester.tap(find.byType(ExpansionTile));
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const ValueKey('resolved-cover')), findsOneWidget);
    expect(find.byKey(const ValueKey('cover-fallback')), findsNothing);
  });

  testWidgets(
    'library tab shows localized empty state when search has no matches',
    (WidgetTester tester) async {
      final notificationService = PlaybackNotificationService();
      final audioDatabaseRepository = AudioDatabaseRepository();
      final nativePlaybackRepository = NativePlaybackRepository();
      const playbackCommandRunner = PlaybackCommandRunner();
      final libraryService = LibraryService();
      final playbackService = PlaybackSessionService();
      final timerService = TimerService();
      final notificationCoordinatorService = NotificationCoordinatorService();
      final settingsRepository = SettingsRepository();
      final languageProvider = AppLanguageProvider();
      final audioProvider = AudioProvider.test(
        notificationService: notificationService,
        audioDatabaseRepository: audioDatabaseRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationStateService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
      );

      addTearDown(audioProvider.dispose);

      audioProvider.addTracks(
        [
          _track(
            name: 'Soft Rain',
            path: '/library/rain/soft_rain.mp3',
            groupKey: '/library/rain',
            groupTitle: 'Rain Pack',
          ),
        ],
        notify: false,
        persist: false,
      );
      libraryService.syncSlice(isInitialized: true, detailRevision: 0);

      await tester.pumpWidget(
        _buildTestApp(
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
          child: const LibraryTab(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(audioProvider.libraryTreeSnapshotRevision, -1);

      await tester.enterText(find.byType(TextField), 'forest');
      await tester.pump(const Duration(milliseconds: 260));
      await _pumpUntilFound(
        tester,
        find.text(languageProvider.tr('no_search_results')),
      );

      expect(
        find.text(languageProvider.tr('no_search_results')),
        findsOneWidget,
      );
      expect(
        audioProvider.libraryTreeSnapshotRevision,
        libraryService.structureRevision,
      );
    },
  );

  testWidgets('library more menu opens formal library management only', (
    WidgetTester tester,
  ) async {
    final notificationService = PlaybackNotificationService();
    final audioDatabaseRepository = AudioDatabaseRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    const playbackCommandRunner = PlaybackCommandRunner();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository();
    final languageProvider = AppLanguageProvider();
    final audioProvider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: audioDatabaseRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
    );

    addTearDown(audioProvider.dispose);

    const libraryRoot = '/library/root';
    const childFolder = '/library/root/child';
    const standaloneFolder = '/library/standalone';
    audioProvider.addWatchedLibrary(libraryRoot, notify: false);
    audioProvider.addWatchedFolder(childFolder, notify: false);
    audioProvider.addWatchedFolder(standaloneFolder, notify: false);
    audioProvider.recordLibraryEntriesForTracks(
      standaloneFolder,
      const <MusicTrack>[],
      persist: false,
    );
    libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(
      _buildTestApp(
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
        child: const LibraryTab(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byTooltip(languageProvider.tr('more_actions')), findsOneWidget);
    expect(find.byTooltip(languageProvider.tr('import_audio')), findsOneWidget);
    expect(find.byTooltip(languageProvider.tr('edit_library')), findsNothing);
    await tester.tap(find.byTooltip(languageProvider.tr('more_actions')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text(languageProvider.tr('edit_library')), findsOneWidget);
    expect(find.text(languageProvider.tr('batch_metadata')), findsOneWidget);
    expect(
      find.text(languageProvider.tr('fixed_card_positions')),
      findsOneWidget,
    );
    await tester.tap(find.text(languageProvider.tr('edit_library')));
    await tester.pumpAndSettle();

    expect(find.text('root'), findsOneWidget);
    expect(find.text('standalone'), findsNothing);
    expect(find.text('child'), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('playlist more menu toggles fixed card positions', (
    WidgetTester tester,
  ) async {
    final notificationService = PlaybackNotificationService();
    final audioDatabaseRepository = AudioDatabaseRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    const playbackCommandRunner = PlaybackCommandRunner();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository();
    final languageProvider = AppLanguageProvider();
    final audioProvider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: audioDatabaseRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
    );

    addTearDown(audioProvider.dispose);
    playbackService.syncSlice(
      activeSessions: const [],
      playingSessionCount: 0,
      focusedSessionId: null,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(
      _buildTestApp(
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
        child: const PlaylistTab(),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip(languageProvider.tr('more_actions')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      find.text(languageProvider.tr('fixed_card_positions')),
      findsOneWidget,
    );
    expect(
      find.text(languageProvider.tr('add_playback_queue')),
      findsOneWidget,
    );

    await tester.tap(find.text(languageProvider.tr('add_playback_queue')));
    await tester.pumpAndSettle();

    expect(
      audioProvider.activeSessions.where((session) => session.isPlaybackQueue),
      hasLength(1),
    );
    expect(
      audioProvider.activeSessions
          .singleWhere((session) => session.isPlaybackQueue)
          .playbackQueue
          ?.name,
      languageProvider.tr('default_playback_queue_name', {'number': 1}),
    );
    final queueSession = audioProvider.activeSessions.singleWhere(
      (session) => session.isPlaybackQueue,
    );
    unawaited(
      showPlaybackQueueEditPanel(
        tester.element(find.byType(PlaylistTab)),
        queueSession.id,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(languageProvider.tr('edit_queue_audio')), findsOneWidget);
    expect(find.text(languageProvider.tr('edit_queue_name')), findsOneWidget);
    expect(find.text(languageProvider.tr('edit_card_color')), findsOneWidget);
    expect(find.text(languageProvider.tr('remove_queue')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets(
    'single-file queue cover fills the card and switcher shows an audio entry',
    (WidgetTester tester) async {
      final notificationService = PlaybackNotificationService();
      final audioDatabaseRepository = AudioDatabaseRepository();
      final nativePlaybackRepository = NativePlaybackRepository();
      const playbackCommandRunner = PlaybackCommandRunner();
      final libraryService = LibraryService();
      final playbackService = PlaybackSessionService();
      final timerService = TimerService();
      final notificationCoordinatorService = NotificationCoordinatorService();
      final settingsRepository = SettingsRepository();
      final languageProvider = AppLanguageProvider();
      final audioProvider = AudioProvider.test(
        notificationService: notificationService,
        audioDatabaseRepository: audioDatabaseRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationStateService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
      );
      const track = MusicTrack(
        path: '/imports/standalone.mp4',
        displayName: 'Standalone clip',
        groupKey: '__single_files__',
        groupTitle: 'Imported files',
        groupSubtitle: 'Manually selected files',
        isSingle: true,
        isVideo: true,
      );
      audioProvider.addTracks(
        const <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      final queueSession = audioProvider.createPlaybackQueue('Queue 1');
      queueSession
        ..currentTrackPath = track.path
        ..currentQueueIndex = 0
        ..playbackQueue = const PlaybackQueueDefinition(
          name: 'Queue 1',
          entries: <PlaybackQueueEntry>[
            PlaybackQueueEntry(
              id: 'legacy-single-work',
              kind: PlaybackQueueEntryKind.work,
              title: 'Imported files',
              tracks: <MusicTrack>[track],
            ),
          ],
        );
      playbackService.syncSlice(
        activeSessions: <PlaybackSession>[queueSession],
        playingSessionCount: 0,
        focusedSessionId: queueSession.id,
        multiThreadPlaybackEnabled: false,
        coverGeneration: 0,
        isInitialized: true,
      );
      addTearDown(audioProvider.dispose);

      await tester.pumpWidget(
        _buildTestApp(
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
          child: const PlaylistTab(),
        ),
      );
      await tester.pumpAndSettle();

      final grid = find.byKey(const ValueKey('playback_queue_cover_grid'));
      final firstCell = find.byKey(
        const ValueKey('playback_queue_cover_cell_0'),
      );
      expect(tester.getSize(grid), const Size(96, 72));
      expect(tester.getSize(firstCell), const Size(96, 72));

      unawaited(
        Navigator.of(
          tester.element(find.byType(PlaylistTab)),
        ).push(buildSessionDetailRoute(sessionId: queueSession.id)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(languageProvider.tr('switch_audio')));
      await tester.pumpAndSettle();

      final sheet = find.byType(BottomSheet);
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(of: sheet, matching: find.text(track.displayName)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: sheet,
          matching: find.text(languageProvider.tr('imported_files')),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('settings detail section configures card info fields', (
    WidgetTester tester,
  ) async {
    final notificationService = PlaybackNotificationService();
    final audioDatabaseRepository = AudioDatabaseRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    const playbackCommandRunner = PlaybackCommandRunner();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository();
    final languageProvider = AppLanguageProvider();
    final audioProvider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: audioDatabaseRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
    );

    addTearDown(audioProvider.dispose);

    await tester.pumpWidget(
      _buildTestApp(
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
        child: const SettingsTab(),
      ),
    );
    await tester.pump();

    expect(
      find.text(languageProvider.tr('dlsite_metadata_language')),
      findsOneWidget,
    );
    expect(find.text(languageProvider.tr('startup_page')), findsOneWidget);

    final settingsScrollable = find
        .descendant(
          of: find.byType(SettingsTab),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text(languageProvider.tr('bottom_navigation_style')),
      120,
      scrollable: settingsScrollable,
    );
    expect(
      find.text(languageProvider.tr('bottom_navigation_style')),
      findsOneWidget,
    );

    final bottomNavigationStyleTile = find.widgetWithText(
      SwitchListTile,
      languageProvider.tr('bottom_navigation_style'),
    );
    await Scrollable.ensureVisible(
      tester.element(bottomNavigationStyleTile),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(bottomNavigationStyleTile);
    await tester.pumpAndSettle();

    expect(audioProvider.bottomNavigationStyle, BottomNavigationStyle.bar);

    await tester.scrollUntilVisible(
      find.text(languageProvider.tr('card_info_display')),
      300,
      scrollable: settingsScrollable,
    );
    expect(find.text(languageProvider.tr('card_info_display')), findsOneWidget);

    final cardInfoTile = find.widgetWithText(
      ListTile,
      languageProvider.tr('card_info_display'),
    );
    await Scrollable.ensureVisible(
      tester.element(cardInfoTile),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(cardInfoTile);
    await tester.pumpAndSettle();

    expect(
      find.text(
        languageProvider.tr('card_info_display_subtitle', {
          'count': '4',
          'max': '6',
        }),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.widgetWithText(
        CheckboxListTile,
        languageProvider.tr('audio_detail_release_date'),
      ),
    );
    await tester.pump();

    expect(audioProvider.cardInfoFields, hasLength(5));
    final salesTile = tester.widget<CheckboxListTile>(
      find.widgetWithText(
        CheckboxListTile,
        languageProvider.tr('audio_detail_sales_count'),
      ),
    );
    expect(salesTile.onChanged, isNotNull);

    await tester.tap(
      find.widgetWithText(
        CheckboxListTile,
        languageProvider.tr('audio_detail_sales_count'),
      ),
    );
    await tester.pump();

    expect(audioProvider.cardInfoFields, hasLength(CardInfoField.maxSelected));
    final ratingTile = tester.widget<CheckboxListTile>(
      find.widgetWithText(
        CheckboxListTile,
        languageProvider.tr('audio_detail_rating'),
      ),
    );
    expect(ratingTile.onChanged, isNull);
  });

  testWidgets(
    'batch metadata page defaults to missing works and shows counts',
    (WidgetTester tester) async {
      final notificationService = PlaybackNotificationService();
      final audioDatabaseRepository = AudioDatabaseRepository();
      final nativePlaybackRepository = NativePlaybackRepository();
      const playbackCommandRunner = PlaybackCommandRunner();
      final libraryService = LibraryService();
      final playbackService = PlaybackSessionService();
      final timerService = TimerService();
      final notificationCoordinatorService = NotificationCoordinatorService();
      final settingsRepository = SettingsRepository();
      final languageProvider = AppLanguageProvider();
      final audioProvider = AudioProvider.test(
        notificationService: notificationService,
        audioDatabaseRepository: audioDatabaseRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationStateService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
      );

      addTearDown(audioProvider.dispose);

      await tester.pumpWidget(
        _buildTestApp(
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
    final notificationService = PlaybackNotificationService();
    final audioDatabaseRepository = AudioDatabaseRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    const playbackCommandRunner = PlaybackCommandRunner();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository();
    final languageProvider = AppLanguageProvider();
    final audioProvider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: audioDatabaseRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
      dlsiteMetadataService: _FakeDlsiteMetadataService(),
      asmrMetadataService: _FakeAsmrMetadataService(),
    );

    addTearDown(audioProvider.dispose);

    await tester.pumpWidget(
      _buildTestApp(
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
      final notificationService = PlaybackNotificationService();
      final audioDatabaseRepository = AudioDatabaseRepository();
      final nativePlaybackRepository = NativePlaybackRepository();
      final libraryService = LibraryService();
      final playbackService = PlaybackSessionService();
      final timerService = TimerService();
      final notificationCoordinatorService = NotificationCoordinatorService();
      final settingsRepository = SettingsRepository();
      final audioProvider = AudioProvider.test(
        notificationService: notificationService,
        audioDatabaseRepository: audioDatabaseRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationStateService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
        dlsiteMetadataService: _FakeDlsiteMetadataService(),
        asmrMetadataService: _FakeAsmrMetadataService(),
      );

      addTearDown(audioProvider.dispose);

      final metadata = (await audioProvider.searchPreferredMetadataByTitles(
        const <String>['Work'],
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
      final notificationService = PlaybackNotificationService();
      final audioDatabaseRepository = AudioDatabaseRepository();
      final nativePlaybackRepository = NativePlaybackRepository();
      const playbackCommandRunner = PlaybackCommandRunner();
      final libraryService = LibraryService();
      final playbackService = PlaybackSessionService();
      final timerService = TimerService();
      final notificationCoordinatorService = NotificationCoordinatorService();
      final settingsRepository = SettingsRepository();
      final languageProvider = AppLanguageProvider();
      final audioProvider = AudioProvider.test(
        notificationService: notificationService,
        audioDatabaseRepository: audioDatabaseRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationStateService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
      );
      addTearDown(audioProvider.dispose);

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
        _buildTestApp(
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
      await _pumpUntilLibraryTreeReady(tester, audioProvider);
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
      await _pumpUntilNotFound(tester, find.byType(AlertDialog));
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

  testWidgets('audio detail fetch opens metadata scope page', (
    WidgetTester tester,
  ) async {
    final notificationService = PlaybackNotificationService();
    final audioDatabaseRepository = AudioDatabaseRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    const playbackCommandRunner = PlaybackCommandRunner();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository();
    final languageProvider = AppLanguageProvider();
    final audioProvider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: audioDatabaseRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
    );

    addTearDown(audioProvider.dispose);
    const target = AudioDetailTarget(
      targetType: AudioDetailTargetType.libraryRootFolder,
      targetPath: '/library/Work',
    );
    await tester.runAsync(
      () => audioProvider.saveAudioDetail(AudioDetail.empty(target)),
    );

    await tester.pumpWidget(
      _buildTestApp(
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

  testWidgets('library edit keeps restored content folder visible', (
    WidgetTester tester,
  ) async {
    final notificationService = PlaybackNotificationService();
    final audioDatabaseRepository = AudioDatabaseRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    const playbackCommandRunner = PlaybackCommandRunner();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository();
    final languageProvider = AppLanguageProvider();
    final audioProvider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: audioDatabaseRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
    );

    addTearDown(audioProvider.dispose);

    const libraryRoot =
        'content://com.android.externalstorage.documents/tree/primary%3AASMR';
    const childFolder = '$libraryRoot/document/primary%3AASMR%2FWorkA';
    const syntheticChildFolder = '$libraryRoot::WorkA';
    const nestedFolder = '$libraryRoot::WorkA/Disc1';
    const trackPath =
        'content://com.android.externalstorage.documents/tree/primary%3AASMR/document/primary%3AASMR%2FWorkA%2FDisc1%2F01.mp3';

    audioProvider.addWatchedLibrary(libraryRoot, notify: false);
    audioProvider.addWatchedFolder(childFolder, notify: false);
    audioProvider.recordLibraryEntriesForTracks(
      libraryRoot,
      const <MusicTrack>[],
      folderPaths: const <String>[childFolder],
      persist: false,
    );
    audioProvider.addTracks(
      [
        _track(
          name: '01',
          path: trackPath,
          groupKey: nestedFolder,
          groupTitle: 'Disc1',
        ),
      ],
      notify: false,
      persist: false,
    );
    libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(
      _buildTestApp(
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
        child: const LibraryEditPage(libraryPath: libraryRoot),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('WorkA', findRichText: true), findsOneWidget);
    expect(
      libraryService
          .libraryEntriesForLibrary(libraryRoot)
          .where((entry) => entry.path == syntheticChildFolder),
      hasLength(1),
    );
    expect(
      find.text('1 \u9996\u97f3\u9891', findRichText: true),
      findsOneWidget,
    );

    await tester.tap(
      find.widgetWithText(TextButton, languageProvider.tr('exclude')).first,
    );
    await tester.pump();

    expect(find.text('WorkA', findRichText: true), findsOneWidget);
    expect(find.text(languageProvider.tr('restore')), findsOneWidget);

    await tester.tap(find.text('WorkA', findRichText: true).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Disc1', findRichText: true), findsOneWidget);
    final disabledChildActions = tester
        .widgetList<TextButton>(
          find.widgetWithText(TextButton, languageProvider.tr('exclude')),
        )
        .where((button) => button.onPressed == null);
    expect(disabledChildActions, isNotEmpty);

    await tester.tap(
      find.widgetWithText(TextButton, languageProvider.tr('restore')).first,
    );
    await tester.pump();

    expect(find.text('WorkA', findRichText: true), findsOneWidget);
    expect(find.text('1 \u9996\u97f3\u9891', findRichText: true), findsWidgets);

    expect(find.text('Disc1', findRichText: true), findsOneWidget);
    expect(find.text(languageProvider.tr('exclude')), findsWidgets);
  });

  testWidgets('library edit keeps decoded content track name after exclusion', (
    WidgetTester tester,
  ) async {
    final notificationService = PlaybackNotificationService();
    final audioDatabaseRepository = AudioDatabaseRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    const playbackCommandRunner = PlaybackCommandRunner();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository();
    final languageProvider = AppLanguageProvider();
    final audioProvider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: audioDatabaseRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
    );

    addTearDown(audioProvider.dispose);

    const libraryRoot =
        'content://com.android.externalstorage.documents/tree/primary%3AASMR';
    const trackPath =
        'content://com.android.externalstorage.documents/tree/primary%3AASMR/document/primary%3AASMR%2F%E3%82%8C%E3%81%84%E3%81%8D%E3%82%89%E8%80%B3%E8%88%90%E3%82%81.mp3';

    audioProvider.addWatchedLibrary(libraryRoot, notify: false);
    audioProvider.addTracks(
      [
        _track(
          name: 'れいきら耳舐め',
          path: trackPath,
          groupKey: libraryRoot,
          groupTitle: 'ASMR',
        ),
      ],
      notify: false,
      persist: false,
    );
    libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(
      _buildTestApp(
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
        child: const LibraryEditPage(libraryPath: libraryRoot),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(
      find.widgetWithText(TextButton, languageProvider.tr('exclude')).first,
    );
    await tester.pump();

    expect(find.text('れいきら耳舐め'), findsOneWidget);
    expect(find.textContaining('primary%3A'), findsNothing);
    expect(find.text(languageProvider.tr('restore')), findsOneWidget);

    await tester.tap(
      find.widgetWithText(TextButton, languageProvider.tr('restore')).first,
    );
    await tester.pump(const Duration(milliseconds: 20));

    expect(audioProvider.trackByPath(trackPath)?.displayName, 'れいきら耳舐め');
    expect(find.text('れいきら耳舐め'), findsOneWidget);
    expect(find.textContaining('primary%3A'), findsNothing);
    expect(find.text(languageProvider.tr('exclude')), findsOneWidget);
  });
}
