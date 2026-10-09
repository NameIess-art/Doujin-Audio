import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import '../test/support/asmr_controller_test_fixture.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:doujin_audio/app/presentation/main_screen.dart';
import 'package:doujin_audio/app/presentation/main_destination.dart';
import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_tab.dart';
import 'package:doujin_audio/features/data_support/application/data_backup_service.dart';
import 'package:doujin_audio/features/library/presentation/library_tab.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:doujin_audio/features/settings/presentation/about_page.dart';
import 'package:doujin_audio/features/settings/application/app_update_service.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/application/windows_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:doujin_audio/features/player/presentation/playlist_view_models.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;
import 'package:media_kit/media_kit.dart' show MediaKit;
import 'package:doujin_audio/main.dart' as app;
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/features/library/presentation/library_providers.dart';
import 'package:doujin_audio/features/player/presentation/playback_providers.dart';
import 'package:doujin_audio/features/settings/presentation/settings_providers.dart';
import 'package:doujin_audio/features/settings/presentation/settings_tab.dart';

import '../test/support/app_runtime_test_fixture.dart';
import '../test/support/test_persistence_repository.dart';
import 'support/app_startup_test_helper.dart';

double get _displayRefreshRate =>
    WidgetsBinding.instance.platformDispatcher.views.first.display.refreshRate;
double get _refreshRate =>
    _displayRefreshRate.isFinite && _displayRefreshRate > 0
    ? _displayRefreshRate
    : 60;
Duration get _frameBudget =>
    Duration(microseconds: (1000000 / _refreshRate).ceil());
const _scenario = String.fromEnvironment('PERF_SCENARIO', defaultValue: 'core');
const _transitionCondition = String.fromEnvironment(
  'PERF_TRANSITION_CONDITION',
  defaultValue: 'baseline',
);
const _idleSeconds = int.fromEnvironment('PERF_IDLE_SECONDS', defaultValue: 60);
const _openings = int.fromEnvironment('PERF_OPENINGS', defaultValue: 3);
const _libraryItemOverride = int.fromEnvironment('PERF_LIBRARY_ITEMS');
const _asmrItemOverride = int.fromEnvironment('PERF_ASMR_ITEMS');
const _asmrTrackOverride = int.fromEnvironment('PERF_ASMR_TRACKS');
const _backupByteOverride = int.fromEnvironment('PERF_BACKUP_BYTES');
const _semanticsEnabled = bool.fromEnvironment(
  'PERF_SEMANTICS',
  defaultValue: _scenario != 'playback',
);
const _coverManifest = String.fromEnvironment('PERF_COVER_MANIFEST');
const _traceReadyFile = String.fromEnvironment('PERF_TRACE_READY_FILE');
List<({String url, String path})> _profileCovers = const [];

int get _libraryItemCount => _libraryItemOverride > 0
    ? _libraryItemOverride
    : _scenario == 'library-large' || _scenario == 'detail-compare'
    ? 20000
    : 100;

int get _asmrItemCount => _asmrItemOverride > 0
    ? _asmrItemOverride
    : _scenario == 'asmr-large'
    ? 2000
    : 100;

int get _asmrTrackCount => _asmrTrackOverride > 0
    ? _asmrTrackOverride
    : _scenario == 'asmr-large'
    ? 2000
    : 0;

int get _backupByteCount => _backupByteOverride > 0
    ? _backupByteOverride
    : _scenario == 'backup'
    ? 128 * 1024 * 1024
    : 0;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Measure engine-driven animation frames instead of the explicit pump cadence.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;

  testWidgets('profile main interaction path', (tester) async {
    expect(
      const <String>{
        'core',
        'library-large',
        'asmr-large',
        'backup',
        'detail-compare',
        'playback',
        'page-transitions',
        'page-transitions-playing',
        'page-transitions-startup',
      },
      contains(_scenario),
      reason: 'Unsupported PERF_SCENARIO=$_scenario',
    );
    expect(
      const {'baseline', 'idle', 'resume', 'os-resume', 'memory-pressure'},
      contains(_transitionCondition),
      reason: 'Unsupported PERF_TRANSITION_CONDITION=$_transitionCondition',
    );
    expect(_idleSeconds, greaterThanOrEqualTo(0));
    expect(_openings, greaterThan(0));
    if (_scenario == 'page-transitions-startup') {
      expect(_transitionCondition, 'baseline');
      expect(
        _openings,
        1,
        reason: 'Each startup sample needs a fresh process.',
      );
      await _waitForHostTimeline(tester);
      await _measureProductionStartup(tester, binding);
      return;
    }
    SharedPreferences.setMockInitialValues(const <String, Object>{
      AppPreferences.onboardingCompletedKey: true,
    });
    if (_coverManifest.isNotEmpty) {
      final entries =
          jsonDecode(await File(_coverManifest).readAsString()) as List;
      _profileCovers = entries
          .map(
            (entry) =>
                (url: entry['url'] as String, path: entry['path'] as String),
          )
          .toList(growable: false);
      expect(_profileCovers, isNotEmpty);
      for (final cover in _profileCovers) {
        expect(await File(cover.path).exists(), true);
      }
    }
    if (_scenario == 'playback' || _scenario == 'page-transitions-playing') {
      await _measureRealPlayback(tester, binding);
      return;
    }
    debugPrint('PERF_STAGE fixture_start scenario=$_scenario');
    sqfliteFfiInit();
    final fixtureDatabase = await AppRuntimeTestFixture.installSharedDatabase();
    addTearDown(
      () => AppRuntimeTestFixture.disposeSharedDatabase(fixtureDatabase),
    );
    final fixture = AppRuntimeWidgetTestFixture();
    if (_profileCovers.isNotEmpty) {
      await fixture.library.coverArtworkCacheService.initialize();
    }
    final sessions = _seedRuntime(fixture, trackCount: _libraryItemCount);
    debugPrint('PERF_STAGE seed_ready libraryItems=$_libraryItemCount');
    final asmrController = _ProfileAsmrController(
      services: createTestAsmrServices(
        persistenceRepository: fixture.persistenceRepository,
      ),
      works: _buildAsmrWorks(_asmrItemCount),
      trackTree: _buildAsmrTrackTree(_asmrTrackCount),
    );
    final backupFixture = _scenario == 'backup'
        ? await _BackupProfileFixture.create(_backupByteCount)
        : null;
    addTearDown(() async {
      for (final session in sessions) {
        await session.shutdown();
      }
      asmrController.dispose();
      await backupFixture?.dispose();
      fixture.dispose();
      UiInteractionNavigatorObserver.instance.resetForTest();
    });

    await fixture.library.loadLibraryTree();
    debugPrint('PERF_STAGE tree_ready');
    await tester.pumpWidget(
      fixture.build(
        const ExcludeSemantics(
          excluding: !_semanticsEnabled,
          child: MainScreen(),
        ),
        navigatorObservers: <NavigatorObserver>[
          UiInteractionNavigatorObserver.instance,
          _PerformanceRouteObserver(),
        ],
        overrides: <Override>[
          asmrLibraryControllerProvider.overrideWithValue(asmrController),
          mainOverlayUiProvider.overrideWithValue(
            const MainOverlayUiState(
              overlaySessions: <PlaybackSessionSnapshot>[],
              playingSessionCount: 0,
              hasPlayingAudioSession: false,
              activeSessionCount: 0,
              isInitialized: true,
              startupReady: true,
            ),
          ),
        ],
      ),
    );
    debugPrint('PERF_STAGE first_frame_ready');
    await tester.pumpAndSettle();
    debugPrint('PERF_STAGE fixture_ready');

    if (_scenario == 'page-transitions') {
      final samples = await _measurePageTransitions(tester);
      final report = _pageTransitionReport(samples, playing: false);
      binding.reportData = {'uiPerformance': report};
      debugPrint('UI_PERFORMANCE ${jsonEncode(report)}');
      _expectFrameBudgets(samples.rounds);
      return;
    }

    if (_scenario == 'detail-compare') {
      final rounds = await _measureDetailComparison(tester);
      final report = <String, Object>{
        'fixture': <String, int>{
          'libraryItems': _libraryItemCount + 2,
          'asmrItems': _asmrItemCount,
          'asmrTracks': _asmrTrackCount,
          'backupBytes': _backupByteCount,
          'playbackSessions': sessions.length,
        },
        'scenario': _scenario,
        'mode': kProfileMode ? 'profile' : (kReleaseMode ? 'release' : 'debug'),
        'frameTimingDeliveryWaitMs': 2000,
        'frameSampleWindow':
            'Frame build start inside action wall-clock interval',
        'frameBudgetUs': _frameBudget.inMicroseconds,
        'rounds': rounds,
      };
      binding.reportData = <String, dynamic>{'uiPerformance': report};
      debugPrint('UI_PERFORMANCE ${jsonEncode(report)}');
      _expectFrameBudgets(rounds);
      return;
    }

    // The first pass warms shaders, text and lazily-created list/card widgets.
    await _runScenario(tester, sessions, _scenario, backupFixture);

    final rounds = <Map<String, Object>>[];
    for (var round = 1; round <= 3; round++) {
      final timings = <FrameTiming>[];
      void collect(List<FrameTiming> values) => timings.addAll(values);
      WidgetsBinding.instance.addTimingsCallback(collect);
      final started = DateTime.now().microsecondsSinceEpoch;
      late int finished;
      try {
        await _runScenario(tester, sessions, _scenario, backupFixture);
        finished = DateTime.now().microsecondsSinceEpoch;
        await Future<void>.delayed(const Duration(seconds: 2));
      } finally {
        WidgetsBinding.instance.removeTimingsCallback(collect);
      }
      timings.retainWhere(
        (timing) => _frameStartedWithin(timing, started, finished),
      );
      rounds.add(_summarizeRound(round, timings));
    }

    final report = <String, Object>{
      'fixture': <String, int>{
        'libraryItems': _libraryItemCount,
        'asmrItems': _asmrItemCount,
        'asmrTracks': _asmrTrackCount,
        'backupBytes': _backupByteCount,
        'playbackSessions': 12,
      },
      'scenario': _scenario,
      'mode': kProfileMode ? 'profile' : (kReleaseMode ? 'release' : 'debug'),
      'frameTimingDeliveryWaitMs': 2000,
      'frameSampleWindow':
          'Frame build start inside action wall-clock interval',
      'frameBudgetUs': _frameBudget.inMicroseconds,
      'rounds': rounds,
    };
    binding.reportData = <String, dynamic>{'uiPerformance': report};
    debugPrint('UI_PERFORMANCE ${jsonEncode(report)}');
    _expectFrameBudgets(rounds);
    // The default retains the baseline's semantics; the override isolates its cost.
    // ignore: avoid_redundant_argument_values
  }, semanticsEnabled: _semanticsEnabled);
}

