import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/app_search_page.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/asmr_controller_test_fixture.dart';

void main() {
  final interaction = UiInteractionCoordinator.instance;
  setUp(interaction.resetForTest);
  tearDown(interaction.resetForTest);

  Widget pageStack(ValueNotifier<int> activeTab) => AppFadeThroughIndexedStack(
    indexListenable: activeTab,
    duration: Duration.zero,
    children: [
      AsmrTab(activeTabIndexListenable: activeTab),
      const SizedBox.shrink(),
    ],
  );

  testWidgets('ASMR rebuilds keep published cards during interaction', (
    tester,
  ) async {
    final controller = _PresentationController(createTestAsmrServices());
    final fixture = AppRuntimeWidgetTestFixture();
    final padding = ValueNotifier<double>(0);
    final activeTab = ValueNotifier<int>(0);
    addTearDown(() {
      padding.dispose();
      activeTab.dispose();
      controller.dispose();
      fixture.dispose();
    });
    final motion = Object();
    interaction.beginInteraction(motion);
    await tester.pumpWidget(
      fixture.build(
        ValueListenableBuilder<double>(
          valueListenable: padding,
          builder: (context, value, _) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: true,
              padding: EdgeInsets.only(right: value),
            ),
            child: pageStack(activeTab),
          ),
        ),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));
    expect(controller.categoryReads, 0);
    expect(find.text('Published work'), findsNothing);

    interaction.cancelInteraction(motion);
    await pumpUntilFound(tester, find.text('Published work'));
    final readsBeforeMotion = controller.categoryReads;
    interaction.beginInteraction(motion);
    controller.publish('Deferred work');
    controller.publish('Newest work');
    padding.value = 1;
    await tester.pump(const Duration(milliseconds: 20));
    expect(controller.categoryReads, readsBeforeMotion);
    expect(find.text('Published work'), findsOneWidget);
    expect(find.text('Deferred work'), findsNothing);
    expect(find.text('Newest work'), findsNothing);

    interaction.cancelInteraction(motion);
    await pumpUntilFound(tester, find.text('Newest work'));
    expect(find.text('Published work'), findsNothing);

    activeTab.value = 1;
    await tester.pump();
    await tester.pump();
    final readsWhileHidden = controller.categoryReads;
    controller.publish('Return work');
    await tester.pump();
    expect(controller.categoryReads, readsWhileHidden);
    interaction.beginInteraction(motion);
    activeTab.value = 0;
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Newest work'), findsOneWidget);
    expect(find.text('Return work'), findsNothing);
    interaction.cancelInteraction(motion);
    await pumpUntilFound(tester, find.text('Return work'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'ASMR adjacent preparation does not activate data on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices())
          ..cacheValid = false;
        final fixture = AppRuntimeWidgetTestFixture();
        final activeTab = ValueNotifier<int>(0);
        final completed = <int>[];
        addTearDown(activeTab.dispose);
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            AppFadeThroughIndexedStack.lazy(
              indexListenable: activeTab,
              prepareAdjacentPage: true,
              separateHeader: true,
              itemCount: 2,
              onTransitionCompleted: completed.add,
              itemBuilder: (_, index) => index == 0
                  ? const Center(child: Text('Local page'))
                  : AsmrTab(
                      key: const ValueKey('prepared_asmr'),
                      tabIndex: 1,
                      activeTabIndexListenable: activeTab,
                    ),
            ),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        expect(find.byType(AsmrTab, skipOffstage: false), findsNothing);
        await tester.pump(interaction.idleDelay);
        await tester.pumpAndSettle();
        final hidden = find.byKey(
          const ValueKey('prepared_asmr'),
          skipOffstage: false,
        );
        expect(hidden, findsOneWidget);
        expect(TickerMode.valuesOf(tester.element(hidden)).enabled, isFalse);
        expect(find.text('Local page'), findsOneWidget);
        expect(activeTab.value, 0);
        expect(completed, isEmpty);
        expect(controller.initializations, 0);
        expect(controller.categoryLoads, 0);
        expect(controller.accountRestores, 0);

        // In-memory projection reads do not count as catalog/account requests.
        final hiddenProjectionReads = controller.categoryReads;
        expect(hiddenProjectionReads, lessThanOrEqualTo(1));
        controller.publish('Activated work');
        await tester.pumpAndSettle();
        expect(controller.categoryReads, hiddenProjectionReads);
        expect(controller.initializations, 0);
        expect(controller.categoryLoads, 0);
        expect(controller.accountRestores, 0);

        activeTab.value = 1;
        await tester.pumpAndSettle();
        await tester.pump(interaction.idleDelay);
        await tester.pumpAndSettle();
        expect(activeTab.value, 1);
        expect(completed, [1]);
        expect(controller.initializations, 1);
        expect(controller.categoryLoads, 1);
        expect(controller.accountRestores, 1);
        expect(controller.categoryReads, greaterThan(hiddenProjectionReads));
        expect(find.text('Activated work'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR empty search uses root cache on its first frame on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices());
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        final reads = controller.categoryReads;
        final loads = controller.categoryLoads;
        final initializations = controller.initializations;
        await tester.tap(find.byKey(const ValueKey('asmr_search_button')));
        await tester.pump();
        final results = find.byKey(const ValueKey('asmr_search_collected'));
        expect(
          find.descendant(of: results, matching: find.text('Published work')),
          findsOneWidget,
        );
        expect(controller.categoryReads, reads);
        await tester.pumpAndSettle();
        expect(controller.categoryReads, reads);
        expect(controller.categoryLoads, loads);
        expect(controller.initializations, initializations);
        final search = tester.widget<AppSearchPageScaffold<AsmrCategoryType>>(
          find.byType(AppSearchPageScaffold<AsmrCategoryType>),
        );
        search.onSubmitted('new query');
        await tester.pumpAndSettle();
        expect(controller.lastSearchQuery, 'new query');
        expect(controller.categoryReads, greaterThan(reads));
        final searchReads = controller.categoryReads;
        search.controller.text = 'new query';
        search.onCloseOrClear();
        await tester.pump();
        expect(
          find.descendant(of: results, matching: find.text('Published work')),
          findsOneWidget,
        );
        await tester.pumpAndSettle();
        expect(controller.categoryReads, searchReads);
        expect(controller.categoryLoads, loads);
        expect(controller.initializations, initializations);
        Navigator.of(tester.element(results)).pop();
        await tester.pumpAndSettle();
        controller.cacheValid = false;
        controller.publish('Reloaded work');
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('asmr_search_button')),
            )
            .onPressed!();
        await tester.pumpAndSettle();
        await tester.pump(interaction.idleDelay);
        await tester.pumpAndSettle();
        expect(controller.categoryLoads, greaterThan(loads));
        expect(
          find.descendant(of: results, matching: find.text('Reloaded work')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR category switches retain widgets and publish hidden updates on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices());
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        void select(AsmrCategoryType category) => tester
            .widget<HeaderSegmentedCategoryBar<AsmrCategoryType>>(
              find.byType(HeaderSegmentedCategoryBar<AsmrCategoryType>),
            )
            .onSelected(category);
        Future<void> settleCategory() async {
          await tester.pumpAndSettle();
          await tester.pump(interaction.idleDelay);
          await tester.pumpAndSettle();
        }

        final collected = find.byKey(
          const ValueKey(AsmrCategoryType.collected),
          skipOffstage: false,
        );
        final initialWidget = tester.widget(collected);
        final initialState = tester.state(collected);
        select(AsmrCategoryType.recommendation);
        await settleCategory();
        select(AsmrCategoryType.collected);
        await settleCategory();
        final initialReads = controller.categoryReads;
        for (var i = 0; i < 3; i++) {
          select(AsmrCategoryType.recommendation);
          await settleCategory();
          select(AsmrCategoryType.collected);
          await settleCategory();
        }
        expect(tester.widget(collected), same(initialWidget));
        expect(tester.state(collected), same(initialState));
        expect(controller.categoryReads, initialReads);

        select(AsmrCategoryType.recommendation);
        await settleCategory();
        controller.publish('Newest work');
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: collected,
            matching: find.text('Published work', skipOffstage: false),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        select(AsmrCategoryType.collected);
        await settleCategory();
        expect(find.text('Newest work'), findsOneWidget);
        expect(tester.state(collected), same(initialState));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR search categories retain content and adopt changed queries on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices());
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('asmr_search_button')));
        await tester.pumpAndSettle();
        AppSearchPageScaffold<AsmrCategoryType> search() =>
            tester.widget(find.byType(AppSearchPageScaffold<AsmrCategoryType>));
        final collected = find.byKey(
          const ValueKey('asmr_search_collected'),
          skipOffstage: false,
        );
        final initialWidget = tester.widget(collected);
        final initialState = tester.state(collected);
        for (var i = 0; i < 3; i++) {
          search().onCategorySelected(AsmrCategoryType.recommendation);
          await tester.pumpAndSettle();
          search().onCategorySelected(AsmrCategoryType.collected);
          await tester.pumpAndSettle();
        }
        expect(tester.widget(collected), same(initialWidget));
        expect(tester.state(collected), same(initialState));

        search().onCategorySelected(AsmrCategoryType.recommendation);
        await tester.pumpAndSettle();
        search().onSubmitted('Newest');
        controller.publish('Newest work');
        await tester.pumpAndSettle();
        final readsBeforeReturn = controller.categoryReads;
        search().onCategorySelected(AsmrCategoryType.collected);
        await tester.pumpAndSettle();
        await tester.pump(interaction.idleDelay);
        await tester.pumpAndSettle();
        expect(controller.lastSearchQuery, 'Newest');
        expect(controller.categoryReads, greaterThan(readsBeforeReturn));
        expect(tester.state(collected), same(initialState));
        expect(tester.widget(collected), isNot(same(initialWidget)));
        expect(find.text('Published work'), findsNothing);
        expect(
          find.descendant(
            of: collected,
            matching: find.textContaining('Newest work', findRichText: true),
          ),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR repeat switches retain category projections on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices());
        final fixture = AppRuntimeWidgetTestFixture();
        final activeTab = ValueNotifier<int>(0);
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        addTearDown(activeTab.dispose);
        await tester.pumpWidget(
          fixture.build(
            pageStack(activeTab),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        final initialReads = controller.categoryReads;
        final originalCard = tester.element(
          find.byKey(const ValueKey<String>('asmr-work-1')),
        );
        for (var i = 0; i < 3; i++) {
          activeTab.value = 1;
          await tester.pumpAndSettle();
          activeTab.value = 0;
          await tester.pumpAndSettle();
        }
        expect(controller.categoryReads, initialReads);
        expect(
          tester.element(find.byKey(const ValueKey<String>('asmr-work-1'))),
          same(originalCard),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR hidden page cancels queued pagination on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices())
          ..workCount = 30
          ..hasMore = true;
        final fixture = AppRuntimeWidgetTestFixture();
        final activeTab = ValueNotifier<int>(0);
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        addTearDown(activeTab.dispose);
        await tester.pumpWidget(
          fixture.build(
            pageStack(activeTab),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        expect(controller.loadMoreCount, 0);
        final motion = Object();
        interaction.beginInteraction(motion);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(800, 10000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pump();
        expect(
          find.byKey(const ValueKey<String>('asmr_load_more_progress')),
          findsOneWidget,
        );
        activeTab.value = 1;
        await tester.pump();
        interaction.cancelInteraction(motion);
        await tester.pump(interaction.idleDelay);
        await tester.pump();
        expect(controller.loadMoreCount, 0);
        activeTab.value = 0;
        await tester.pump();
        await tester.pump(interaction.idleDelay);
        await tester.pump();
        expect(controller.loadMoreCount, 1);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'ASMR appended card animation pauses while hidden on $platform',
      (tester) async {
        final controller = _PresentationController(createTestAsmrServices())
          ..hasMore = true
          ..needsRetry = true;
        final fixture = AppRuntimeWidgetTestFixture();
        final activeTab = ValueNotifier<int>(0);
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        addTearDown(activeTab.dispose);
        await tester.pumpWidget(
          fixture.build(
            pageStack(activeTab),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Published work'));
        await tester.pumpAndSettle();
        controller.workCount = 2;
        controller.publish('Published work');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        final card = find.byKey(
          const ValueKey<String>('asmr-work-2'),
          skipOffstage: false,
        );
        final animation = tester.widget<FadeTransition>(card).opacity;
        final beforeHide = animation.value;
        expect(beforeHide, inExclusiveRange(0, 1));
        activeTab.value = 1;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(animation.value, beforeHide);
        activeTab.value = 0;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(animation.value, greaterThan(beforeHide));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('ASMR category and tree providers defer initial projections', (
    tester,
  ) async {
    final controller = _PresentationController(createTestAsmrServices());
    final container = ProviderContainer(
      overrides: [asmrLibraryControllerProvider.overrideWithValue(controller)],
    );
    addTearDown(controller.dispose);
    addTearDown(container.dispose);
    final motion = Object();
    interaction.beginInteraction(motion);
    final category = asmrCategoryStateProvider((
      category: AsmrCategoryType.collected,
      searchQuery: '',
      searchSession: false,
    ));
    final tree = asmrTrackTreeStateProvider(1);
    final categorySubscription = container.listen(category, (_, _) {});
    final treeSubscription = container.listen(tree, (_, _) {});
    controller.publish('Latest work');
    await tester.pump();
    expect(controller.categoryReads, 0);
    expect(controller.treeReads, 0);
    expect(container.read(category).isLoading, isTrue);
    expect(container.read(tree).isLoading, isTrue);

    interaction.cancelInteraction(motion);
    await tester.pump();
    final state = await container.read(category.future);
    await container.read(tree.future);
    expect(state!.works.single.title, 'Latest work');
    expect(controller.categoryReads, 1);
    expect(controller.treeReads, 1);
    categorySubscription.close();
    treeSubscription.close();
    await tester.pump(const Duration(milliseconds: 1));
  });
}

class _PresentationController extends AsmrLibraryController {
  _PresentationController(TestAsmrServices services)
    : super(
        preferencesStore: services.preferencesStore,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: services.accountSyncService,
      );

  String title = 'Published work';
  int revision = 0;
  int categoryReads = 0;
  int treeReads = 0;
  bool hasMore = false;
  bool needsRetry = false;
  int workCount = 1;
  int loadMoreCount = 0;
  String lastSearchQuery = '';
  int initializations = 0;
  int categoryLoads = 0;
  int accountRestores = 0;
  bool cacheValid = true;
  AppLanguage _presentationLanguage = AppLanguage.zh;

  void publish(String value) {
    title = value;
    revision++;
    notifyListeners();
  }

  @override
  bool get initialized => true;

  @override
  bool hasLoadedCategory(AsmrCategoryType category) => cacheValid;

  @override
  AsmrLibraryGlobalViewState get globalViewState => AsmrLibraryGlobalViewState(
    initialized: true,
    visibleCategories: kDefaultVisibleAsmrCategories,
    contentLanguage: AsmrContentLanguage.zh,
    contentLanguagePreference: ContentLanguagePreference.followPage,
    revision: 0,
  );

  @override
  AsmrCategoryViewState categoryViewState(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) {
    categoryReads++;
    if (searchSession) lastSearchQuery = searchQuery;
    return AsmrCategoryViewState(
      category: category,
      works: [
        for (var i = 0; cacheValid && i < workCount; i++)
          AsmrWork.fromJson({
            'id': i + 1,
            'title': i == 0 ? title : '$title $i',
          }),
      ],
      isLoading: false,
      isLoadingMore: false,
      isRefreshing: false,
      isStale: false,
      hasAttemptedLoad: cacheValid,
      hasMore: hasMore,
      needsLoadMoreRetry: needsRetry,
      totalCount: workCount,
      activeQuery: searchQuery,
      lastError: null,
      operationError: null,
      revision: revision,
    );
  }

  @override
  AsmrTrackTreeViewState trackTreeViewState(int workId) {
    treeReads++;
    return super.trackTreeViewState(workId);
  }

  @override
  Future<void> initialize({AsmrContentLanguage? defaultLanguage}) async {
    initializations++;
  }

  @override
  AppLanguage get pageLanguage => _presentationLanguage;

  @override
  bool setPageLanguage(AppLanguage language) {
    _presentationLanguage = language;
    return false;
  }

  @override
  Future<void> ensureCategoryLoaded(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {
    categoryLoads++;
    if (!cacheValid) {
      cacheValid = true;
      notifyListeners();
    }
  }

  @override
  Future<void> loadMoreCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {
    loadMoreCount++;
    hasMore = false;
    revision++;
    notifyListeners();
  }

  @override
  Future<void> restoreAsmrAccountSession({bool force = false}) async {
    accountRestores++;
  }

  @override
  Future<void> syncAsmrAccount({bool force = false}) async {}
}
