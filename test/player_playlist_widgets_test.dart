import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'support/runtime_test_models.dart';
import 'package:nameless_audio/app/state/app_runtime_providers.dart';
import 'package:nameless_audio/core/media/subtitle_parser.dart';
import 'support/test_persistence_repository.dart';
import 'package:nameless_audio/features/player/application/playback_facade.dart';
import 'package:nameless_audio/features/player/application/playback_subtitle_service.dart';
import 'package:nameless_audio/features/player/presentation/playlist_tab.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:nameless_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:nameless_audio/features/library/application/library_service.dart';
import 'package:nameless_audio/core/widgets/app_transitions.dart';
import 'package:nameless_audio/core/widgets/duration_overlay.dart';
import 'package:nameless_audio/core/widgets/app_feedback.dart';
import 'package:nameless_audio/core/widgets/swipe_reveal_card.dart';
import 'package:nameless_audio/core/widgets/top_page_header.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';

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

  @override
  Future<String?> futureForTrack(MusicTrack? track, {String? trackPath}) =>
      SynchronousFuture<String?>(null);
}

void _expectThemeSessionResetButtonStyle(WidgetTester tester, Finder finder) {
  expect(finder, findsOneWidget);
  final button = tester.widget<FilledButton>(finder);
  final style = button.style!;
  final colorScheme = Theme.of(tester.element(finder)).colorScheme;
  const enabled = <WidgetState>{};
  const disabled = <WidgetState>{WidgetState.disabled};

  expect(style.minimumSize!.resolve(enabled), const Size(96, 40));
  expect(
    style.padding!.resolve(enabled),
    const EdgeInsets.symmetric(horizontal: 20),
  );
  expect(style.shape!.resolve(enabled), isA<StadiumBorder>());
  expect(style.tapTargetSize, MaterialTapTargetSize.padded);
  expect(style.visualDensity, VisualDensity.standard);
  expect(style.elevation!.resolve(enabled), 0);
  expect(style.backgroundColor!.resolve(enabled), colorScheme.primary);
  expect(style.foregroundColor!.resolve(enabled), colorScheme.onPrimary);
  expect(
    style.overlayColor!.resolve(const <WidgetState>{WidgetState.pressed}),
    colorScheme.onPrimary.withValues(alpha: 0.14),
  );
  expect(
    style.backgroundColor!.resolve(disabled),
    colorScheme.onSurface.withValues(alpha: 0.12),
  );
  expect(
    style.foregroundColor!.resolve(disabled),
    colorScheme.onSurface.withValues(alpha: 0.50),
  );
  final textStyle = style.textStyle!.resolve(enabled)!;
  expect(textStyle.fontSize, 14);
  expect(textStyle.fontWeight, FontWeight.w600);
  expect(textStyle.height, 1);
}

