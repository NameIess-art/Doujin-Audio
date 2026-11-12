import 'dart:async';

import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/operation_feedback.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_tab.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/asmr_controller_test_fixture.dart';

class _ActivationController extends AsmrLibraryController {
  _ActivationController(TestAsmrServices services)
    : super(
        preferencesStore: services.preferencesStore,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: services.accountSyncService,
      );

  bool fail = false;
  bool hasCachedWork = false;
  int cachedWorkCount = 1;
  bool _initialized = false;
  int attempts = 0;
  int categoryLoads = 0;
  Completer<void>? barrier;
  Completer<void>? accountRestoreBarrier;
  Completer<void>? accountSyncBarrier;
  int accountRestores = 0;
  int accountSyncs = 0;

  @override
  bool get isAsmrAccountLoggedIn => true;

  @override
  bool get initialized => _initialized || hasCachedWork;

  @override
  AsmrLibraryGlobalViewState get globalViewState => AsmrLibraryGlobalViewState(
    initialized: initialized,
    visibleCategories: kDefaultVisibleAsmrCategories,
    contentLanguage: AsmrContentLanguage.zh,
    contentLanguagePreference: ContentLanguagePreference.followPage,
    revision: attempts,
  );

  @override
  Future<void> initializeForVisiblePage({
    AsmrContentLanguage? defaultLanguage,
  }) async {
    if (_initialized) return;
    attempts++;
    await (barrier?.future ??
        Future<void>.delayed(const Duration(milliseconds: 1)));
    if (fail) throw StateError('Persistence unavailable');
    _initialized = true;
    notifyListeners();
  }

  @override
  Future<void> restoreAsmrAccountSession({bool force = false}) async {
    accountRestores++;
    await accountRestoreBarrier?.future;
  }

  @override
  Future<void> syncAsmrAccount({bool force = false}) async {
    accountSyncs++;
    await accountSyncBarrier?.future;
  }

  @override
  Future<void> ensureCategoryLoaded(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {
    categoryLoads++;
    notifyListeners();
  }

  @override
  List<AsmrWork> filteredWorksFor(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) => categoryViewState(
    category,
    searchQuery: searchQuery,
    searchSession: searchSession,
  ).works;

  @override
  AsmrCategoryViewState categoryViewState(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) => AsmrCategoryViewState(
    category: category,
    works: hasCachedWork
        ? [
            for (var id = 1; id <= cachedWorkCount; id++)
              AsmrWork.fromJson({
                'id': id,
                'title': id == 1 ? 'Cached work' : 'Cached work $id',
              }),
          ]
        : const [],
    isLoading: false,
    isLoadingMore: false,
    isRefreshing: false,
    isStale: false,
    hasAttemptedLoad: hasCachedWork || categoryLoads != 0,
    hasMore: false,
    needsLoadMoreRetry: false,
    totalCount: hasCachedWork ? cachedWorkCount : 0,
    activeQuery: searchQuery,
    lastError: null,
    operationError: null,
    revision: categoryLoads,
  );
}

class _SearchSuggestionsController extends _ActivationController {
  _SearchSuggestionsController(super.services);

  int suggestionLoads = 0;
  AsmrSearchSuggestions suggestions = AsmrSearchSuggestions(
    voiceActors: const ['Initial voice'],
    tags: const ['Initial tag'],
  );

  @override
  AsmrSearchSuggestions get searchSuggestions => suggestions;

  @override
  Future<void> ensureSearchSuggestions({bool force = false}) async {
    suggestionLoads++;
  }
}

Future<void> _pumpFrames(WidgetTester tester) async {
  // Retry and category snapshots each fade before deferred work resumes at idle.
  final duration =
      kAppMotionFast +
      kPlaceholderContentTransitionDuration * 2 +
      UiInteractionCoordinator.instance.idleDelay;
  const frameDuration = Duration(milliseconds: 20);
  for (
    var elapsed = Duration.zero;
    elapsed <= duration;
    elapsed += frameDuration
  ) {
    await tester.pump(frameDuration);
  }
}

NavigatorState _coverPage(WidgetTester tester) {
  final navigator = Navigator.of(tester.element(find.byType(AsmrTab)));
  unawaited(
    navigator.push<void>(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => const Scaffold(body: Text('Covering route')),
      ),
    ),
  );
  return navigator;
}