Future<void> _measureProductionStartup(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  expect(
    Platform.isAndroid,
    true,
    reason: 'This run uses the independent Android Profile package.',
  );
  final preparation = Stopwatch()..start();
  await startAppForTest(tester, app.main);
  await enterMainScreen(tester);
  final stackFinder = find.byKey(const ValueKey<String>('main_page_stack'));
  // enterMainScreen observes the actual production runtime gate. Do not settle
  // the page or browse any target before sampling its first navigation.
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while ((stackFinder.evaluate().isEmpty ||
          !UiInteractionCoordinator.instance.navigationAllowed.value) &&
      DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(stackFinder, findsOneWidget);
  expect(UiInteractionCoordinator.instance.navigationAllowed.value, true);
  preparation.stop();

  final container = ProviderScope.containerOf(
    tester.element(find.byType(MainScreen)),
    listen: false,
  );
  final runtime = container.read(audioRuntimeCoordinatorProvider);
  addTearDown(() async {
    // Normal production shutdown; never clear sessions, DB, preferences or
    // cover caches. Call before removing the production ProviderScope.
    await runtime.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  final library = container.read(libraryFacadeProvider);
  final playback = container.read(playbackFacadeProvider);
  final settings = container.read(settingsRepositoryProvider);
  final destinations = resolveMainDestinations(
    showLocalLibrary: settings.showLocalLibrary,
    showAsmrOne: settings.showAsmrOne,
  );
  final stack = tester.widget<AppFadeThroughIndexedStack>(stackFinder);
  final initialDestination = destinations[stack.index].type;
  // A previous test may have persisted Settings as the last browse page.
  // Honor that real state; never reset it just to match synthetic fixtures.
  final firstDestination = initialDestination == MainDestinationType.settings
      ? MainDestinationType.playlist
      : MainDestinationType.settings;
  VoidCallback selectDestination(MainDestinationType destination) {
    final index = destinations.indexWhere((item) => item.type == destination);
    expect(index, greaterThanOrEqualTo(0));
    final rail = find.byType(NavigationRail);
    if (rail.evaluate().isNotEmpty) {
      final onSelected = tester
          .widget<NavigationRail>(rail)
          .onDestinationSelected!;
      return () => onSelected(index);
    }
    final key = destinations[index].labelKey;
    return tester
        .widget<InkResponse>(
          find.byKey(ValueKey<String>('main_destination_ink_$key')),
        )
        .onTap!;
  }

  final preparationUs = preparation.elapsedMicroseconds;
  final firstAction = selectDestination(firstDestination);
  final slideVisible = _observeTransitionSlide(tester, 'main_page_stack');
  final rounds = <Map<String, Object>>[];
  rounds.add(
    await _measureTransitionAction(
      tester,
      'startup-main-${firstDestination.name}',
      1,
      firstAction,
      slideVisible,
    ),
  );
  if (firstDestination != MainDestinationType.settings) {
    selectDestination(MainDestinationType.settings)();
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  final i18n = container.read(appLanguageProviderInstanceProvider);
  final aboutTitle = find.descendant(
    of: find.byType(SettingsTab),
    matching: find.text(i18n.tr('about')),
  );
  expect(aboutTitle, findsOneWidget);
  final aboutTile = find.ancestor(
    of: aboutTitle,
    matching: find.byType(ListTile),
  );
  final openAbout = tester.widget<ListTile>(aboutTile).onTap;
  expect(openAbout, isNotNull);
  TransitionRoute<dynamic>? aboutRoute;
  rounds.add(
    await _measureTransitionAction(
      tester,
      'startup-ordinary-about',
      1,
      openAbout!,
      () => _routeTransitionVisible(aboutRoute),
      afterFirstPump: () {
        final about = find.byType(AboutPage, skipOffstage: false);
        expect(about, findsOneWidget);
        aboutRoute =
            ModalRoute.of(tester.element(about)) as TransitionRoute<dynamic>;
        // AppPreparedPageRoute records its first full page with progress 0.
        // Capture that route exactly once before the first visible frame.
        expect(
          aboutRoute!.animation!.value,
          0,
          reason:
              'The visibility probe must not omit the first animation frame.',
        );
      },
    ),
  );
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  navigator.pop();
  for (var frame = 0; frame < 40; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  // Preserve the production package's saved browse destination for the paired run.
  selectDestination(initialDestination)();
  for (var frame = 0; frame < 40; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  final report = <String, Object>{
    'scenario': _scenario,
    'platform': 'android',
    'runtime': 'production bootstrap + persisted SQLite + Media3',
    'mode': kProfileMode ? 'profile' : (kReleaseMode ? 'release' : 'debug'),
    'playing': playback.hasPlayingSession,
    'framePolicy': binding.framePolicy.name,
    'transitionCondition': 'baseline',
    'openings': 1,
    'idleSeconds': _idleSeconds,
    'refreshRateHz': _refreshRate,
    'conditions': <Map<String, Object>>[
      {'opening': 1, 'condition': 'baseline', 'conditionElapsedMs': 0},
    ],
    'startupPreparationUs': preparationUs,
    'initialDestination': initialDestination.name,
    'firstDestination': firstDestination.name,
    'libraryItems': library.library.length,
    'watchedFolders': library.watchedFolders.length,
    'watchedLibraries': library.watchedLibraries.length,
    'playbackSessions': playback.activeSessions.length,
    'playingSessions': playback.activeSessions
        .where((s) => s.state.playing)
        .length,
    'dataset':
        'Independent .perf package existing persisted data; no fixture seeding',
    'onboarding':
        'Existing startup helper accepts onboarding if shown; elapsed preparation includes it',
    'frameBudgetUs': _frameBudget.inMicroseconds,
    'frameTimingDeliveryWaitMs': 2000,
    'firstVisibleFrameMeasurement':
        'Existing frameNumber-matched UI commit probe; not display presentation',
    'input':
        'Production NavigationRail/InkResponse/ListTile callback; no injected route or fake version',
    'timelineTracing': const String.fromEnvironment(
      'PERF_TRACE_READY_FILE',
    ).isNotEmpty,
    'samplingLimits':
        'Starts before app.main but after integration harness initialization. '
        'Preparation includes production bootstrap, helper polling (up to 100 ms), '
        'and possible onboarding. It is not OS process-to-first-display latency. '
        'Host trace handshake occurs before app.main; enabled tracing adds profiling overhead. '
        'Immediate first navigation does not prove overlap with delayed startup maintenance. '
        'Empty persisted data is an empty-data startup sample, not the synthetic 100-item workload.',
    'rounds': rounds,
  };
  binding.reportData = {'uiPerformance': report};
  debugPrint('UI_PERFORMANCE ${jsonEncode(report)}');
  _expectFrameBudgets(rounds);
}

Future<void> _measureRealPlayback(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  expect(
    Platform.isWindows || Platform.isAndroid,
    true,
    reason: 'Playback profiling requires the Android or Windows runtime.',
  );
  if (Platform.isWindows) {
    MediaKit.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  final directory = await Directory.systemTemp.createTemp(
    'doujin_playback_profile_',
  );
  final database = await openDatabase(
    '${directory.path}${Platform.pathSeparator}playback.sqlite',
  );
  await AppDatabase.createSchemaForTest(database);
  final appDatabase = AppDatabase.test(database);
  AppDatabase.setInstanceForTest(appDatabase);
  final native = NativePlaybackRepository();
  final fixture = AppRuntimeWidgetTestFixture(
    providedNativePlaybackRepository: native,
    providedPersistenceRepository: TestPersistenceRepository(
      database: appDatabase,
    ),
    persistenceEnabled: true,
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await WidgetsBinding.instance.endOfFrame;
    await fixture.runtimeGraph.runtime.dispose();
    fixture.dispose();
    AppDatabase.setInstanceForTest(null);
    await database.close();
    await directory.delete(recursive: true);
    UiInteractionNavigatorObserver.instance.resetForTest();
  });
  await fixture.runtimeGraph.runtime.start().timeout(
    const Duration(seconds: 30),
  );
  final tracks = <MusicTrack>[];
  for (var i = 0; i < 100; i++) {
    final file = File('${directory.path}${Platform.pathSeparator}音声 $i.wav');
    await _writeSilentWave(file, seconds: i == 0 ? 120 : 4);
    tracks.add(
      MusicTrack(
        path: file.path,
        displayName: 'Runtime track $i',
        groupKey: directory.path,
        groupTitle: 'Local playback profile',
        groupSubtitle: '',
        isSingle: true,
        coverCachePath: _profileCovers.isEmpty
            ? null
            : _profileCovers[i % _profileCovers.length].path,
        duration: Duration(seconds: i == 0 ? 120 : 4),
      ),
    );
  }
  fixture.library.addTracks(tracks, persist: false);
  await fixture.library.loadLibraryTree();
  final asmrController = _ProfileAsmrController(
    services: createTestAsmrServices(
      persistenceRepository: fixture.persistenceRepository,
    ),
    works: _buildAsmrWorks(100),
    trackTree: const [],
  );
  addTearDown(asmrController.dispose);
  // Keep the real overlay provider, native event streams and runtime bindings.
  await tester.pumpWidget(
    fixture.build(
      const ExcludeSemantics(
        excluding: !_semanticsEnabled,
        child: MainScreen(),
      ),
      navigatorObservers: [
        UiInteractionNavigatorObserver.instance,
        _PerformanceRouteObserver(),
      ],
      overrides: [
        asmrLibraryControllerProvider.overrideWithValue(asmrController),
      ],
    ),
  );
  await _switchMainPage(tester, MainDestinationType.library);
  if (_scenario == 'page-transitions-playing') {
    expect(
      await fixture.playback.spawnSessionWithQueue(
        [tracks.first],
        autoPlay: false,
        loopMode: SessionLoopMode.single,
      ),
      true,
    );
    final id = fixture.playback.sessions.keys.single;
    await _toggleRuntimeSession(tester, fixture, id, playing: true);
    var backgroundPermissionPromptDismissed = false;
    if (Platform.isAndroid) {
      final mainContext = tester.element(find.byType(MainScreen));
      final i18n = ProviderScope.containerOf(
        mainContext,
        listen: false,
      ).read(appLanguageProviderInstanceProvider);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      // The real overlay asks about battery exemption after playback starts.
      // Close its production "later" action before measuring unobscured pages.
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 16));
        if (find
            .text(i18n.tr('background_play_permission_title'))
            .hitTestable()
            .evaluate()
            .isNotEmpty) {
          await tester.tap(find.text(i18n.tr('later')).hitTestable());
          backgroundPermissionPromptDismissed = true;
          for (var frame = 0; frame < 40; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
      }
      expect(ModalRoute.of(mainContext)!.isCurrent, true);
    }
    final samples = await _measurePageTransitions(
      tester,
      localPath: tracks.first.path,
      sessionId: id,
    );
    expect(fixture.playback.sessionById(id)!.state.playing, true);
    final report = _pageTransitionReport(samples, playing: true);
    report['backgroundPermissionPromptDismissed'] =
        backgroundPermissionPromptDismissed;
    binding.reportData = {'uiPerformance': report};
    debugPrint('UI_PERFORMANCE ${jsonEncode(report)}');
    _expectFrameBudgets(samples.rounds);
    return;
  }
  final rounds = <Map<String, Object>>[];
  Map<String, Object>? idleObservation;
  final report = <String, Object>{
    'scenario': 'playback',
    'mode': kProfileMode ? 'profile' : (kReleaseMode ? 'release' : 'debug'),
    'runtime': Platform.isWindows ? 'libmpv' : 'Media3',
    'media': 'real local PCM WAV',
    'overlayEnabled': true,
    'framePolicy': binding.framePolicy.name,
    'navigationWarmupPasses': 2,
    'frameTimingDeliveryWaitMs': 2000,
    'frameSampleWindow': 'Frame build start inside action wall-clock interval',
    'nativeEventCountsWindow': 'Navigation plus FrameTiming delivery wait',
    'testForcesSemantics': false,
    'systemAccessibility':
        'unchanged; platform accessibility requests remain active',
    'persistence': 'isolated file SQLite with production incremental writes',
    'baseline': 'Current version, idle-0, same device and same run',
    'preChangeBaselineAvailable': false,
    'frameWorkload': 'Common main page navigation and scrolling',
    'sessionInteractionWorkload': 'Card play/pause and opening/closing detail',
    'sessionControlPointer': Platform.isWindows ? 'mouse' : 'touch',
    'limitations': [
      'Remote media, network buffering and hardware video decode are not measured',
      'Process CPU usage and native memory are not measured by frame timings',
      'Baseline deltas compare navigation only; session interaction frames have separate budget checks',
    ],
    'measurementStatus': 'incomplete',
    'libraryItems': tracks.length,
    'frameBudgetUs': _frameBudget.inMicroseconds,
    'rounds': rounds,
  };
  binding.reportData = {'uiPerformance': report};
  for (final (stage, sessionCount, playingCount, queueSize)
      in <(String, int, int, int)>[
        ('idle-0', 0, 0, 1),
        ('idle-1', 1, 0, 1),
        ('idle-5', 5, 0, 1),
        ('idle-50', 50, 0, 1),
        ('playing-2', 5, 2, 1),
        ('queue-1000', 5, 2, 1000),
      ]) {
    debugPrint(
      'PLAYBACK_STAGE_BEGIN stage=$stage sessions=$sessionCount queueItems=$queueSize',
    );
    expect(await fixture.playback.clearAllSessions(), true);
    for (var i = 0; i < sessionCount; i++) {
      final queue = i == 0 && queueSize > 1
          ? List.generate(queueSize, (index) => tracks[index % tracks.length])
          : [tracks[i % tracks.length]];
      expect(
        await fixture.playback.spawnSessionWithQueue(
          queue,
          autoPlay: false,
          loopMode: SessionLoopMode.single,
        ),
        true,
      );
    }
    final ids = fixture.playback.sessions.keys.toList();
    // Profile paused sessions that have really decoded media at least once.
    for (final id in ids) {
      await _toggleRuntimeSession(tester, fixture, id, playing: true);
      await _toggleRuntimeSession(tester, fixture, id, playing: false);
    }
    for (final id in ids.take(playingCount)) {
      await _toggleRuntimeSession(tester, fixture, id, playing: true);
    }
    for (var warmup = 0; warmup < 2; warmup++) {
      await _runRealPlaybackInteractions(tester, fixture);
    }
    if (stage == 'idle-50') {
      debugPrint('PLAYBACK_IDLE_OBSERVATION_BEGIN sessions=${ids.length}');
      await tester.pump(const Duration(milliseconds: 500));
      var structuralEvents = 0, progressEvents = 0;
      final structureSub = native.snapshots.listen((_) => structuralEvents++);
      final progressSub = native.progressUpdates.listen(
        (_) => progressEvents++,
      );
      final observation = Stopwatch()..start();
      try {
        while (observation.elapsed < const Duration(seconds: 60)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(seconds: 1)),
          );
          await tester.pump();
        }
      } finally {
        await structureSub.cancel();
        await progressSub.cancel();
      }
      idleObservation = {
        'sessionCount': ids.length,
        'observationMs': observation.elapsedMilliseconds,
        'structuralEvents': structuralEvents,
        'progressEvents': progressEvents,
        if (Platform.isWindows)
          'retainedPlayers': ids
              .where(
                (id) =>
                    WindowsPlaybackBridge.instance.playerForSession(id) != null,
              )
              .length,
      };
      report['idleObservation'] = idleObservation;
      debugPrint('PLAYBACK_IDLE_PERFORMANCE ${jsonEncode(idleObservation)}');
    }
    for (var round = 1; round <= 3; round++) {
      final timings = <FrameTiming>[];
      final navigationStarted = DateTime.now().microsecondsSinceEpoch;
      late int navigationFinished;
      var structuralEvents = 0, progressEvents = 0;
      final structureSub = native.snapshots.listen((_) => structuralEvents++);
      final progressSub = native.progressUpdates.listen(
        (_) => progressEvents++,
      );
      void collect(List<FrameTiming> values) => timings.addAll(values);
      WidgetsBinding.instance.addTimingsCallback(collect);
      try {
        await _runRealPlaybackNavigation(tester);
        navigationFinished = DateTime.now().microsecondsSinceEpoch;
        // The engine can deliver FrameTiming in one-second batches. Wait for
        // delivery, then exclude frames outside this action's clock interval.
        await Future<void>.delayed(const Duration(seconds: 2));
      } finally {
        WidgetsBinding.instance.removeTimingsCallback(collect);
        await structureSub.cancel();
        await progressSub.cancel();
      }
      timings.retainWhere(
        (timing) =>
            _frameStartedWithin(timing, navigationStarted, navigationFinished),
      );
      final sessionTimings = <FrameTiming>[];
      final sessionInteractionsStarted = DateTime.now().microsecondsSinceEpoch;
      late int sessionInteractionsFinished;
      void collectSession(List<FrameTiming> values) =>
          sessionTimings.addAll(values);
      late Map<String, Object> interactions;
      if (ids.isNotEmpty) {
        WidgetsBinding.instance.addTimingsCallback(collectSession);
      }
      try {
        interactions = await _runRealPlaybackSessionInteractions(
          tester,
          fixture,
        );
        sessionInteractionsFinished = DateTime.now().microsecondsSinceEpoch;
        if (ids.isNotEmpty) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      } finally {
        if (ids.isNotEmpty) {
          WidgetsBinding.instance.removeTimingsCallback(collectSession);
        }
      }
      sessionTimings.retainWhere(
        (timing) => _frameStartedWithin(
          timing,
          sessionInteractionsStarted,
          sessionInteractionsFinished,
        ),
      );
      final result = <String, Object>{
        ..._summarizeRound(round, timings),
        ...interactions,
        'stage': stage,
        'sessionCount': sessionCount,
        'playingCount': playingCount,
        'queueItems': queueSize,
        'structuralEvents': structuralEvents,
        'progressEvents': progressEvents,
        if (ids.isNotEmpty)
          'sessionInteractionFrames': _summarizeRound(round, sessionTimings),
        if (Platform.isWindows)
          'retainedPlayers': ids
              .where(
                (id) =>
                    WindowsPlaybackBridge.instance.playerForSession(id) != null,
              )
              .length,
      };
      rounds.add(result);
      debugPrint('PLAYBACK_PERFORMANCE ${jsonEncode(result)}');
    }
  }
  report['measurementStatus'] = 'complete';
  final gates = _assessPlaybackPerformance(rounds, idleObservation!);
  report['gates'] = gates;
  debugPrint('UI_PERFORMANCE ${jsonEncode(report)}');
  if (kProfileMode) {
    expect(gates['allTargetsPassed'], true, reason: jsonEncode(gates));
  }
}

Future<void> _writeSilentWave(File file, {required int seconds}) async {
  const rate = 8000;
  final bytes = ByteData(44 + rate * seconds * 2);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  text(8, 'WAVEfmt ');
  text(36, 'data');
  bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, rate, Endian.little);
  bytes.setUint32(28, rate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  bytes.setUint32(40, bytes.lengthInBytes - 44, Endian.little);
  await file.writeAsBytes(bytes.buffer.asUint8List());
}

Future<void> _toggleRuntimeSession(
  WidgetTester tester,
  AppRuntimeWidgetTestFixture fixture,
  String id, {
  required bool playing,
}) async {
  await _pumpUntilComplete(
    tester,
    fixture.playback
        .toggleSessionPlayPause(id)
        .timeout(const Duration(seconds: 15)),
  );
  await _waitForRuntimeSession(tester, fixture, id, playing: playing);
}

Future<void> _waitForRuntimeSession(
  WidgetTester tester,
  AppRuntimeWidgetTestFixture fixture,
  String id, {
  required bool playing,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  NativePlaybackSnapshot? nativeSnapshot;
  final sub = fixture.nativePlaybackRepository.snapshots.listen((snapshot) {
    if (snapshot.sessionId == id) nativeSnapshot = snapshot;
  });
  try {
    final result = await fixture.nativePlaybackRepository.snapshot();
    expect(result.isOk, true, reason: result.errorOrNull);
    nativeSnapshot ??= result.valueOrNull?.sessions
        .where((snapshot) => snapshot.sessionId == id)
        .firstOrNull;
    while (DateTime.now().isBefore(deadline)) {
      final session = fixture.playback.sessionById(id)!;
      if (nativeSnapshot?.playing == playing &&
          nativeSnapshot?.transportCommandId == session.transportCommandId &&
          session.state.playing == playing &&
          !session.isLoading &&
          (!playing || session.position > Duration.zero)) {
        return;
      }
      if (session.playbackError != null || nativeSnapshot?.error != null) {
        fail(
          'Native playback failed: ${session.playbackError ?? nativeSnapshot?.error}',
        );
      }
      await tester.pump(const Duration(milliseconds: 16));
    }
    fail(
      'Native session $id did not become playing=$playing: '
      'native=${nativeSnapshot?.playing}, intent=${nativeSnapshot?.playWhenReady}.',
    );
  } finally {
    await sub.cancel();
  }
}

Future<Map<String, Object>> _runRealPlaybackInteractions(
  WidgetTester tester,
  AppRuntimeWidgetTestFixture fixture,
) async {
  await _runRealPlaybackNavigation(tester);
  return _runRealPlaybackSessionInteractions(tester, fixture);
}

Future<void> _runRealPlaybackNavigation(WidgetTester tester) async {
  await _switchMainPage(tester, MainDestinationType.library);
  await _flingPageList<LibraryTab>(tester);
  await _switchMainPage(tester, MainDestinationType.playlist);
  await _flingPageList<PlaylistTab>(tester);
  await _switchMainPage(tester, MainDestinationType.settings);
  await _switchMainPage(tester, MainDestinationType.asmrOne);
  await _flingPageList<AsmrTab>(tester);
  await _switchMainPage(tester, MainDestinationType.library);
}

Future<Map<String, Object>> _runRealPlaybackSessionInteractions(
  WidgetTester tester,
  AppRuntimeWidgetTestFixture fixture,
) async {
  final latency = <String, Object>{};
  if (fixture.playback.sessions.isEmpty) return latency;
  await _switchMainPage(tester, MainDestinationType.playlist);
  final cards = find.byType(SessionListCard);
  expect(cards, findsWidgets);
  final visibleControls = find
      .ancestor(
        of: find.descendant(
          of: cards,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Icon &&
                (widget.icon == Icons.play_arrow_rounded ||
                    widget.icon == Icons.pause_rounded),
          ),
        ),
        matching: find.byType(IconButton),
      )
      .hitTestable();
  for (
    var frame = 0;
    frame < 60 && visibleControls.evaluate().isEmpty;
    frame++
  ) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(
    visibleControls,
    findsWidgets,
    reason: 'A visible session play/pause button must receive pointer events.',
  );
  final card = find.ancestor(of: visibleControls.first, matching: cards);
  final id = tester.widget<SessionListCard>(card).sessionId;
  final wasPlaying = fixture.playback.sessionById(id)!.state.playing;
  if (wasPlaying) {
    await _toggleRuntimeSession(tester, fixture, id, playing: false);
  }
  await WidgetsBinding.instance.endOfFrame;
  final play = find.descendant(
    of: find.byWidgetPredicate(
      (widget) => widget is SessionListCard && widget.sessionId == id,
    ),
    matching: find.byIcon(Icons.play_arrow_rounded),
  );
  expect(play, findsOneWidget);
  final button = find.ancestor(of: play, matching: find.byType(IconButton));
  for (
    var frame = 0;
    frame < 60 && button.hitTestable().evaluate().isEmpty;
    frame++
  ) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(
    button.hitTestable(),
    findsOneWidget,
    reason: 'The real play button must receive pointer events before timing.',
  );
  final buttonElement = button.evaluate().single;
  final previousCommandId = fixture.playback
      .sessionById(id)!
      .transportCommandId;
  final started = Stopwatch()..start();
  int? actualPlaybackConfirmedUs;
  final sub = fixture.nativePlaybackRepository.snapshots.listen((snapshot) {
    final session = fixture.playback.sessionById(id)!;
    if (snapshot.sessionId == id &&
        snapshot.playing &&
        snapshot.transportCommandId == session.transportCommandId &&
        session.transportCommandId > previousCommandId) {
      actualPlaybackConfirmedUs ??= started.elapsedMicroseconds;
    }
  });
  try {
    await tester.tap(
      play,
      kind: Platform.isWindows
          ? PointerDeviceKind.mouse
          : PointerDeviceKind.touch,
    );
    await WidgetsBinding.instance.endOfFrame;
    final switcher = tester.widget<AnimatedSwitcher>(
      find.descendant(
        of: find.byElementPredicate(
          (element) => identical(element, buttonElement),
        ),
        matching: find.byType(AnimatedSwitcher),
      ),
    );
    latency['nextFrameIntentFeedbackUs'] = started.elapsedMicroseconds;
    latency['nextFrameIntentFeedbackObserved'] =
        fixture.playback.sessionById(id)!.playbackRequested &&
        (switcher.child?.key == const ValueKey<bool>(true) ||
            switcher.child?.key == const ValueKey<String>('loading'));
    await _waitForRuntimeSession(tester, fixture, id, playing: true);
    latency['actualPlaybackConfirmedUs'] =
        actualPlaybackConfirmedUs ?? started.elapsedMicroseconds;
    latency['actualPlaybackConfirmationSource'] =
        actualPlaybackConfirmedUs == null ? 'snapshot' : 'native event';
  } finally {
    await sub.cancel();
  }
  if (!wasPlaying) {
    await _toggleRuntimeSession(tester, fixture, id, playing: false);
  }
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  unawaited(navigator.push(buildSessionDetailRoute(sessionId: id)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  navigator.pop();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await _switchMainPage(tester, MainDestinationType.library);
  return latency;
}

List<PlaybackSession> _seedRuntime(
  AppRuntimeWidgetTestFixture fixture, {
  required int trackCount,
}) {
  fixture.settingsRepository.syncSlice(isInitialized: true);
  final tracks = List.generate(
    trackCount,
    (index) =>
        testMusicTrack(
          name: 'Performance track ${index + 1}',
          path: '/profile/audio_${index + 1}.mp3',
          groupKey: '/profile/group_${index + 1}',
          groupTitle: 'Performance album ${index + 1}',
          isSingle: true,
        ).copyWith(
          coverCachePath: _profileCovers.isEmpty
              ? null
              : _profileCovers[index % _profileCovers.length].path,
        ),
  );
  if (_scenario == 'detail-compare') {
    tracks.addAll(<MusicTrack>[
      testMusicTrack(
        name: 'Local work track 1',
        path: '/profile/work/track_1.mp3',
        groupKey: '/profile/work',
        groupTitle: 'Local performance work',
      ),
      testMusicTrack(
        name: 'Local work track 2',
        path: '/profile/work/track_2.mp3',
        groupKey: '/profile/work',
        groupTitle: 'Local performance work',
      ),
    ]);
  }
  fixture.library.addTracks(tracks, notify: false, persist: false);
  fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

  final sessions = List.generate(12, (index) {
    final session =
        PlaybackSession(
            id: 'profile_session_$index',
            currentTrackPath: tracks[index].path,
            loopMode: SessionLoopMode.single,
            nonSingleLoopMode: SessionLoopMode.single,
            volume: 1,
            createdAt: DateTime(2026, 8, 3, 0, index),
            state: PlayerState(index == 0, ProcessingState.ready),
          )
          ..duration = const Duration(minutes: 20)
          ..bufferedPosition = const Duration(minutes: 5);
    fixture.playbackService.registerSession(session);
    return session;
  });
  if (_scenario == 'detail-compare') {
    final remoteTracks = List.generate(
      2,
      (index) => MusicTrack(
        path: 'https://example.com/profile/asmr_${index + 1}.mp3',
        displayName: 'ASMR track ${index + 1}',
        groupKey: 'asmr-work-profile',
        groupTitle: 'ASMR performance work',
        groupSubtitle: 'RJ100000',
        isSingle: false,
        remoteMetadataKind: MusicTrack.remoteMetadataKindAsmrOne,
        remoteMetadata: const <String, Object?>{
          'id': 100000,
          'workTitle': 'ASMR performance work',
        },
      ),
    );
    for (final (id, track, queue) in <(String, MusicTrack, List<MusicTrack>?)>[
      ('profile_local_detail', tracks[trackCount], null),
      ('profile_asmr_detail', remoteTracks.first, remoteTracks),
    ]) {
      final session = PlaybackSession(
        id: id,
        currentTrackPath: track.path,
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026, 8, 3),
        state: const PlayerState(false, ProcessingState.ready),
        customQueueTracks: queue,
      )..duration = const Duration(minutes: 20);
      fixture.playbackService.registerSession(session);
      sessions.add(session);
    }
  }
  fixture.playbackService.syncSlice(
    activeSessions: fixture.playbackService.activeSessions,
    playingSessionCount: 1,
    focusedSessionId: sessions.first.id,
    coverGeneration: 0,
    isInitialized: true,
  );
  return sessions;
}

typedef _TransitionSamples = ({
  List<Map<String, Object>> rounds,
  List<Map<String, Object>> conditions,
});

Map<String, Object> _imageCacheSample() {
  final cache = PaintingBinding.instance.imageCache;
  return {
    'bytes': cache.currentSizeBytes,
    'count': cache.currentSize,
    'live': cache.liveImageCount,
    'pending': cache.pendingImageCount,
  };
}

final class _MemoryPressureProbe with WidgetsBindingObserver {
  int count = 0;

  @override
  void didHaveMemoryPressure() => count++;
}

Future<Map<String, Object>> _prepareTransitionCondition(
  WidgetTester tester,
) async {
  final binding = tester.binding;
  if (_transitionCondition == 'os-resume') {
    expect(
      Platform.isAndroid,
      true,
      reason: 'os-resume requires Android and an external ADB driver',
    );
    return (await tester.runAsync(() async {
      final paused = Completer<void>();
      final resumed = Completer<void>();
      final backgroundWatch = Stopwatch();
      final memoryPressure = _MemoryPressureProbe();
      binding.addObserver(memoryPressure);
      final listener = AppLifecycleListener(
        onStateChange: (state) {
          if (state == AppLifecycleState.paused && !paused.isCompleted) {
            backgroundWatch.start();
            paused.complete();
          } else if (state == AppLifecycleState.resumed &&
              paused.isCompleted &&
              !resumed.isCompleted) {
            backgroundWatch.stop();
            resumed.complete();
          }
        },
      );
      try {
        // The host sends HOME, waits, then activates the existing .perf task.
        // Do not synthesize lifecycle events or kill the process in this case.
        debugPrint('PAGE_TRANSITION_OS_BACKGROUND_READY');
        await paused.future.timeout(const Duration(seconds: 30));
        await resumed.future.timeout(
          const Duration(seconds: _idleSeconds + 120),
        );
        expect(
          backgroundWatch.elapsed,
          greaterThanOrEqualTo(const Duration(seconds: _idleSeconds)),
        );
        return <String, Object>{
          'observedBackgroundMs': backgroundWatch.elapsedMilliseconds,
          'observedMemoryPressureEvents': memoryPressure.count,
        };
      } finally {
        listener.dispose();
        binding.removeObserver(memoryPressure);
      }
    }))!;
  }
  if (_transitionCondition == 'memory-pressure') {
    binding.handleMemoryPressure();
    await tester.pump();
    return const {};
  }
  if (_transitionCondition == 'idle') {
    return (await tester.runAsync(() async {
      expect(binding.lifecycleState, AppLifecycleState.resumed);
      final interrupted = Completer<AppLifecycleState>();
      final watch = Stopwatch()..start();
      final listener = AppLifecycleListener(
        onStateChange: (state) {
          if (state != AppLifecycleState.resumed && !interrupted.isCompleted) {
            debugPrint('PAGE_TRANSITION_IDLE_INTERRUPTED ${state.name}');
            interrupted.complete(state);
          }
        },
      );
      try {
        debugPrint('PAGE_TRANSITION_IDLE_READY pid=$pid seconds=$_idleSeconds');
        final state = await Future.any<AppLifecycleState?>([
          Future<void>.delayed(
            const Duration(seconds: _idleSeconds),
          ).then((_) => null),
          interrupted.future,
        ]);
        watch.stop();
        expect(
          state,
          isNull,
          reason:
              'Foreground idle was interrupted after '
              '${watch.elapsedMilliseconds} ms by ${state?.name}',
        );
        expect(binding.lifecycleState, AppLifecycleState.resumed);
        debugPrint('PAGE_TRANSITION_IDLE_COMPLETE');
        return <String, Object>{
          'foregroundIdleMs': watch.elapsedMilliseconds,
          'foregroundIdlePid': pid,
          'foregroundIdleContinuous': true,
        };
      } finally {
        listener.dispose();
      }
    }))!;
  }
  if (_transitionCondition == 'resume') {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  }
  try {
    if (_transitionCondition == 'resume') {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: _idleSeconds)),
      );
    }
  } finally {
    if (_transitionCondition == 'resume') {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  }
  return const {};
}

// Captures the route created by the production card callback, without a
// widget-tree traversal in the measured frame's visibility probe.
final class _PerformanceRouteObserver extends NavigatorObserver {
  TransitionRoute<dynamic>? lastPushed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    lastPushed = route is TransitionRoute<dynamic> ? route : null;
  }
}

bool _routeTransitionVisible(TransitionRoute<dynamic>? route) {
  final progress = route?.animation?.value;
  // A prepared route may report 1 before its deferred push and first layout.
  return progress != null && progress > 0 && progress < 1;
}

Map<String, Object> _pageTransitionReport(
  _TransitionSamples samples, {
  required bool playing,
}) => {
  'scenario': _scenario,
  'platform': Platform.isWindows ? 'windows' : 'android',
  'mode': kProfileMode ? 'profile' : (kReleaseMode ? 'release' : 'debug'),
  'runtime': playing ? (Platform.isWindows ? 'libmpv' : 'Media3') : 'fixture',
  'playing': playing,
  'semanticsEnabled': _semanticsEnabled,
  'platformSemanticsEnabled': WidgetsBinding.instance.semanticsEnabled,
  'coverFixtureCount': _profileCovers.length,
  'hostTimelineCapture': _traceReadyFile.isNotEmpty,
  'decodedImageCacheCount': PaintingBinding.instance.imageCache.currentSize,
  'libraryItems': playing ? 100 : _libraryItemCount,
  'asmrItems': playing ? 100 : _asmrItemCount,
  'transitionCondition': _transitionCondition,
  'idleSeconds': _idleSeconds,
  'openings': _openings,
  'refreshRateHz': _refreshRate,
  'frameBudgetSource': _displayRefreshRate.isFinite && _displayRefreshRate > 0
      ? 'FlutterView.display.refreshRate'
      : '60 Hz fallback',
  'frameBudgetUs': _frameBudget.inMicroseconds,
  'frameTimingDeliveryWaitMs': 2000,
  'frameSampleWindow':
      'Action invocation through 36 pumps at 16 ms; preparation and trailing UI frames included',
  'firstVisibleFrameMeasurement':
      'UI frame commit with 0 < route progress < 1 or incoming slide within viewport; not display presentation time',
  'firstVisibleFrameSampleWindow':
      'First 10 visible animation frames, matched by engine frame number; includes the first visible frame',
  'firstVisibleProbe':
      'Retained slide elements resolved before timing; no widget-tree search in frame callbacks',
  'asmrDetailEntry': 'Real ASMR card onTap -> showAsmrWorkDetailSheet',
  'conditionApplication': 'Once before each opening cycle, starting on Library',
  'lifecycleSource': _transitionCondition == 'resume'
      ? 'Test binding lifecycle simulation; not OS background or surface recreation'
      : _transitionCondition == 'os-resume'
      ? 'External ADB HOME and activity activation; observed OS paused/resumed events'
      : 'No simulated background transition',
  'resumeRuntime': playing
      ? 'Started runtime with real playback'
      : 'Presentation fixture; audio runtime not started',
  'memoryPressureSource': _transitionCondition == 'memory-pressure'
      ? 'Test binding handleMemoryPressure; not measured OS memory pressure'
      : 'No simulated memory pressure',
  'samplingLimits':
      'Synthetic library/ASMR metadata and optional cover files; baseline is a fresh '
      'test process but starts after fixture setup, not production cold-start latency. '
      'No display presentation or renderer surface-loss trace. ImageCache counters '
      'exclude GPU textures, Dart heap and native player memory.',
  'conditions': samples.conditions,
  'rounds': samples.rounds,
};

bool Function() _observeTransitionSlide(WidgetTester tester, String stackKey) {
  // Finder traversal inside POST_FRAME was itself producing 20 ms frames.
  // Existing page elements survive the slide; only inspect their positions.
  final slides = find
      .descendant(
        of: find.byKey(ValueKey<String>(stackKey)),
        matching: find.byType(SlideTransition),
      )
      .evaluate()
      .toList(growable: false);
  expect(slides, isNotEmpty);
  return () => slides.any((element) {
    if (!element.mounted) return false;
    final dx = (element.widget as SlideTransition).position.value.dx;
    return dx.abs() > 0.001 && dx.abs() < 0.999;
  });
}

Future<void> _waitForHostTimeline(WidgetTester tester) async {
  if (_traceReadyFile.isNotEmpty) {
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (!await File(_traceReadyFile).exists()) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException(
            'Host did not enable navigation timeline tracing',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
  }
}

Future<Map<String, Object>> _measureTransitionAction(
  WidgetTester tester,
  String name,
  int opening,
  VoidCallback action,
  bool Function() visible, {
  VoidCallback? afterFirstPump,
}) async {
  final cacheBefore = _imageCacheSample();
  final timings = <FrameTiming>[];
  void collect(List<FrameTiming> values) => timings.addAll(values);
  WidgetsBinding.instance.addTimingsCallback(collect);
  final started = DateTime.now().microsecondsSinceEpoch;
  final timelineStarted = Timeline.now;
  int? firstVisible;
  int? firstVisibleFrameNumber;
  final visibleFrameNumbers = <int>{};
  var sampling = true;
  void observeVisibleFrame(Duration _) {
    if (!sampling) return;
    if (visible()) {
      firstVisible ??= DateTime.now().microsecondsSinceEpoch;
      final frameNumber =
          WidgetsBinding.instance.platformDispatcher.frameData.frameNumber;
      firstVisibleFrameNumber ??= frameNumber;
      visibleFrameNumbers.add(frameNumber);
    }
    WidgetsBinding.instance.addPostFrameCallback(observeVisibleFrame);
  }

  late int finished;
  late int timelineFinished;
  try {
    action();
    WidgetsBinding.instance.addPostFrameCallback(observeVisibleFrame);
    // Observe every frame rather than jumping over the preparation interval.
    for (var frame = 0; frame < 36; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (frame == 0) afterFirstPump?.call();
    }
    finished = DateTime.now().microsecondsSinceEpoch;
    timelineFinished = Timeline.now;
    sampling = false;
    if (_traceReadyFile.isNotEmpty) {
      debugPrint(
        'PAGE_TRANSITION_TIMELINE_READY ${jsonEncode({'transition': name, 'opening': opening, 'startUs': timelineStarted, 'endUs': timelineFinished})}',
      );
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  } finally {
    sampling = false;
    WidgetsBinding.instance.removeTimingsCallback(collect);
  }
  timings.retainWhere(
    (timing) => _frameStartedWithin(timing, started, finished),
  );
  // A frame's buildFinish precedes its post-frame callback. Comparing it with
  // callback wall time would drop the first visible frame and hide its cost.
  final visibleTimings = firstVisibleFrameNumber == null
      ? <FrameTiming>[]
      : timings
            .where((timing) => visibleFrameNumbers.contains(timing.frameNumber))
            .toList(growable: false);
  final preparationTimings = firstVisibleFrameNumber == null
      ? timings
      : timings
            .where((timing) => timing.frameNumber < firstVisibleFrameNumber!)
            .toList(growable: false);
  final result = <String, Object>{
    ..._summarizeRound(opening, timings),
    'transition': name,
    'opening': opening,
    'pass': opening == 1 ? 'initial' : 'repeat',
    'condition': _transitionCondition,
    'imageCacheBefore': cacheBefore,
    'imageCacheAfter': _imageCacheSample(),
    'preparationFrames': _summarizeRound(opening, preparationTimings),
    'visibleAnimationFrames': _summarizeRound(opening, visibleTimings),
    'firstTenVisibleFrames': _summarizeRound(
      opening,
      visibleTimings.take(10).toList(growable: false),
    ),
    'firstVisibleUiFrameLatencyUs': firstVisible == null
        ? -1
        : firstVisible! - started,
    'firstVisibleFrameNumber': firstVisibleFrameNumber ?? -1,
    'firstSampledVisibleFrameNumber': visibleTimings.isEmpty
        ? -1
        : visibleTimings.first.frameNumber,
    'visibleFrameNumbers': visibleFrameNumbers.toList(growable: false),
    'overBudgetFrameTimings': [
      for (final timing in timings)
        if (timing.buildDuration > _frameBudget ||
            timing.rasterDuration > _frameBudget)
          {
            'frameNumber': timing.frameNumber,
            'visible': visibleFrameNumbers.contains(timing.frameNumber),
            'uiUs': timing.buildDuration.inMicroseconds,
            'rasterUs': timing.rasterDuration.inMicroseconds,
            'buildStartTimelineUs': timing.timestampInMicroseconds(
              FramePhase.buildStart,
            ),
            'rasterStartTimelineUs': timing.timestampInMicroseconds(
              FramePhase.rasterStart,
            ),
          },
    ],
    'actionWindowUs': finished - started,
    'actionStartedUs': started,
    'actionFinishedUs': finished,
    'actionStartedTimelineUs': timelineStarted,
    'actionFinishedTimelineUs': timelineFinished,
  };
  debugPrint('PAGE_TRANSITION_PERFORMANCE ${jsonEncode(result)}');
  expect(
    firstVisible,
    isNotNull,
    reason: '$name must produce a visible animation frame',
  );
  expect(
    result['firstSampledVisibleFrameNumber'],
    firstVisibleFrameNumber,
    reason: '$name must include the first visible probe frame in timings',
  );
  return result;
}

Future<_TransitionSamples> _measurePageTransitions(
  WidgetTester tester, {
  String localPath = '/profile/audio_1.mp3',
  String sessionId = 'profile_session_11',
}) async {
  await _waitForHostTimeline(tester);
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  final routeObserver = navigator.widget.observers
      .whereType<_PerformanceRouteObserver>()
      .single;
  final rounds = <Map<String, Object>>[];
  final conditions = <Map<String, Object>>[];
  final target = AudioDetailTarget.singleAudioFile(localPath);
  final localDetail = AudioDetail(
    target: target,
    rjCode: 'RJ100000',
    workTitle: 'Performance album 1',
    circleName: 'Profile circle',
    voiceActors: const ['Profile voice'],
    tags: const ['offline', 'profile'],
    duration: const Duration(minutes: 20),
  );
  Future<void> settleTransition() async {
    // Real playback keeps scheduling progress frames, so pumpAndSettle cannot
    // define the end of a navigation animation in the playing scenario.
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> measure(
    String name,
    int opening,
    VoidCallback action,
    bool Function() visible,
  ) async {
    rounds.add(
      await _measureTransitionAction(tester, name, opening, action, visible),
    );
  }

  void selectDestination(MainDestinationType destination) {
    final index = switch (destination) {
      MainDestinationType.asmrOne => 0,
      MainDestinationType.playlist => 2,
      MainDestinationType.settings => 3,
      MainDestinationType.library => 1,
    };
    final rail = find.byType(NavigationRail);
    if (rail.evaluate().isNotEmpty) {
      tester.widget<NavigationRail>(rail).onDestinationSelected!(index);
    } else {
      final key = switch (destination) {
        MainDestinationType.asmrOne => 'show_asmr_one',
        MainDestinationType.playlist => 'nav_sessions',
        MainDestinationType.settings => 'nav_settings',
        MainDestinationType.library => 'music_library',
      };
      final ink = find.byKey(ValueKey<String>('main_destination_ink_$key'));
      tester.widget<InkResponse>(ink).onTap!();
    }
  }

  for (var opening = 1; opening <= _openings; opening++) {
    // Start each pass from Library, so first visits to the other tabs are measured.
    await _switchMainPage(tester, MainDestinationType.library);
    final conditionSample = <String, Object>{
      'opening': opening,
      'condition': _transitionCondition,
      'requestedWaitSeconds':
          _transitionCondition == 'idle' ||
              _transitionCondition == 'resume' ||
              _transitionCondition == 'os-resume'
          ? _idleSeconds
          : 0,
      'imageCacheBeforeCondition': _imageCacheSample(),
    };
    final conditionStarted = DateTime.now();
    conditionSample.addAll(await _prepareTransitionCondition(tester));
    conditionSample['conditionElapsedMs'] = DateTime.now()
        .difference(conditionStarted)
        .inMilliseconds;
    conditionSample['imageCacheAfterCondition'] = _imageCacheSample();
    for (final destination in [
      MainDestinationType.playlist,
      MainDestinationType.settings,
      MainDestinationType.asmrOne,
    ]) {
      await measure(
        'main-${destination.name}',
        opening,
        () {
          selectDestination(destination);
        },
        _observeTransitionSlide(tester, 'main_page_stack'),
      );
      await settleTransition();
    }
    for (final category in [
      AsmrCategoryType.recommendation,
      AsmrCategoryType.collected,
    ]) {
      await measure(
        'asmr-${category.name}',
        opening,
        () {
          tester
              .widget<HeaderSegmentedCategoryBar<AsmrCategoryType>>(
                find.byType(HeaderSegmentedCategoryBar<AsmrCategoryType>),
              )
              .onSelected(category);
        },
        _observeTransitionSlide(tester, 'asmr_category_stack'),
      );
      await settleTransition();
    }
    for (final (name, destination) in [
      ('library-from-asmr', MainDestinationType.library),
      ('playlist-from-library', MainDestinationType.playlist),
      ('library-from-playlist', MainDestinationType.library),
      ('settings-from-library', MainDestinationType.settings),
      ('library-from-settings', MainDestinationType.library),
      ('asmr-from-library', MainDestinationType.asmrOne),
    ]) {
      await measure('main-$name', opening, () {
        selectDestination(destination);
      }, _observeTransitionSlide(tester, 'main_page_stack'));
      await settleTransition();
    }
    final workTitle = find.text('Performance ASMR 1').hitTestable();
    expect(workTitle, findsOneWidget);
    final workCard = find
        .ancestor(of: workTitle, matching: find.byType(InkWell))
        .first;
    final openWork = tester.widget<InkWell>(workCard).onTap;
    expect(openWork, isNotNull);
    routeObserver.lastPushed = null;
    await measure('work-asmr', opening, openWork!, () {
      final route = routeObserver.lastPushed;
      return route?.settings.name == workDetailRouteName &&
          _routeTransitionVisible(route);
    });
    navigator.pop();
    await settleTransition();
    routeObserver.lastPushed = null;
    await measure(
      'session-detail',
      opening,
      () {
        unawaited(
          navigator.push(buildSessionDetailRoute(sessionId: sessionId)),
        );
      },
      () => _routeTransitionVisible(routeObserver.lastPushed),
    );
    navigator.pop();
    await settleTransition();
    await _switchMainPage(tester, MainDestinationType.library);
    for (final (name, page) in <(String, Widget)>[
      (
        'ordinary-about',
        AboutPage(
          versionFuture: Future.value(
            const AppVersionInfo(versionName: 'profile', buildNumber: 1),
          ),
        ),
      ),
      (
        'work-local',
        WorkDetailPage.forLocal(target: target, initialDetail: localDetail),
      ),
    ]) {
      late PageRoute<void> route;
      await measure(name, opening, () {
        route = buildAppPageRoute<void>(
          context: navigator.context,
          child: page,
          settings: page is WorkDetailPage
              ? const RouteSettings(name: workDetailRouteName)
              : null,
          workDetailTransition: page is WorkDetailPage,
        );
        if (page is WorkDetailPage) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (navigator.mounted) unawaited(navigator.push(route));
          });
        } else {
          unawaited(navigator.push(route));
        }
      }, () => _routeTransitionVisible(route));
      navigator.pop();
      await settleTransition();
    }
    conditionSample['imageCacheAfterCycle'] = _imageCacheSample();
    conditions.add(conditionSample);
    debugPrint('PAGE_TRANSITION_CONDITION ${jsonEncode(conditionSample)}');
  }
  if (_profileCovers.isNotEmpty) {
    expect(
      PaintingBinding.instance.imageCache.currentSize,
      greaterThan(0),
      reason:
          'The cover fixture must decode images, not measure only fallbacks.',
    );
  }
  return (rounds: rounds, conditions: conditions);
}

Future<List<Map<String, Object>>> _measureDetailComparison(
  WidgetTester tester,
) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  final rounds = <Map<String, Object>>[];
  unawaited(
    navigator.push(buildSessionDetailRoute(sessionId: 'profile_session_11')),
  );
  await tester.pump(const Duration(milliseconds: 350));
  navigator.pop();
  await tester.pump(const Duration(milliseconds: 350));
  for (final (source, sessionId) in <(String, String)>[
    ('local', 'profile_local_detail'),
    ('asmr', 'profile_asmr_detail'),
  ]) {
    for (var opening = 1; opening <= 3; opening++) {
      final timings = <FrameTiming>[];
      void collect(List<FrameTiming> values) => timings.addAll(values);
      WidgetsBinding.instance.addTimingsCallback(collect);
      final started = DateTime.now().microsecondsSinceEpoch;
      late int finished;
      try {
        unawaited(
          navigator.push(buildSessionDetailRoute(sessionId: sessionId)),
        );
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        finished = DateTime.now().microsecondsSinceEpoch;
        await Future<void>.delayed(const Duration(seconds: 2));
      } finally {
        WidgetsBinding.instance.removeTimingsCallback(collect);
      }
      timings.retainWhere(
        (timing) => _frameStartedWithin(timing, started, finished),
      );
      rounds.add(<String, Object>{
        ..._summarizeRound(opening, timings),
        'source': source,
        'opening': opening,
      });
      navigator.pop();
      await tester.pump(const Duration(milliseconds: 350));
    }
  }
  return rounds;
}

