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
import 'package:flutter/material.dart';
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
  bool _initialized = false;
  int attempts = 0;
  int categoryLoads = 0;
  Completer<void>? barrier;

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
  Future<void> restoreAsmrAccountSession({bool force = false}) async {}

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
  AsmrCategoryViewState categoryViewState(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) => AsmrCategoryViewState(
    category: category,
    works: hasCachedWork
        ? [
            AsmrWork.fromJson(const {'id': 1, 'title': 'Cached work'}),
          ]
        : const [],
    isLoading: false,
    isLoadingMore: false,
    isRefreshing: false,
    isStale: false,
    hasAttemptedLoad: hasCachedWork || categoryLoads != 0,
    hasMore: false,
    needsLoadMoreRetry: false,
    totalCount: hasCachedWork ? 1 : 0,
    activeQuery: searchQuery,
    lastError: null,
    operationError: null,
    revision: categoryLoads,
  );
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