void main() {
  setUp(() {
    UiInteractionCoordinator.instance.resetForTest();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  const platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.windows,
  });

  for (final (name, page) in [
    ('catalog', const AsmrTab()),
    ('search results', const AsmrSearchPage(initialQuery: 'Cached')),
  ]) {
    testWidgets('online $name handles wheel input on both platforms', (
      tester,
    ) async {
      final fixture = AppRuntimeWidgetTestFixture();
      final controller = _SearchSuggestionsController(createTestAsmrServices())
        ..hasCachedWork = true
        ..cachedWorkCount = 40;
      addTearDown(fixture.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        fixture.build(
          page,
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
          ],
        ),
      );
      await _pumpFrames(tester);

      final list = find.byKey(const PageStorageKey(AsmrCategoryType.collected));
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)).first,
      );
      final position = scrollable.position;
      expect(position.maxScrollExtent, greaterThan(80));
      final start = position.pixels;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(list),
          scrollDelta: const Offset(0, 80),
        ),
      );
      if (defaultTargetPlatform == TargetPlatform.windows) {
        expect(position.pixels, start);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 48));
        expect(position.pixels, inExclusiveRange(start, start + 80));
      } else {
        expect(position.pixels, start + 80);
      }
      await tester.pumpAndSettle();
      expect(position.pixels, start + 80);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: platforms);
  }

  testWidgets('online activation waits for navigation but bypasses startup work', (
    tester,
  ) async {
    final coordinator = UiInteractionCoordinator.instance;
    final startup = Completer<void>();
    addTearDown(() {
      if (!startup.isCompleted) startup.complete();
    });
    var startupStarted = false;
    coordinator.scheduleAfterIdle(
      key: 'secondary_startup',
      generation: coordinator.generation,
      priority: 200,
      task: () {
        startupStarted = true;
        return startup.future;
      },
    );
    expect(startupStarted, isTrue);

    final fixture = AppRuntimeWidgetTestFixture();
    final controller = _ActivationController(createTestAsmrServices());
    addTearDown(fixture.dispose);
    addTearDown(controller.dispose);
    final navigation = Object();
    coordinator.beginNavigation(navigation);
    await tester.pumpWidget(
      fixture.build(
        const AsmrTab(),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      ),
    );
    await _pumpFrames(tester);
    expect(controller.attempts, 0);
    expect(controller.categoryLoads, 0);

    coordinator.endNavigation(navigation);
    await _pumpFrames(tester);
    expect(controller.attempts, 1);
    expect(controller.categoryLoads, 1);
    expect(startup.isCompleted, isFalse);
    startup.complete();
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);

  testWidgets(
    'Windows online work context menu enters selection with its work selected',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      final controller = _ActivationController(createTestAsmrServices())
        ..hasCachedWork = true;
      addTearDown(fixture.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        fixture.build(
          const AsmrTab(),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
          ],
        ),
      );
      await _pumpFrames(tester);
      await tester.tap(
        find.text('Cached work'),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(fixture.languageProvider.tr('select_multiple')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('asmr_batch_selection_header')),
        findsOneWidget,
      );
      expect(
        find.text(
          fixture.languageProvider.tr('selected_count', {'count': '1'}),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          ValueKey(
            'asmr_selection_indicator_${AsmrWork.fromJson(const {'id': 1, 'title': 'Cached work'}).workKey}',
          ),
        ),
        findsOneWidget,
      );
      expect(fixture.playback.activeSessions, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('search suggestion IO and publication wait for navigation', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    final controller = _SearchSuggestionsController(createTestAsmrServices());
    final observer = UiInteractionNavigatorObserver();
    addTearDown(fixture.dispose);
    addTearDown(controller.dispose);
    addTearDown(observer.dispose);
    await tester.pumpWidget(
      fixture.build(
        const Text('Search home'),
        navigatorObservers: [observer],
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.text('Search home'));
    unawaited(
      Navigator.of(context).push(
        buildAppPageRoute<void>(
          context: context,
          child: const AsmrSearchPage(),
          separateHeader: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(controller.suggestionLoads, 0);
    await tester.pumpAndSettle();
    expect(controller.suggestionLoads, 1);
    expect(find.text('Initial tag'), findsOneWidget);

    final interaction = UiInteractionCoordinator.instance;
    final source = Object();
    interaction.beginNavigation(source);
    for (var i = 0; i < 5; i++) {
      controller.suggestions = AsmrSearchSuggestions(
        voiceActors: ['New voice $i'],
        tags: ['New tag $i'],
      );
      controller.notifyListeners();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('Initial tag'), findsOneWidget);
      expect(find.text('New tag $i'), findsNothing);
    }
    interaction.endNavigation(source);
    await tester.pump(interaction.idleDelay);
    await tester.pumpAndSettle();
    expect(find.text('New tag 4'), findsOneWidget);
    expect(controller.suggestionLoads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    // Leaving before idle must cancel the queued work, rather than load data
    // for a search page that no longer exists.
    interaction.beginNavigation(source);
    await tester.pumpWidget(fixture.build(
      const AsmrSearchPage(),
      overrides: [asmrLibraryControllerProvider.overrideWithValue(controller)],
    ));
    await tester.pump();
    expect(controller.suggestionLoads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    interaction.endNavigation(source);
    await tester.pump(interaction.idleDelay);
    await tester.pumpAndSettle();
    expect(controller.suggestionLoads, 1);
  }, variant: platforms);

  for (final syncing in [false, true]) {
    testWidgets(
      'account ${syncing ? 'sync' : 'restore'} releases idle queue and stays deduplicated on return',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final pending = Completer<void>();
        final controller = _ActivationController(createTestAsmrServices());
        if (syncing) {
          controller.accountSyncBarrier = pending;
        } else {
          controller.accountRestoreBarrier = pending;
        }
        addTearDown(fixture.dispose);
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await _pumpFrames(tester);
        expect(controller.accountRestores, 1);
        expect(controller.accountSyncs, syncing ? 1 : 0);

        final navigator = _coverPage(tester);
        await tester.pump();
        final coordinator = UiInteractionCoordinator.instance;
        final generation = coordinator.beginGeneration();
        var queryCompleted = false;
        coordinator.scheduleAfterIdle(
          key: 'other_page_local_query',
          generation: generation,
          priority: 20,
          task: () async => queryCompleted = true,
        );
        await _pumpFrames(tester);
        expect(queryCompleted, isTrue);
        expect(pending.isCompleted, isFalse);

        navigator.pop();
        await _pumpFrames(tester);
        expect(controller.accountRestores, 1);
        expect(controller.accountSyncs, syncing ? 1 : 0);
        pending.complete();
        await _pumpFrames(tester);
        expect(controller.accountSyncs, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: platforms,
    );
  }

  testWidgets(
    'failed account hydration retries on return and can finish after disposal',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      final failed = Completer<void>();
      final controller = _ActivationController(createTestAsmrServices())
        ..accountRestoreBarrier = failed;
      addTearDown(fixture.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        fixture.build(
          const AsmrTab(),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
          ],
        ),
      );
      await _pumpFrames(tester);
      failed.completeError(StateError('Account temporarily unavailable'));
      await _pumpFrames(tester);
      final retry = Completer<void>();
      controller.accountRestoreBarrier = retry;
      final navigator = _coverPage(tester);
      await tester.pump();
      navigator.pop();
      await _pumpFrames(tester);
      expect(controller.accountRestores, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      retry.complete();
      await tester.pump();
      expect(controller.accountSyncs, 1);
      expect(tester.takeException(), isNull);
    },
    variant: platforms,
  );

  testWidgets('cached works wait for visible page activation', (tester) async {
    final fixture = AppRuntimeWidgetTestFixture();
    final barrier = Completer<void>();
    final controller = _ActivationController(createTestAsmrServices())
      ..hasCachedWork = true
      ..barrier = barrier;
    addTearDown(fixture.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      fixture.build(
        const AsmrTab(),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      ),
    );
    await _pumpFrames(tester);
    expect(controller.initialized, isTrue);
    expect(controller.attempts, 1);
    expect(controller.categoryLoads, 0);
    expect(find.byType(LibrarySkeletonListView), findsOneWidget);
    expect(find.text('Cached work', skipOffstage: false), findsNothing);

    barrier.complete();
    await _pumpFrames(tester);
    expect(controller.categoryLoads, 1);
    expect(find.text('Cached work'), findsOneWidget);
    expect(find.byType(LibrarySkeletonListView), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);

  testWidgets('cached works stay hidden while retrying activation', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    final controller = _ActivationController(createTestAsmrServices())
      ..hasCachedWork = true
      ..fail = true;
    addTearDown(fixture.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      fixture.build(
        const AsmrTab(),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      ),
    );
    await _pumpFrames(tester);
    expect(find.byType(OperationStatusBanner), findsOneWidget);
    expect(find.text('Cached work', skipOffstage: false), findsNothing);

    final barrier = Completer<void>();
    controller
      ..fail = false
      ..barrier = barrier;
    await tester.tap(find.byTooltip(fixture.languageProvider.tr('retry')));
    await _pumpFrames(tester);
    expect(controller.attempts, 2);
    expect(find.byType(OperationStatusBanner), findsNothing);
    expect(find.byType(LibrarySkeletonListView), findsOneWidget);
    expect(find.text('Cached work', skipOffstage: false), findsNothing);

    barrier.complete();
    await _pumpFrames(tester);
    expect(find.text('Cached work'), findsOneWidget);
    expect(find.byType(LibrarySkeletonListView), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);

  testWidgets('initialization failure waits for an explicit retry', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    final controller = _ActivationController(createTestAsmrServices())
      ..fail = true;
    addTearDown(fixture.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      fixture.build(
        const AsmrTab(),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      ),
    );
    await _pumpFrames(tester);
    expect(controller.attempts, 1);
    expect(find.byType(OperationStatusBanner), findsOneWidget);
    expect(
      find.text(fixture.languageProvider.tr('operation_failed_retry')),
      findsOneWidget,
    );

    final navigator = _coverPage(tester);
    await tester.pump();
    navigator.pop();
    await _pumpFrames(tester);
    expect(controller.attempts, 1);

    // Two taps before the next frame must share the same activation task.
    await tester.tap(find.byTooltip(fixture.languageProvider.tr('retry')));
    await tester.tap(find.byTooltip(fixture.languageProvider.tr('retry')));
    await _pumpFrames(tester);
    expect(controller.attempts, 2);
    expect(find.byType(OperationStatusBanner), findsOneWidget);

    controller.fail = false;
    await tester.tap(find.byTooltip(fixture.languageProvider.tr('retry')));
    await _pumpFrames(tester);
    expect(controller.attempts, 3);
    expect(controller.categoryLoads, 1);
    expect(find.byType(OperationStatusBanner), findsNothing);
    expect(
      find.text(fixture.languageProvider.tr('asmr_empty_category')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);

  for (final finishWhileCovered in [false, true]) {
    testWidgets(
      'route return resumes activation, completed while covered: $finishWhileCovered',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final barrier = Completer<void>();
        final controller = _ActivationController(createTestAsmrServices())
          ..barrier = barrier;
        addTearDown(fixture.dispose);
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await _pumpFrames(tester);
        expect(controller.attempts, 1);
        final navigator = _coverPage(tester);
        await tester.pump();
        if (finishWhileCovered) {
          barrier.complete();
          await _pumpFrames(tester);
          expect(controller.categoryLoads, 0);
        }
        navigator.pop();
        await tester.pump();
        if (!finishWhileCovered) {
          await _pumpFrames(tester);
          expect(controller.attempts, 1);
          barrier.complete();
        }
        await _pumpFrames(tester);
        expect(controller.attempts, 1);
        expect(controller.categoryLoads, 1);
        expect(
          find.text(fixture.languageProvider.tr('asmr_empty_category')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: platforms,
    );
  }

  testWidgets('route return restarts activation discarded while queued', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    final controller = _ActivationController(createTestAsmrServices());
    addTearDown(fixture.dispose);
    addTearDown(controller.dispose);
    final interaction = Object();
    UiInteractionCoordinator.instance.beginInteraction(interaction);
    await tester.pumpWidget(
      fixture.build(
        const AsmrTab(),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      ),
    );
    final navigator = _coverPage(tester);
    await tester.pump();
    UiInteractionCoordinator.instance.cancelInteraction(interaction);
    await _pumpFrames(tester);
    expect(controller.attempts, 0);
    navigator.pop();
    await _pumpFrames(tester);
    expect(controller.attempts, 1);
    expect(controller.categoryLoads, 1);
    expect(
      find.text(fixture.languageProvider.tr('asmr_empty_category')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);
}