List<AsmrWork> _buildAsmrWorks(int count) => List.generate(
  count,
  (index) => AsmrWork(
    id: index + 1,
    title: 'Performance ASMR ${index + 1}',
    circleName: 'Profile circle ${(index % 12) + 1}',
    sourceId: 'RJ${(100000 + index).toString()}',
    sourceType: 'DLSITE',
    sourceUrl: '',
    coverUrl: _profileCovers.isEmpty
        ? ''
        : _profileCovers[index % _profileCovers.length].url,
    thumbnailUrl: _profileCovers.isEmpty
        ? ''
        : _profileCovers[index % _profileCovers.length].url,
    mainCoverUrl: _profileCovers.isEmpty
        ? ''
        : _profileCovers[index % _profileCovers.length].url,
    releaseDate: DateTime(2026),
    createDate: DateTime(2026),
    duration: Duration(minutes: 30 + index),
    dlCount: index * 17,
    reviewCount: index,
    rating: 4.5,
    voiceActors: const <String>['Profile voice'],
    tags: const <String>['offline', 'profile'],
  ),
);

List<AsmrTrackFile> _buildAsmrTrackTree(int count) => List.generate(
  count,
  (index) => AsmrTrackFile(
    hash: 'profile-track-$index',
    title: 'Performance ASMR track ${index + 1}.mp3',
    type: 'audio',
    streamUrl: 'https://example.com/profile-track-$index.mp3',
    downloadUrl: 'https://example.com/profile-track-$index.mp3',
    lowQualityUrl: null,
    duration: const Duration(minutes: 1),
    size: 1024,
    children: const <AsmrTrackFile>[],
    workId: 1,
    workTitle: 'Performance ASMR 1',
    sourceId: 'RJ100000',
    relativePath: 'Performance ASMR track ${index + 1}.mp3',
  ),
  growable: false,
);

