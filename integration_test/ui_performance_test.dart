import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:doujin_audio/app/presentation/main_screen.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/application/asmr_preferences.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_tab.dart';
import 'package:doujin_audio/features/library/presentation/library_tab.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:doujin_audio/features/player/presentation/playlist_view_models.dart';
import 'package:doujin_audio/features/settings/application/app_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/app_runtime_test_fixture.dart';

const _frameBudget = Duration(microseconds: 16667);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('profile main interaction path', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      AppPreferences.onboardingCompletedKey: true,
    });
    final fixture = AppRuntimeWidgetTestFixture();
    final sessions = _seedRuntime(fixture);
    final asmrController = _ProfileAsmrController(
      fixture: fixture,
      works: _buildAsmrWorks(),
    );
    addTearDown(() async {
      for (final session in sessions) {
        session.dispose();
      }
      asmrController.dispose();
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
              overlaySessions: <PlaybackSession>[],
              visibleSessions: <PlaybackSession>[],
              playingSessionCount: 0,
              activeSessionCount: 0,
              showPlaybackCard: false,
              isInitialized: true,
              startupReady: true,
            ),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // The first pass warms shaders, text and lazily-created list/card widgets.
    await _runScenario(tester, sessions);

    final rounds = <Map<String, Object>>[];
    for (var round = 1; round <= 3; round++) {
      final timings = <FrameTiming>[];
      void collect(List<FrameTiming> values) => timings.addAll(values);
      WidgetsBinding.instance.addTimingsCallback(collect);
      await _runScenario(tester, sessions);
      await tester.pump(const Duration(milliseconds: 100));
      WidgetsBinding.instance.removeTimingsCallback(collect);
      rounds.add(_summarizeRound(round, timings));
    }

    final report = <String, Object>{
      'fixture': <String, int>{
        'libraryItems': 100,
        'asmrItems': 100,
        'playbackSessions': 12,
      },
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

List<PlaybackSession> _seedRuntime(AppRuntimeWidgetTestFixture fixture) {
  fixture.settingsRepository.syncSlice(isInitialized: true);
  final tracks = List.generate(
    100,
    (index) => testMusicTrack(
      name: 'Performance track ${index + 1}',
      path: '/profile/audio_${index + 1}.mp3',
      groupKey: '/profile/group_${index + 1}',
      groupTitle: 'Performance album ${index + 1}',
      isSingle: true,
    ),
  );
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
  fixture.playbackService.syncSlice(
    activeSessions: fixture.playbackService.activeSessions,
    playingSessionCount: 1,
    focusedSessionId: sessions.first.id,
    multiThreadPlaybackEnabled: true,
    coverGeneration: 0,
    isInitialized: true,
  );
  return sessions;
}

List<AsmrWork> _buildAsmrWorks() => List.generate(
  100,
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

Future<void> _runScenario(
  WidgetTester tester,
  List<PlaybackSession> sessions,
) async {
  await _switchMainPage(tester, 0);
  await _ensureLocalLibrary(tester);
  await _flingPageList<LibraryTab>(tester);
  await _switchToAsmr(tester);
  await _flingPageList<AsmrTab>(tester);

  await _switchMainPage(tester, 1);
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
  await _switchMainPage(tester, 2);
  await _switchMainPage(tester, 0);
  await _ensureLocalLibrary(tester);
}

Future<void> _switchMainPage(WidgetTester tester, int index) async {
  final stack = find.byKey(const ValueKey<String>('main_page_stack'));
  if (tester.widget<AppFadeThroughIndexedStack>(stack).index == index) return;
  const keys = <String>[
    'main_destination_nav_library',
    'main_destination_nav_sessions',
    'main_destination_nav_settings',
  ];
  await tester.tap(find.byKey(ValueKey<String>(keys[index])));
  await tester.pump(const Duration(milliseconds: 320));
}

Future<void> _switchToAsmr(WidgetTester tester) async {
  final localHeader = find.byWidgetPredicate(
    (widget) => widget is TopPageHeader && widget.title != 'ASMR.ONE',
  );
  await tester.fling(localHeader.first, const Offset(-160, 0), 1200);
  await tester.pump(const Duration(milliseconds: 260));
}

Future<void> _ensureLocalLibrary(WidgetTester tester) async {
  final asmrHeader = find.byWidgetPredicate(
    (widget) => widget is TopPageHeader && widget.title == 'ASMR.ONE',
  );
  if (asmrHeader.evaluate().isEmpty) return;
  await tester.fling(asmrHeader.first, const Offset(160, 0), 1200);
  await tester.pump(const Duration(milliseconds: 260));
}

Future<void> _flingPageList<T extends Widget>(WidgetTester tester) async {
  final scrollables = find.descendant(
    of: find.byType(T),
    matching: find.byType(Scrollable),
  );
  if (scrollables.evaluate().isEmpty) return;
  await tester.fling(scrollables.last, const Offset(0, -1200), 5000);
  await tester.pump(const Duration(milliseconds: 500));
  await tester.fling(scrollables.last, const Offset(0, 1200), 5000);
  await tester.pump(const Duration(milliseconds: 500));
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
    required AppRuntimeWidgetTestFixture fixture,
    required this.works,
  }) : super(
         preferencesStore: AsmrPreferencesStore(
           repository: fixture.persistenceRepository,
         ),
       );

  final List<AsmrWork> works;

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
}
