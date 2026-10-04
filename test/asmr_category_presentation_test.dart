import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
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
            child: AsmrTab(activeTabIndexListenable: activeTab),
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
    controller.publish('Return work');
    interaction.beginInteraction(motion);
    activeTab.value = 0;
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Newest work'), findsOneWidget);
    expect(find.text('Return work'), findsNothing);
    interaction.cancelInteraction(motion);
    await pumpUntilFound(tester, find.text('Return work'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

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

  void publish(String value) {
    title = value;
    revision++;
    notifyListeners();
  }

  @override
  bool get initialized => true;

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
    return AsmrCategoryViewState(
      category: category,
      works: [
        AsmrWork.fromJson({'id': 1, 'title': title}),
      ],
      isLoading: false,
      isLoadingMore: false,
      isRefreshing: false,
      isStale: false,
      hasAttemptedLoad: true,
      hasMore: false,
      needsLoadMoreRetry: false,
      totalCount: 1,
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
  Future<void> initialize({AsmrContentLanguage? defaultLanguage}) async {}

  @override
  bool setPageLanguage(AppLanguage language) => false;

  @override
  Future<void> ensureCategoryLoaded(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {}

  @override
  Future<void> restoreAsmrAccountSession({bool force = false}) async {}

  @override
  Future<void> syncAsmrAccount({bool force = false}) async {}
}