Future<void> _runScenario(
  WidgetTester tester,
  List<PlaybackSession> sessions,
  String scenario,
  _BackupProfileFixture? backupFixture,
) async {
  if (scenario == 'library-large') {
    await _switchMainPage(tester, MainDestinationType.library);
    await _ensureLocalLibrary(tester);
    await _flingPageList<LibraryTab>(tester);
    return;
  }
  if (scenario == 'asmr-large') {
    await _switchMainPage(tester, MainDestinationType.library);
    await _switchToAsmr(tester);
    await _flingPageList<AsmrTab>(tester);
    await _openAndCloseFirstAsmrWork(tester);
    return;
  }
  if (scenario == 'backup') {
    await _runBackupExport(tester, backupFixture!);
    await _switchMainPage(tester, MainDestinationType.playlist);
    await _flingPageList<PlaylistTab>(tester);
    await _switchMainPage(tester, MainDestinationType.library);
    return;
  }
  await _switchMainPage(tester, MainDestinationType.library);
  await _ensureLocalLibrary(tester);
  await _flingPageList<LibraryTab>(tester);
  await _switchToAsmr(tester);
  await _flingPageList<AsmrTab>(tester);

  await _switchMainPage(tester, MainDestinationType.playlist);
  for (var frame = 0; frame < 24; frame++) {
    sessions.first.applyNativeProgress(
      NativePlaybackProgressUpdate(
        sessionId: sessions.first.id,
        position: Duration(milliseconds: frame * 250),
        bufferedPosition: Duration(seconds: 30 + frame),
        duration: const Duration(minutes: 20),
        nativeElapsedRealtimeMs: frame * 250,
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await _openAndCloseSessionDetail(tester);
  await _flingPageList<PlaylistTab>(tester);
  await _switchMainPage(tester, MainDestinationType.settings);
  await _switchMainPage(tester, MainDestinationType.library);
  await _ensureLocalLibrary(tester);
}

Future<void> _openAndCloseFirstAsmrWork(WidgetTester tester) async {
  final firstWork = find.text('Performance ASMR 1');
  if (firstWork.evaluate().isEmpty) return;
  await tester.tap(firstWork.first);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pageBack();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _runBackupExport(
  WidgetTester tester,
  _BackupProfileFixture fixture,
) async {
  final output = File(fixture.outputPath);
  final service = fixture.service;
  await _pumpUntilComplete(
    tester,
    service.exportBackup(output.path).then<void>((_) {}),
  );
  await _pumpUntilComplete(
    tester,
    service.inspectAndStageRestore(output.path).then<void>((_) {}),
  );
  if (await output.exists()) await output.delete();
  final part = File('${output.path}.part');
  if (await part.exists()) await part.delete();
}

Future<void> _pumpUntilComplete(WidgetTester tester, Future<void> operation) =>
    TestAsyncUtils.guard(() async {
      var complete = false;
      Object? failure;
      StackTrace? failureStack;
      final tracked = operation
          .catchError((Object error, StackTrace stack) {
            failure = error;
            failureStack = stack;
          })
          .whenComplete(() => complete = true);
      while (!complete) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tracked;
      if (failure != null) {
        Error.throwWithStackTrace(failure!, failureStack!);
      }
    });

final class _BackupProfileFixture {
  _BackupProfileFixture({
    required this.directory,
    required this.database,
    required this.service,
  });

  final Directory directory;
  final Database database;
  final DataBackupService service;

  String get outputPath =>
      '${directory.path}${Platform.pathSeparator}ui-performance-backup.dabackup';

  static Future<_BackupProfileFixture> create(int payloadBytes) async {
    final temporaryDirectory = await getTemporaryDirectory();
    final directory = await Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}'
      'doujin-ui-performance-${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final database = await openDatabase(
      '${directory.path}${Platform.pathSeparator}profile.sqlite',
    );
    await AppDatabase.createSchemaForTest(database);
    await database.execute(
      'PRAGMA user_version = ${AppDatabase.schemaVersion}',
    );
    if (payloadBytes > 0) {
      const profileTrackPath = '/performance/backup-payload.mp3';
      await database.insert('tracks', <String, Object?>{
        'path': profileTrackPath,
        'display_name': 'Backup performance payload',
        'group_key': '/performance',
        'group_title': 'Performance',
        'group_subtitle': '',
        'is_single': 1,
        'is_video': 0,
        'duration_ms': 1000,
      });
      await database.rawInsert(
        'INSERT INTO track_remote_metadata('
        'path, remote_metadata_kind, remote_metadata_json'
        ') VALUES (?, ?, zeroblob(?))',
        <Object?>[profileTrackPath, 'performance-payload', payloadBytes],
      );
    }
    final service = DataBackupService(
      database: AppDatabase.test(database),
      supportDirectoryProvider: () async => directory,
      platformName: Platform.operatingSystem,
    );
    return _BackupProfileFixture(
      directory: directory,
      database: database,
      service: service,
    );
  }

  Future<void> dispose() async {
    await database.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

Future<void> _switchMainPage(
  WidgetTester tester,
  MainDestinationType destination,
) async {
  final index = switch (destination) {
    MainDestinationType.asmrOne => 0,
    MainDestinationType.library => 1,
    MainDestinationType.playlist => 2,
    MainDestinationType.settings => 3,
  };
  final stack = find.byKey(const ValueKey<String>('main_page_stack'));
  for (var attempt = 0; attempt < 100 && stack.evaluate().isEmpty; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
  if (stack.evaluate().isEmpty) {
    debugPrint(
      'UI_PERFORMANCE_STARTUP main=${find.byType(MainScreen).evaluate().length} '
      'stackOffstage=${find.byKey(const ValueKey<String>('main_page_stack'), skipOffstage: false).evaluate().length} '
      'errors=${find.byType(ErrorWidget).evaluate().length}',
    );
  }
  expect(stack, findsOneWidget);
  if (tester.widget<AppFadeThroughIndexedStack>(stack).index == index) return;
  final rail = find.byType(NavigationRail);
  if (rail.evaluate().isNotEmpty) {
    tester.widget<NavigationRail>(rail).onDestinationSelected!(index);
  } else {
    final labelKey = switch (destination) {
      MainDestinationType.asmrOne => 'show_asmr_one',
      MainDestinationType.library => 'music_library',
      MainDestinationType.playlist => 'nav_sessions',
      MainDestinationType.settings => 'nav_settings',
    };
    await tester.tap(
      find.byKey(ValueKey<String>('main_destination_ink_$labelKey')),
    );
  }
  // Start the transition before advancing its duration. A single delayed pump
  // starts a newly built transition at the end of that delay.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump();
}

Future<void> _switchToAsmr(WidgetTester tester) async {
  await _switchMainPage(tester, MainDestinationType.asmrOne);
}

Future<void> _ensureLocalLibrary(WidgetTester tester) async {
  await _switchMainPage(tester, MainDestinationType.library);
}

Future<void> _flingPageList<T extends Widget>(WidgetTester tester) async {
  ScrollPosition? currentPosition() {
    final scrollables = find.descendant(
      of: find.byType(T),
      matching: find.byType(Scrollable),
    );
    final positions = scrollables
        .evaluate()
        .map((element) => (element as StatefulElement).state)
        .whereType<ScrollableState>()
        .map((state) => state.position)
        .where((position) => position.axis == Axis.vertical)
        .toList(growable: false);
    if (positions.isEmpty) return null;
    positions.sort((a, b) => b.maxScrollExtent.compareTo(a.maxScrollExtent));
    return positions.first;
  }

  Future<void> animateTo({required bool end}) async {
    final position = currentPosition();
    if (position == null ||
        position.maxScrollExtent <= position.minScrollExtent) {
      return;
    }
    final animation = position.animateTo(
      end ? position.maxScrollExtent : position.minScrollExtent,
      duration: const Duration(milliseconds: 480),
      curve: Curves.easeOut,
    );
    for (var frame = 0; frame < 32; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await animation;
  }

  await animateTo(end: true);
  await animateTo(end: false);
}

Future<void> _openAndCloseSessionDetail(WidgetTester tester) async {
  final card = find.byKey(const ValueKey<String>('profile_session_11'));
  if (card.evaluate().isEmpty) return;
  await tester.tap(card);
  await tester.pump(const Duration(milliseconds: 350));
  if (tester.state<NavigatorState>(find.byType(Navigator)).canPop()) {
    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 350));
  }
}

Map<String, Object> _assessPlaybackPerformance(
  List<Map<String, Object>> rounds,
  Map<String, Object> idleObservation,
) {
  final absoluteChecks = [
    for (final round in rounds)
      for (final (sample, metrics) in <(String, Map<String, Object>)>[
        ('main navigation', round),
        if (round['sessionInteractionFrames'] != null)
          (
            'session controls and detail',
            round['sessionInteractionFrames'] as Map<String, Object>,
          ),
      ])
        {
          'stage': round['stage']!,
          'round': round['round']!,
          'sample': sample,
          'frameCount': metrics['frameCount']!,
          'uiP95Us': metrics['uiP95Us']!,
          'rasterP95Us': metrics['rasterP95Us']!,
          'overBudgetPercent': metrics['overBudgetPercent']!,
          'passed':
              (metrics['frameCount'] as int) > 0 &&
              (metrics['uiP95Us'] as int) <= _frameBudget.inMicroseconds &&
              (metrics['rasterP95Us'] as int) <= _frameBudget.inMicroseconds &&
              (metrics['overBudgetPercent'] as num) <= 1,
        },
  ];
  final increments = <Map<String, Object>>[];
  for (final round in rounds.where(
    (round) => round['stage'] == 'idle-1' || round['stage'] == 'idle-5',
  )) {
    final baseline = rounds
        .where(
          (baseline) =>
              baseline['stage'] == 'idle-0' &&
              baseline['round'] == round['round'],
        )
        .firstOrNull;
    if (baseline == null) {
      increments.add({
        'stage': round['stage']!,
        'round': round['round']!,
        'passed': false,
      });
      continue;
    }
    final uiDelta = (round['uiP95Us'] as int) - (baseline['uiP95Us'] as int);
    final rasterDelta =
        (round['rasterP95Us'] as int) - (baseline['rasterP95Us'] as int);
    increments.add({
      'stage': round['stage']!,
      'round': round['round']!,
      'uiP95DeltaUs': uiDelta,
      'rasterP95DeltaUs': rasterDelta,
      'passed': uiDelta <= 1000 && rasterDelta <= 1000,
    });
  }
  const expectedStages = {
    'idle-0',
    'idle-1',
    'idle-5',
    'idle-50',
    'playing-2',
    'queue-1000',
  };
  final measurementValid =
      kProfileMode &&
      (WidgetsBinding.instance as IntegrationTestWidgetsFlutterBinding)
              .framePolicy ==
          LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive &&
      rounds.length == 18 &&
      expectedStages.every(
        (stage) => rounds.where((round) => round['stage'] == stage).length == 3,
      ) &&
      absoluteChecks.length == 33 &&
      absoluteChecks.every((check) => (check['frameCount'] as int) > 0);
  final baselineWithinBudget = absoluteChecks
      .where((check) => check['stage'] == 'idle-0')
      .every((check) => check['passed'] == true);
  final allStagesWithinBudget = absoluteChecks.every(
    (check) => check['passed'] == true,
  );
  final idleIncrementWithinBudget =
      increments.length == 6 &&
      increments.every((check) => check['passed'] == true);
  final nextFrameFeedbackObserved = rounds
      .where((round) => (round['sessionCount'] as int) > 0)
      .every((round) => round['nextFrameIntentFeedbackObserved'] == true);
  final idle60SecondsSilent =
      idleObservation['sessionCount'] == 50 &&
      (idleObservation['observationMs'] as int) >= 60000 &&
      idleObservation['structuralEvents'] == 0 &&
      idleObservation['progressEvents'] == 0 &&
      (!Platform.isWindows || idleObservation['retainedPlayers'] == 0);
  return {
    'measurementValid': measurementValid,
    'baselineWithinBudget': baselineWithinBudget,
    'allStagesWithinBudget': allStagesWithinBudget,
    'idleSessionIncrementWithinBudget': idleIncrementWithinBudget,
    'nextFrameIntentFeedbackObserved': nextFrameFeedbackObserved,
    'idle60SecondsSilent': idle60SecondsSilent,
    'allTargetsPassed':
        measurementValid &&
        baselineWithinBudget &&
        allStagesWithinBudget &&
        idleIncrementWithinBudget &&
        nextFrameFeedbackObserved &&
        idle60SecondsSilent,
    'thresholds': {
      'p95Us': _frameBudget.inMicroseconds,
      'overBudgetPercent': 1,
      'idleP95DeltaUs': 1000,
    },
    'absoluteChecks': absoluteChecks,
    'idleSessionIncrements': increments,
  };
}

void _expectFrameBudgets(List<Map<String, Object>> rounds) {
  if (!kProfileMode) return;
  final failures = <Map<String, Object>>[];
  for (final round in rounds) {
    for (final (window, sample) in <(String, Map<String, Object>)>[
      ('whole-action', round),
      if (round['visibleAnimationFrames']
          case final Map<String, Object> visible)
        ('visible-animation', visible),
    ]) {
      if ((sample['frameCount'] as int) <= 0 ||
          (sample['uiP95Us'] as int) > _frameBudget.inMicroseconds ||
          (sample['rasterP95Us'] as int) > _frameBudget.inMicroseconds ||
          (sample['overBudgetPercent'] as num) > 1) {
        failures.add({
          'transition': round['transition'] ?? _scenario,
          'round': round['round']!,
          'window': window,
          'metrics': sample,
        });
      }
    }
  }
  expect(
    failures,
    isEmpty,
    reason:
        'PERF_SCENARIO=$_scenario budgetUs=${_frameBudget.inMicroseconds}; ${jsonEncode(failures)}',
  );
}

Map<String, Object> _summarizeRound(int round, List<FrameTiming> timings) {
  final ui = timings.map((timing) => timing.buildDuration).toList()..sort();
  final raster = timings.map((timing) => timing.rasterDuration).toList()
    ..sort();
  final overBudget = timings
      .map(
        (timing) =>
            timing.buildDuration > _frameBudget ||
            timing.rasterDuration > _frameBudget,
      )
      .toList(growable: false);
  var longestRun = 0;
  var currentRun = 0;
  for (final slow in overBudget) {
    currentRun = slow ? currentRun + 1 : 0;
    if (currentRun > longestRun) longestRun = currentRun;
  }
  return <String, Object>{
    'round': round,
    'frameCount': timings.length,
    'uiP95Us': _percentile95(ui).inMicroseconds,
    'uiMaxUs': ui.isEmpty ? 0 : ui.last.inMicroseconds,
    'rasterP95Us': _percentile95(raster).inMicroseconds,
    'rasterMaxUs': raster.isEmpty ? 0 : raster.last.inMicroseconds,
    'overBudgetFrames': overBudget.where((slow) => slow).length,
    'overBudgetPercent': timings.isEmpty
        ? 0
        : overBudget.where((slow) => slow).length * 100 / timings.length,
    'maxConsecutiveOverBudgetFrames': longestRun,
  };
}

bool _frameStartedWithin(FrameTiming timing, int startUs, int endUs) {
  final buildStartWallUs = _frameTimestampWallUs(timing, FramePhase.buildStart);
  return buildStartWallUs >= startUs && buildStartWallUs <= endUs;
}

int _frameTimestampWallUs(FrameTiming timing, FramePhase phase) =>
    timing.timestampInMicroseconds(FramePhase.rasterFinishWallTime) -
    (timing.timestampInMicroseconds(FramePhase.rasterFinish) -
        timing.timestampInMicroseconds(phase));

Duration _percentile95(List<Duration> sorted) {
  if (sorted.isEmpty) return Duration.zero;
  final index = ((sorted.length - 1) * 0.95).ceil();
  return sorted[index];
}

final class _ProfileAsmrController extends AsmrLibraryController {
  _ProfileAsmrController({
    required TestAsmrServices services,
    required this.works,
    required this.trackTree,
  }) : super(
         preferencesStore: services.preferencesStore,
         remoteCatalogService: services.remoteCatalogService,
         accountSyncService: services.accountSyncService,
       );

  final List<AsmrWork> works;
  final List<AsmrTrackFile> trackTree;

  @override
  Future<List<AsmrTrackFile>> ensureTrackTree(
    AsmrWork work, {
    bool forceRefresh = false,
  }) async => trackTree;

  @override
  bool get initialized => true;
  @override
  AppLanguage get pageLanguage => AppLanguage.zh;
  @override
  bool get isAsmrAccountLoggedIn => false;

  @override
  Future<void> initialize({AsmrContentLanguage? defaultLanguage}) async {}
  @override
  Future<void> restoreAsmrAccountSession({bool force = false}) async {}
  @override
  bool setPageLanguage(AppLanguage language) => false;

  @override
  AsmrLibraryGlobalViewState get globalViewState => AsmrLibraryGlobalViewState(
    initialized: true,
    visibleCategories: kDefaultVisibleAsmrCategories,
    contentLanguage: AsmrContentLanguage.zh,
    contentLanguagePreference: ContentLanguagePreference.followPage,
    revision: 0,
  );

  @override
  List<AsmrWork> worksFor(AsmrCategoryType category) =>
      category == AsmrCategoryType.collected ? works : const <AsmrWork>[];
  @override
  int totalCountFor(AsmrCategoryType category) => worksFor(category).length;
  @override
  String activeQueryFor(AsmrCategoryType category) => '';

  @override
  AsmrCategoryViewState categoryViewState(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) => AsmrCategoryViewState(
    category: category,
    works: worksFor(category),
    isLoading: false,
    isLoadingMore: false,
    isRefreshing: false,
    isStale: false,
    hasAttemptedLoad: true,
    hasMore: false,
    needsLoadMoreRetry: false,
    totalCount: totalCountFor(category),
    activeQuery: searchQuery,
    lastError: null,
    operationError: null,
    revision: 0,
  );

  @override
  AsmrTrackTreeViewState trackTreeViewState(int workId) {
    final visibleTree = workId == 1 && trackTree.isNotEmpty
        ? trackTree
        : const <AsmrTrackFile>[];
    return AsmrTrackTreeViewState(
      workId: workId,
      tree: visibleTree,
      visibleTree: visibleTree,
      isLoading: false,
      isRefreshing: false,
      isStale: false,
      operationError: null,
      revision: 0,
    );
  }
}
