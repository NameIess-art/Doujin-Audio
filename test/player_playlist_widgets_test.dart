import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/app/state/audio_provider.dart';
import 'package:nameless_audio/app/state/audio_provider_riverpod.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/features/player/application/playback_facade.dart';
import 'package:nameless_audio/features/player/presentation/playlist_tab.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:nameless_audio/features/player/application/audio_state_services.dart';
import 'package:nameless_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:nameless_audio/core/widgets/duration_overlay.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/audio_provider_test_fixture.dart';

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
  AudioProviderTestFixture.initialize();
  late Database testDatabase;

  setUpAll(() async {
    testDatabase = await AudioProviderTestFixture.installSharedDatabase();
  });

  tearDownAll(() async {
    await AudioProviderTestFixture.disposeSharedDatabase(testDatabase);
  });

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

  test('ASMR session switcher displays tracks in natural path order', () {
    MusicTrack asmrTrack(String title) {
      final relativePath = '01/$title.mp3';
      return MusicTrack(
        path: 'https://example.test/$relativePath',
        displayName: title,
        groupKey: 'asmr-work-1',
        groupTitle: 'Work',
        groupSubtitle: 'RJ000001',
        isSingle: false,
        remoteMetadataKind: 'asmr.one',
        remoteMetadata: <String, Object?>{'trackRelativePath': relativePath},
      );
    }

    const sortedTitles = <String>[
      'トラック１',
      'トラック２',
      'トラック３',
      'トラック４',
      'トラック５',
      'トラック６',
      'トラック７',
      'トラック８',
      'トラック９',
      'トラック１０',
      'トラック１１',
    ];
    final rotated = <MusicTrack>[
      asmrTrack(sortedTitles[9]),
      asmrTrack(sortedTitles[10]),
      ...sortedTitles.skip(1).take(8).map(asmrTrack),
      asmrTrack(sortedTitles[0]),
    ];

    final ordered = orderTracksForSessionSwitcher(
      rotated,
      preserveQueueOrder: false,
    );

    expect(ordered.map((track) => track.displayName), sortedTitles);
    expect(
      orderTracksForSessionSwitcher(rotated, preserveQueueOrder: true),
      same(rotated),
    );
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
    final playbackFacade = PlaybackFacade.create(
      databaseRepository: AudioDatabaseRepository(),
      service: playbackService,
    );
    addTearDown(playbackFacade.dispose);
    final container = ProviderContainer(
      overrides: [playbackFacadeProvider.overrideWithValue(playbackFacade)],
    );
    addTearDown(container.dispose);

    final paths = container.read(activeTrackPathsProvider);

    expect(paths.contains('/tracks/active.mp3'), isTrue);
    expect(paths.contains(''), isFalse);
    expect(container.read(isTrackActiveProvider('/tracks/active.mp3')), isTrue);
    expect(container.read(isTrackActiveProvider('/tracks/other.mp3')), isFalse);
  });

  testWidgets('volume balance can be restored to default', (
    WidgetTester tester,
  ) async {
    const nativePlaybackChannel = MethodChannel(NativePlaybackChannel.name);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          nativePlaybackChannel,
          (_) async => <String, Object?>{'ok': true, 'value': null},
        );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, null);
    });

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
    final track = testMusicTrack(
      name: 'Balance track',
      path: '/library/balance/track.mp3',
      groupKey: '/library/balance',
      groupTitle: 'Balance',
    );
    final session = PlaybackSession(
      id: 'balance-session',
      currentTrackPath: track.path,
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(false, ProcessingState.ready),
    )..audioEffects = AudioEffectsState.flat.copyWith(panning: 0.6);
    audioProvider.addTracks(<MusicTrack>[track], notify: false, persist: false);
    playbackService.registerSession(session);
    playbackService.syncSlice(
      activeSessions: <PlaybackSession>[session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
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
        child: const PlaylistTab(),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(
      Navigator.of(
        tester.element(find.byType(PlaylistTab)),
      ).push(buildSessionDetailRoute(sessionId: session.id)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(languageProvider.tr('audio_features')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(languageProvider.tr('volume_balance')));
    await tester.pumpAndSettle();

    final restoreButton = find.byKey(
      const ValueKey<String>('restore_volume_balance'),
    );
    expect(restoreButton, findsOneWidget);
    expect(find.text(languageProvider.tr('restore_default')), findsOneWidget);
    await tester.tap(restoreButton);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    expect(session.audioEffects.panning, 0.0);
    expect(tester.widget<FilledButton>(restoreButton).onPressed, isNull);
  });

  testWidgets('playlist cards freeze background updates while reordering', (
    WidgetTester tester,
  ) async {
    final fixture = AudioProviderWidgetTestFixture(
      configureSettingsRepository: (settingsRepository) {
        settingsRepository.cardPositionsLocked = false;
        settingsRepository.syncSlice();
      },
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
    final track = testMusicTrack(
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
    final workTrack = testMusicTrack(
      name: 'Work track',
      path: Platform.isWindows
          ? r'C:\library\duration\work-track.mp3'
          : '/library/duration/work-track.mp3',
      groupKey: Platform.isWindows
          ? r'C:\library\duration'
          : '/library/duration',
      groupTitle: 'Duration',
    );
    final singleTrack = testMusicTrack(
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
    final coverCache = _RecordingPlaybackCoverCacheService();
    final fixture = AudioProviderWidgetTestFixture(
      coverArtworkCacheService: coverCache,
      configureSettingsRepository: (settingsRepository) {
        settingsRepository.cardPositionsLocked = false;
      },
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
    final track = testMusicTrack(
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

  testWidgets('playlist more menu toggles fixed card positions', (
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

    playbackService.syncSlice(
      activeSessions: const [],
      playingSessionCount: 0,
      focusedSessionId: null,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
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
}
