import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import '../test/support/asmr_controller_test_fixture.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:doujin_audio/app/presentation/main_screen.dart';
import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_tab.dart';
import 'package:doujin_audio/features/data_support/application/data_backup_service.dart';
import 'package:doujin_audio/features/library/presentation/library_tab.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:doujin_audio/features/player/presentation/playlist_view_models.dart';
import 'package:doujin_audio/features/settings/application/app_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../test/support/app_runtime_test_fixture.dart';

const _frameBudget = Duration(microseconds: 16667);
const _scenario = String.fromEnvironment('PERF_SCENARIO', defaultValue: 'core');
const _libraryItemOverride = int.fromEnvironment('PERF_LIBRARY_ITEMS');
const _asmrItemOverride = int.fromEnvironment('PERF_ASMR_ITEMS');
const _asmrTrackOverride = int.fromEnvironment('PERF_ASMR_TRACKS');
const _backupByteOverride = int.fromEnvironment('PERF_BACKUP_BYTES');

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

  testWidgets('profile main interaction path', (tester) async {
    expect(
      const <String>{
        'core',
        'library-large',
        'asmr-large',
        'backup',
        'detail-compare',
      },
      contains(_scenario),
      reason: 'Unsupported PERF_SCENARIO=$_scenario',
    );
    SharedPreferences.setMockInitialValues(const <String, Object>{
      AppPreferences.onboardingCompletedKey: true,
    });
    final fixture = AppRuntimeWidgetTestFixture();
    final sessions = _seedRuntime(fixture, trackCount: _libraryItemCount);
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
    await tester.pumpWidget(
      fixture.build(
        const MainScreen(),
        navigatorObservers: <NavigatorObserver>[
          UiInteractionNavigatorObserver.instance,
        ],
        overrides: <Override>[
          asmrLibraryControllerProvider.overrideWithValue(asmrController),
          mainOverlayUiProvider.overrideWithValue(
            const MainOverlayUiState(
              overlaySessions: <PlaybackSessionSnapshot>[],
              playingSessionCount: 0,
              activeSessionCount: 0,
              isInitialized: true,
              startupReady: true,
            ),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    if (_scenario == 'detail-compare') {
      final rounds = await _measureDetailComparison(tester, fixture);
      final report = <String, Object>{
        'fixture': <String, int>{
          'libraryItems': _libraryItemCount + 2,
          'asmrItems': _asmrItemCount,
          'asmrTracks': _asmrTrackCount,
          'backupBytes': _backupByteCount,
          'playbackSessions': sessions.length,
        },
        'scenario': _scenario,
        'frameBudgetUs': _frameBudget.inMicroseconds,
        'rounds': rounds,
      };
      binding.reportData = <String, dynamic>{'uiPerformance': report};
      debugPrint('UI_PERFORMANCE ${jsonEncode(report)}');
      expect(
        !kProfileMode ||
            rounds.every((round) => (round['frameCount'] as int) > 0),
        isTrue,
      );
      return;
    }

    // The first pass warms shaders, text and lazily-created list/card widgets.
    await _runScenario(tester, sessions, _scenario, backupFixture);

    final rounds = <Map<String, Object>>[];
    for (var round = 1; round <= 3; round++) {
      final timings = <FrameTiming>[];
      void collect(List<FrameTiming> values) => timings.addAll(values);
      WidgetsBinding.instance.addTimingsCallback(collect);
      await _runScenario(tester, sessions, _scenario, backupFixture);
      await tester.pump(const Duration(milliseconds: 100));
      WidgetsBinding.instance.removeTimingsCallback(collect);
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
      'frameBudgetUs': _frameBudget.inMicroseconds,
      'rounds': rounds,
    };
    binding.reportData = <String, dynamic>{'uiPerformance': report};
    debugPrint('UI_PERFORMANCE ${jsonEncode(report)}');
    expect(
      !kProfileMode ||
          rounds.every((round) => (round['frameCount'] as int) > 0),
      isTrue,
    );
  });
}

List<PlaybackSession> _seedRuntime(
  AppRuntimeWidgetTestFixture fixture, {
  required int trackCount,
}) {
  fixture.settingsRepository.syncSlice(isInitialized: true);
  final tracks = List.generate(
    trackCount,
    (index) => testMusicTrack(
      name: 'Performance track ${index + 1}',
      path: '/profile/audio_${index + 1}.mp3',
      groupKey: '/profile/group_${index + 1}',
      groupTitle: 'Performance album ${index + 1}',
      isSingle: true,
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

Future<List<Map<String, Object>>> _measureDetailComparison(
  WidgetTester tester,
  AppRuntimeWidgetTestFixture fixture,
) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  final rounds = <Map<String, Object>>[];
  unawaited(
    navigator.push(buildSessionDetailRoute(sessionId: 'profile_session_11')),
  );
  await tester.pump(const Duration(milliseconds: 350));
  navigator.pop();
  await tester.pump(const Duration(milliseconds: 350));
  for (final blurEnabled in <bool>[true, false]) {
    fixture.settingsRepository.blurPlayerBackgroundEnabled = blurEnabled;
    fixture.settingsRepository.syncSlice(isInitialized: true);
    await tester.pump(const Duration(milliseconds: 50));
    for (final (source, sessionId) in <(String, String)>[
      ('local', 'profile_local_detail'),
      ('asmr', 'profile_asmr_detail'),
    ]) {
      for (var opening = 1; opening <= 3; opening++) {
        final timings = <FrameTiming>[];
        void collect(List<FrameTiming> values) => timings.addAll(values);
        WidgetsBinding.instance.addTimingsCallback(collect);
        unawaited(
          navigator.push(buildSessionDetailRoute(sessionId: sessionId)),
        );
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.pump(const Duration(milliseconds: 100));
        WidgetsBinding.instance.removeTimingsCallback(collect);
        rounds.add(<String, Object>{
          ..._summarizeRound(opening, timings),
          'source': source,
          'blurEnabled': blurEnabled,
          'opening': opening,
        });
        navigator.pop();
        await tester.pump(const Duration(milliseconds: 350));
      }
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
    coverUrl: '',
    thumbnailUrl: '',
    mainCoverUrl: '',
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

Future<void> _pumpUntilComplete(
  WidgetTester tester,
  Future<void> operation,
) async {
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
}

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
  await tester.pump(const Duration(milliseconds: 900));
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
    'rasterP95Us': _percentile95(raster).inMicroseconds,
    'overBudgetFrames': overBudget.where((slow) => slow).length,
    'overBudgetPercent': timings.isEmpty
        ? 0
        : overBudget.where((slow) => slow).length * 100 / timings.length,
    'maxConsecutiveOverBudgetFrames': longestRun,
  };
}

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