Future<({AppRuntimeWidgetTestFixture fixture, PlaybackSession session})>
_pumpSubtitleDetail({
  required WidgetTester tester,
  required PlaybackDetailSubtitleStyle style,
  required SubtitleTrack subtitleTrack,
  required Duration initialPosition,
}) async {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = const Size(1080, 2400);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final track = MusicTrack(
    path: '/library/subtitles/track.mp3',
    displayName: 'Subtitle track',
    groupKey: '/library/subtitles',
    groupTitle: 'Subtitle album',
    groupSubtitle: '/library/subtitles',
    isSingle: false,
  );
  final fixture = AppRuntimeWidgetTestFixture(
    coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
    configureSettingsRepository: (settings) {
      settings.playbackDetailSubtitleStyle = style;
      settings.syncSlice(isInitialized: true);
    },
  );
  addTearDown(fixture.dispose);
  fixture.runtimeGraph.library.addTracks(
    <MusicTrack>[track],
    notify: false,
    persist: false,
  );
  final session = PlaybackSession(
    id: 'subtitle-session',
    currentTrackPath: track.path,
    loopMode: SessionLoopMode.single,
    nonSingleLoopMode: SessionLoopMode.single,
    volume: 1,
    createdAt: DateTime(2026),
    state: PlayerState(false, ProcessingState.ready),
  )..setOptimisticPosition(initialPosition);
  fixture.playbackService.registerSession(session);
  fixture.playbackService.syncSlice(
    activeSessions: <PlaybackSession>[session],
    playingSessionCount: 0,
    focusedSessionId: session.id,
    multiThreadPlaybackEnabled: false,
    coverGeneration: 0,
    isInitialized: true,
  );
  final subtitleService = PlaybackSubtitleService(
    trackResolver: (_) => track,
    subtitleLoader: (_, _) async => subtitleTrack,
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        nativePlaybackChannel,
        (_) async => <String, Object?>{'ok': true, 'value': null},
      );
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativePlaybackChannel, null);
  });

  await tester.pumpWidget(
    fixture.build(const PlaylistTab(), subtitleService: subtitleService),
  );
  await tester.pumpAndSettle();
  unawaited(
    Navigator.of(
      tester.element(find.byType(PlaylistTab)),
    ).push(buildSessionDetailRoute(sessionId: session.id)),
  );
  await tester.pumpAndSettle();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pump();

  return (fixture: fixture, session: session);
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

  test('equalizer badge only appears while equalizer is enabled', () {
    final disabledIcons = sessionFeatureBadgeIcons(
      showSubtitles: false,
      channelSwapEnabled: false,
      audioEffects: AudioEffectsState(eqPresetId: 'voice_clear'),
      speed: 1,
    );
    final enabledIcons = sessionFeatureBadgeIcons(
      showSubtitles: false,
      channelSwapEnabled: false,
      audioEffects: AudioEffectsState(eqEnabled: true),
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
      databaseRepository: TestPersistenceRepository(),
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

  testWidgets('playlist first open fades its card skeleton out over 750ms', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    fixture.playbackService.syncSlice(
      activeSessions: const <PlaybackSession>[],
      playingSessionCount: 0,
      focusedSessionId: null,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: fixture.runtimeGraph,
        persistenceRepository: fixture.persistenceRepository,
        nativePlaybackRepository: fixture.nativePlaybackRepository,
        playbackCommandRunner:
            AppRuntimeWidgetTestFixture.playbackCommandRunner,
        libraryService: fixture.libraryService,
        playbackService: fixture.playbackService,
        timerService: fixture.timerService,
        notificationCoordinatorService: fixture.notificationCoordinatorService,
        settingsRepository: fixture.settings,
        languageProvider: fixture.languageProvider,
        child: const PlaylistTab(),
      ),
    );

    const placeholderKey = ValueKey<String>('playlist_initial_placeholder');
    const contentKey = ValueKey<String>('playlist_loaded_content');
    expect(find.byKey(placeholderKey), findsOneWidget);
    expect(find.byKey(contentKey), findsNothing);

    final skeletonCards = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('playlist_skeleton_card_');
    });
    expect(skeletonCards, findsAtLeastNWidgets(5));
    final firstSkeleton = tester.widget<Container>(skeletonCards.first);
    expect(firstSkeleton.padding, const EdgeInsets.all(8));
    expect(
      (firstSkeleton.decoration! as BoxDecoration).border,
      isNull,
      reason: 'Playlist loading items should match the borderless list style.',
    );
    final skeletonTrailingCircles = find.descendant(
      of: skeletonCards.first,
      matching: find.byWidgetPredicate((widget) {
        return widget is Container &&
            widget.decoration is BoxDecoration &&
            (widget.decoration! as BoxDecoration).shape == BoxShape.circle;
      }),
    );
    expect(skeletonTrailingCircles, findsNothing);
    expect(
      tester.getTopLeft(skeletonCards.first).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(find.byType(TopPageHeader)).dy),
    );
    expect(
      tester.getBottomLeft(skeletonCards.last).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.byType(PlaylistTab)).dy - 16,
      ),
    );

    await tester.pump();
    expect(find.byKey(placeholderKey), findsOneWidget);
    expect(find.byKey(contentKey), findsOneWidget);

    await tester.pump(
      kPlaceholderContentTransitionDuration - const Duration(milliseconds: 1),
    );
    expect(find.byKey(placeholderKey), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.byKey(placeholderKey), findsNothing);
    expect(find.byKey(contentKey), findsOneWidget);
  });

  testWidgets('session reset actions share style and disable at defaults', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
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
    runtimeGraph.library.addTracks(
      <MusicTrack>[track],
      notify: false,
      persist: false,
    );
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

    const portraitDividerKey = ValueKey<String>('portrait_console_divider');
    expect(find.byKey(portraitDividerKey), findsOneWidget);
    tester.view.physicalSize = const Size(900, 430);
    await tester.pumpAndSettle();
    expect(find.byKey(portraitDividerKey), findsNothing);
    tester.view.physicalSize = const Size(430, 900);
    await tester.pumpAndSettle();

    final speedRestoreButton = find.byKey(
      const ValueKey<String>('restore_playback_speed'),
    );
    _expectThemeSessionResetButtonStyle(tester, speedRestoreButton);
    expect(tester.widget<FilledButton>(speedRestoreButton).onPressed, isNull);

    await tester.tap(find.text(languageProvider.tr('equalizer')));
    await tester.pumpAndSettle();
    final equalizerResetButton = find.byKey(
      const ValueKey<String>('reset_equalizer'),
    );
    final saveEqualizerPresetButton = find.byKey(
      const ValueKey<String>('save_equalizer_preset'),
    );
    _expectThemeSessionResetButtonStyle(tester, equalizerResetButton);
    _expectThemeSessionResetButtonStyle(tester, saveEqualizerPresetButton);
    expect(tester.widget<FilledButton>(equalizerResetButton).onPressed, isNull);
    expect(
      tester.widget<FilledButton>(saveEqualizerPresetButton).onPressed,
      isNull,
    );

    unawaited(
      runtimeGraph.playback.applySessionEqPreset(
        session.id,
        builtInEqPresets[1],
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(equalizerResetButton).onPressed,
      isNotNull,
    );
    expect(
      tester.widget<FilledButton>(saveEqualizerPresetButton).onPressed,
      isNotNull,
    );

    await tester.tap(equalizerResetButton);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(equalizerResetButton).onPressed, isNull);
    expect(
      tester.widget<FilledButton>(saveEqualizerPresetButton).onPressed,
      isNull,
    );

    await tester.tap(find.text(languageProvider.tr('volume_balance')));
    await tester.pumpAndSettle();

    final restoreButton = find.byKey(
      const ValueKey<String>('restore_volume_balance'),
    );
    _expectThemeSessionResetButtonStyle(tester, restoreButton);
    expect(tester.widget<FilledButton>(restoreButton).onPressed, isNotNull);
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
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
      configureSettingsRepository: (settingsRepository) {
        settingsRepository.cardPositionsLocked = false;
        settingsRepository.syncSlice();
      },
    );
    addTearDown(fixture.disposeAfterWarmups);
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
    runtimeGraph.library.addTracks([track], notify: false, persist: false);
    playbackService.syncSlice(
      activeSessions: [session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );
    await tester.runAsync(() async {
      runtimeGraph.warmup.schedule(currentPageIndex: 2, immediate: true);
      await runtimeGraph.warmup.waitUntilIdle();
    });

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
    runtimeGraph.library.addTracks([workTrack, singleTrack], persist: false);
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
      await runtimeGraph.library.saveAudioDetail(
        AudioDetail.empty(
          workDetailTarget,
        ).copyWith(duration: const Duration(minutes: 3, seconds: 40)),
      );
      await runtimeGraph.library.saveAudioDetail(
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
      runtimeGraph.library.resolvedAudioDetail(workDetailTarget)?.duration,
      const Duration(minutes: 3, seconds: 40),
    );
    expect(
      runtimeGraph.library.resolvedAudioDetail(singleDetailTarget)?.duration,
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
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: coverCache,
      configureSettingsRepository: (settingsRepository) {
        settingsRepository.cardPositionsLocked = false;
      },
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
    runtimeGraph.library.addTracks([track], notify: false, persist: false);
    playbackService.syncSlice(
      activeSessions: [session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
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

    playbackService.syncSlice(
      activeSessions: const [],
      playingSessionCount: 0,
      focusedSessionId: null,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
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
      runtimeGraph.playback.activeSessions.where(
        (session) => session.isPlaybackQueue,
      ),
      hasLength(1),
    );
    expect(
      runtimeGraph.playback.activeSessions
          .singleWhere((session) => session.isPlaybackQueue)
          .playbackQueue
          ?.name,
      languageProvider.tr('default_playback_queue_name', {'number': 1}),
    );
    final queueSession = runtimeGraph.playback.activeSessions.singleWhere(
      (session) => session.isPlaybackQueue,
    );
    final queueCard = tester
        .widgetList<SwipeRevealCard>(find.byType(SwipeRevealCard))
        .singleWhere((card) => card.key == ValueKey(queueSession.id));
    expect((queueCard.shape as RoundedRectangleBorder).side, BorderSide.none);
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

  testWidgets('queue add buttons keep 48px touch targets without overflow', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final track = MusicTrack(
      path: '/library/work/track.mp3',
      displayName: 'Track',
      groupKey: '/library/work',
      groupTitle: 'Work',
      groupSubtitle: '/library/work',
      isSingle: false,
    );
    fixture.runtimeGraph.library.addTracks(
      <MusicTrack>[track],
      notify: false,
      persist: false,
    );
    final sourceSession = PlaybackSession(
      id: 'queue-source',
      currentTrackPath: track.path,
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(false, ProcessingState.ready),
    );
    final queueSession = fixture.runtimeGraph.playback.createPlaybackQueue(
      'Queue',
    );
    fixture.playbackService.registerSession(sourceSession);
    fixture.playbackService.syncSlice(
      activeSessions: <PlaybackSession>[sourceSession, queueSession],
      playingSessionCount: 0,
      focusedSessionId: sourceSession.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(
      fixture.build(PlaybackQueueAudioEditPage(sessionId: queueSession.id)),
    );
    await tester.pumpAndSettle();

    final addAudio = find.byTooltip(
      fixture.languageProvider.tr('add_audio_to_queue'),
    );
    final addWork = find.byTooltip(
      fixture.languageProvider.tr('add_work_to_queue'),
    );
    expect(tester.getSize(addAudio), const Size(48, 48));
    expect(tester.getSize(addWork), const Size(48, 48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('playlist resolves ASMR metadata from the session queue', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final track = MusicTrack(
      path: 'https://api.asmr-300.com/api/media/stream/f3d4baa6ec96a6ad',
      displayName: '本編トラック 01',
      groupKey: 'asmr-work-123456',
      groupTitle: 'ASMR 作品タイトル',
      groupSubtitle: 'RJ123456',
      isSingle: false,
      remoteMetadataKind: 'asmr.one',
    );
    final session = fixture.runtimeGraph.playback.createTrackSession(
      track,
      loopMode: SessionLoopMode.single,
      customQueueTracks: <MusicTrack>[track],
    );
    fixture.playbackService.syncSlice(
      activeSessions: <PlaybackSession>[session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(fixture.build(const PlaylistTab()));
    await tester.pump();

    expect(find.text(track.displayName), findsOneWidget);
    expect(find.text(track.groupTitle), findsOneWidget);
    expect(find.text('f3d4baa6ec96a6ad'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 120));
  });

  testWidgets('local library playlist shows the work card name', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    const libraryRoot = '/library/Library';
    const workRoot = '$libraryRoot/Work A';
    final track = MusicTrack(
      path: '$workRoot/Disc 1/01.mp3',
      displayName: '01',
      groupKey: workRoot,
      groupTitle: 'Work A',
      groupSubtitle: workRoot,
      isSingle: false,
    ).copyWith(manualCoverPath: '/covers/work.jpg');
    fixture.runtimeGraph.library.addWatchedLibrary(libraryRoot, notify: false);
    fixture.runtimeGraph.library.addTracks(
      <MusicTrack>[track],
      notify: false,
      persist: false,
    );
    final session = fixture.runtimeGraph.playback.createTrackSession(
      track,
      customQueueTracks: <MusicTrack>[track],
    );
    fixture.playbackService.syncSlice(
      activeSessions: <PlaybackSession>[session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(fixture.build(const PlaylistTab()));
    await tester.pumpAndSettle();

    expect(find.text('Work A'), findsOneWidget);
    expect(find.text('Library'), findsNothing);
    final swipeCard = tester.widget<SwipeRevealCard>(
      find.byType(SwipeRevealCard),
    );
    expect(swipeCard.color, isNull);
    expect((swipeCard.shape as RoundedRectangleBorder).side, BorderSide.none);
    expect(swipeCard.primaryActionIcon, Icons.delete_outline_rounded);
    expect(swipeCard.destructive, isTrue);
    final cardContent = tester.widget<Padding>(
      find.byKey(ValueKey<String>('playlist_card_content_${session.id}')),
    );
    expect(cardContent.padding, const EdgeInsets.all(8));
    final cardContentRow = cardContent.child! as Row;
    expect((cardContentRow.children[1] as SizedBox).width, 8);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 120));
  });

  testWidgets('playlist cards show loading spinners without loading text', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final track = MusicTrack(
      path: '/library/work/loading.mp3',
      displayName: 'Loading track',
      groupKey: '/library/work',
      groupTitle: 'Work',
      groupSubtitle: '/library/work',
      isSingle: false,
    );
    fixture.runtimeGraph.library.addTracks(
      <MusicTrack>[track],
      notify: false,
      persist: false,
    );
    final trackSession = fixture.runtimeGraph.playback.createTrackSession(track)
      ..isLoading = true;
    final queueSession =
        fixture.runtimeGraph.playback.createPlaybackQueue('Loading queue')
          ..currentTrackPath = track.path
          ..playbackQueue = PlaybackQueueDefinition(
            name: 'Loading queue',
            entries: <PlaybackQueueEntry>[
              PlaybackQueueEntry(
                id: 'loading-entry',
                kind: PlaybackQueueEntryKind.track,
                title: track.displayName,
                tracks: <MusicTrack>[track],
              ),
            ],
          )
          ..isLoading = true;
    fixture.playbackService.syncSlice(
      activeSessions: <PlaybackSession>[trackSession, queueSession],
      playingSessionCount: 0,
      focusedSessionId: trackSession.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(fixture.build(const PlaylistTab()));
    await tester.pump();

    expect(
      find.text(fixture.languageProvider.tr('playback_loading')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('loading')), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 120));
  });

  testWidgets(
    'single-file queue cover fills the card and switcher shows an audio entry',
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
      final track = MusicTrack(
        path: '/imports/standalone.mp4',
        displayName: 'Standalone clip',
        groupKey: '__single_files__',
        groupTitle: 'Imported files',
        groupSubtitle: 'Manually selected files',
        isSingle: true,
        isVideo: true,
      );
      runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      final queueSession = runtimeGraph.playback.createPlaybackQueue('Queue 1');
      queueSession
        ..currentTrackPath = track.path
        ..currentQueueIndex = 0
        ..playbackQueue = PlaybackQueueDefinition(
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

  testWidgets('compact playback subtitle centers wrapped text', (tester) async {
    const subtitleText = 'First line\nsecond centered line';
    final subtitleTrack = SubtitleTrack(
      sourcePath: '/library/subtitles/track.srt',
      cues: <SubtitleCue>[
        const SubtitleCue(
          start: Duration.zero,
          end: Duration(seconds: 5),
          text: subtitleText,
        ),
      ],
    );
    await _pumpSubtitleDetail(
      tester: tester,
      style: PlaybackDetailSubtitleStyle.compact,
      subtitleTrack: subtitleTrack,
      initialPosition: const Duration(seconds: 1),
    );
    await pumpUntilFound(tester, find.text(subtitleText));

    final text = tester.widget<Text>(find.text(subtitleText));
    expect(text.textAlign, TextAlign.center);
    expect(text.maxLines, 2);
  });

  testWidgets('detail loading subtitle fades while the cover resizes', (
    tester,
  ) async {
    final subtitleTrack = SubtitleTrack(
      sourcePath: '/library/subtitles/empty.srt',
      cues: <SubtitleCue>[],
    );
    final result = await _pumpSubtitleDetail(
      tester: tester,
      style: PlaybackDetailSubtitleStyle.compact,
      subtitleTrack: subtitleTrack,
      initialPosition: Duration.zero,
    );
    final loadingText = result.fixture.languageProvider.tr('playback_loading');
    final cover = find.byKey(
      const ValueKey('session_detail_cover_subtitle-session'),
    );
    final initialCoverHeight = tester.getSize(cover).height;

    result.session.isLoading = true;
    result.fixture.playbackService.markActiveSessionsDirty();
    result.fixture.playbackService.syncSlice(
      activeSessions: <PlaybackSession>[result.session],
      playingSessionCount: 0,
      focusedSessionId: result.session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );
    await pumpUntilFound(tester, find.text(loadingText));
    await tester.pump(const Duration(milliseconds: 110));

    final fadeIn = tester.widget<FadeTransition>(
      find.byKey(
        const ValueKey<Object>((
          'subtitle_fade',
          ValueKey<String>('subtitle_loading'),
        )),
      ),
    );
    expect(fadeIn.opacity.value, greaterThan(0));
    expect(fadeIn.opacity.value, lessThan(1));
    final midCoverHeight = tester.getSize(cover).height;

    await tester.pump(const Duration(milliseconds: 220));
    final loadingCoverHeight = tester.getSize(cover).height;
    expect(initialCoverHeight, greaterThan(midCoverHeight));
    expect(midCoverHeight, greaterThan(loadingCoverHeight));

    result.session.isLoading = false;
    result.fixture.playbackService.markActiveSessionsDirty();
    result.fixture.playbackService.syncSlice(
      activeSessions: <PlaybackSession>[result.session],
      playingSessionCount: 0,
      focusedSessionId: result.session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );
    await pumpUntilFound(tester, find.byKey(const ValueKey('subtitle_empty')));
    await tester.pump(const Duration(milliseconds: 110));

    expect(find.text(loadingText), findsOneWidget);
    final fadeOut = tester.widget<FadeTransition>(
      find.byKey(
        const ValueKey<Object>((
          'subtitle_fade',
          ValueKey<String>('subtitle_loading'),
        )),
      ),
    );
    expect(fadeOut.opacity.value, greaterThan(0));
    expect(fadeOut.opacity.value, lessThan(1));

    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text(loadingText), findsNothing);
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.getSize(cover).height, greaterThan(loadingCoverHeight));
  });

  testWidgets('timeline subtitles scroll, return, and seek while paused', (
    tester,
  ) async {
    final subtitleTrack = SubtitleTrack(
      sourcePath: '/library/subtitles/track.srt',
      cues: <SubtitleCue>[
        const SubtitleCue(
          start: Duration.zero,
          end: Duration(seconds: 2),
          text: 'Cue zero',
        ),
        const SubtitleCue(
          start: Duration(seconds: 2),
          end: Duration(seconds: 4),
          text: 'Cue one wraps onto a centered second line',
        ),
        const SubtitleCue(
          start: Duration(seconds: 4),
          end: Duration(seconds: 6),
          text: 'Cue two',
        ),
      ],
    );
    final result = await _pumpSubtitleDetail(
      tester: tester,
      style: PlaybackDetailSubtitleStyle.timeline,
      subtitleTrack: subtitleTrack,
      initialPosition: const Duration(milliseconds: 2500),
    );
    final viewport = find.byKey(
      const ValueKey<String>('subtitle_timeline_viewport'),
    );
    await pumpUntilFound(tester, viewport);
    await tester.pumpAndSettle();

    final cue0 = find.byKey(const ValueKey<String>('subtitle_timeline_cue_0'));
    final cue1 = find.byKey(const ValueKey<String>('subtitle_timeline_cue_1'));
    final cue2 = find.byKey(const ValueKey<String>('subtitle_timeline_cue_2'));
    Opacity opacityFor(Finder cue) => tester.widget<Opacity>(
      find.ancestor(of: cue, matching: find.byType(Opacity)).first,
    );

    expect(tester.getSize(viewport).height, 96);
    expect(opacityFor(cue0).opacity, 0.45);
    expect(opacityFor(cue1).opacity, 1);
    expect(opacityFor(cue2).opacity, 0.45);
    expect(
      tester.getCenter(cue1).dy,
      closeTo(tester.getCenter(viewport).dy, 0.1),
    );
    expect(
      find.byKey(const ValueKey<String>('subtitle_timeline_seek_button')),
      findsNothing,
    );
    expect(
      tester.widget<Text>(find.text(subtitleTrack.cues[1].text)).textAlign,
      TextAlign.center,
    );
    final focusedText = tester.widget<Text>(
      find.byKey(const ValueKey<String>('subtitle_timeline_text_1')),
    );
    final unfocusedText = tester.widget<Text>(
      find.byKey(const ValueKey<String>('subtitle_timeline_text_0')),
    );
    final textPadding = tester.widget<Padding>(
      find.byKey(const ValueKey<String>('subtitle_timeline_text_padding_1')),
    );
    expect(focusedText.style?.fontSize, 16);
    expect(unfocusedText.style?.fontSize, 14);
    expect(focusedText.maxLines, isNull);
    expect(focusedText.overflow, isNull);
    expect(
      textPadding.padding,
      const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
    );

    final list = find.byKey(const ValueKey<String>('subtitle_timeline_list'));
    await tester.drag(list, const Offset(0, -52));
    await tester.pumpAndSettle();
    expect(opacityFor(cue2).opacity, 1);
    expect(
      find.byKey(const ValueKey<String>('subtitle_timeline_seek_button')),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 2999));
    expect(opacityFor(cue2).opacity, 1);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(opacityFor(cue1).opacity, 1);

    await tester.drag(list, const Offset(0, -52));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('subtitle_timeline_seek_button')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('subtitle_timeline_seek_button')),
    );
    await tester.pump();

    expect(result.session.position, const Duration(seconds: 4));
    expect(result.session.state.playing, isFalse);
    expect(
      find.byKey(const ValueKey<String>('subtitle_timeline_seek_button')),
      findsNothing,
    );
    await tester.pump(PlaybackSession.loadingIndicatorThreshold);
  });

  testWidgets('timeline subtitles lazily expand a bounded cue window', (
    tester,
  ) async {
    const cueCount = 240;
    const playbackIndex = 120;
    final subtitleTrack = SubtitleTrack(
      sourcePath: '/library/subtitles/large-track.srt',
      cues: List<SubtitleCue>.generate(cueCount, (index) {
        final start = Duration(seconds: index * 2);
        return SubtitleCue(
          start: start,
          end: start + const Duration(seconds: 2),
          text: 'Cue $index',
        );
      }),
    );
    await _pumpSubtitleDetail(
      tester: tester,
      style: PlaybackDetailSubtitleStyle.timeline,
      subtitleTrack: subtitleTrack,
      initialPosition: const Duration(seconds: playbackIndex * 2),
    );
    final listFinder = find.byKey(
      const ValueKey<String>('subtitle_timeline_list'),
    );
    await pumpUntilFound(tester, listFinder);
    await tester.pumpAndSettle();

    final initialItemCount = tester
        .widget<ListView>(listFinder)
        .childrenDelegate
        .estimatedChildCount!;
    expect(initialItemCount, lessThan(cueCount));
    expect(
      find.byKey(
        const ValueKey<String>('subtitle_timeline_text_$playbackIndex'),
      ),
      findsOneWidget,
    );

    await tester.drag(listFinder, const Offset(0, -10000));
    await tester.pumpAndSettle();

    final expandedItemCount = tester
        .widget<ListView>(listFinder)
        .childrenDelegate
        .estimatedChildCount!;
    expect(expandedItemCount, greaterThan(initialItemCount));
    expect(expandedItemCount, lessThan(cueCount));

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('timeline subtitles expand beyond two lines without clipping', (
    tester,
  ) async {
    const subtitleText = 'Line one\nLine two\nLine three\nLine four\nLine five';
    final subtitleTrack = SubtitleTrack(
      sourcePath: '/library/subtitles/long-track.srt',
      cues: <SubtitleCue>[
        const SubtitleCue(
          start: Duration.zero,
          end: Duration(seconds: 5),
          text: subtitleText,
        ),
      ],
    );
    await _pumpSubtitleDetail(
      tester: tester,
      style: PlaybackDetailSubtitleStyle.timeline,
      subtitleTrack: subtitleTrack,
      initialPosition: const Duration(seconds: 1),
    );

    final viewport = find.byKey(
      const ValueKey<String>('subtitle_timeline_viewport'),
    );
    final cue = find.byKey(const ValueKey<String>('subtitle_timeline_cue_0'));
    final text = tester.widget<Text>(
      find.byKey(const ValueKey<String>('subtitle_timeline_text_0')),
    );

    expect(text.maxLines, isNull);
    expect(text.overflow, isNull);
    expect(tester.getSize(cue).height, greaterThan(96));
    expect(
      tester.getSize(viewport).height,
      greaterThanOrEqualTo(tester.getSize(cue).height),
    );
  });

  testWidgets('timeline subtitle focus changes provide rate-limited haptics', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    AppInteractionFeedback.resetContinuous();
    AppInteractionFeedback.hapticFeedbackEnabled = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() {
      AppInteractionFeedback.resetContinuous();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final subtitleTrack = SubtitleTrack(
      sourcePath: '/library/subtitles/track.srt',
      cues: <SubtitleCue>[
        const SubtitleCue(
          start: Duration.zero,
          end: Duration(seconds: 2),
          text: 'Cue zero',
        ),
        const SubtitleCue(
          start: Duration(seconds: 2),
          end: Duration(seconds: 4),
          text: 'Cue one',
        ),
        const SubtitleCue(
          start: Duration(seconds: 4),
          end: Duration(seconds: 6),
          text: 'Cue two',
        ),
      ],
    );
    await _pumpSubtitleDetail(
      tester: tester,
      style: PlaybackDetailSubtitleStyle.timeline,
      subtitleTrack: subtitleTrack,
      initialPosition: const Duration(seconds: 2),
    );

    final list = find.byKey(const ValueKey<String>('subtitle_timeline_list'));
    await tester.drag(list, const Offset(0, -52));
    await tester.pumpAndSettle();

    expect(
      calls.where((call) => call.method == 'HapticFeedback.vibrate'),
      hasLength(1),
    );
  });
}
