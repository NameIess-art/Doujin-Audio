import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'support/asmr_controller_test_fixture.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/core/immutable_collections.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_page.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_tab.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_work_detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  testWidgets('Windows metadata copies with right click only', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(fixture.build(Builder(builder: (context) => TextButton(
      onPressed: () => showAsmrWorkDetailSheet(context, _work()),
      child: const Text('Open detail'),
    ))));
    await tester.tap(find.text('Open detail'));
    await tester.pumpAndSettle();
    final text = find.text('Test circle');
    await tester.ensureVisible(text);
    await tester.longPress(text);
    expect(copied, isEmpty);
    final click = await tester.startGesture(tester.getCenter(text), kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await click.up();
    await tester.pumpAndSettle();
    expect(copied, ['Test circle']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  setUp(UiInteractionCoordinator.instance.resetForTest);
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  for (final count in <int>[100, 1000, 5000]) {
    testWidgets('selection reuses visible rows for $count ASMR works', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await fixture.languageProvider.setLanguage(AppLanguage.zh);
      final controller = _TestFavoritesAsmrLibraryController(
        createTestAsmrServices(),
        const [],
      );
      controller.favoriteWorks = immutableList(
        List.generate(count, (index) => _work(id: index, title: 'Work $index')),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        fixture.build(
          const AsmrTab(),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Work 0'));
      await tester.pumpAndSettle();

      final dynamic listState = tester.state(
        find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_AsmrCategoryList',
        ),
      );
      final Object cachedRows = listState.visibleItemsCache as Object;
      await tester.tap(find.text('Work 1'));
      await tester.pumpAndSettle();
      expect(identical(listState.visibleItemsCache, cachedRows), isTrue);
      expect(find.text('Work 0'), findsOneWidget);
      expect(find.text('Work 1'), findsOneWidget);
      expect(find.text('Work ${count - 1}'), findsNothing);

      controller.updateFavorites(<AsmrWork>[
        _work(id: count, title: 'New work'),
      ]);
      await tester.pumpAndSettle();
      expect(identical(listState.visibleItemsCache, cachedRows), isFalse);
      expect(find.text('New work'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('detail download button opens the work download page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    await fixture.languageProvider.setLanguage(AppLanguage.en);
    final work = _work();

    await tester.pumpWidget(
      fixture.build(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAsmrWorkDetailSheet(context, work),
            child: const Text('Open detail'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open detail'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('asmr_work_detail_download')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AsmrDownloadPage), findsOneWidget);
    expect(find.byType(TopPageHeader), findsOneWidget);
    expect(find.byType(HeaderFloatingSurface), findsWidgets);
    expect(
      tester.widget<AsmrDownloadPage>(find.byType(AsmrDownloadPage)).work.id,
      work.id,
    );
    expect(find.text('Work details'), findsNothing);
    expect(find.textContaining('/'), findsNothing);
  });

  testWidgets('download page shows batch progress when multiple works are being downloaded', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    await fixture.languageProvider.setLanguage(AppLanguage.zh);
    final work = _work();

    await tester.pumpWidget(
      fixture.build(
        AsmrDownloadPage(
          work: work,
          batchIndex: 2,
          batchTotal: 5,
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AsmrDownloadPage), findsOneWidget);
    expect(find.text('2/5'), findsOneWidget);
  });

  testWidgets(
    'detail sheet shows favorite button to the left of download button and allows undoing unfavorite',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await fixture.languageProvider.setLanguage(AppLanguage.zh);

      final work = _work();
      final controller = _TestFavoritesAsmrLibraryController(
        createTestAsmrServices(),
        <AsmrWork>[work],
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        fixture.build(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showAsmrWorkDetailSheet(context, work),
              child: const Text('Open detail'),
            ),
          ),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
          ],
        ),
      );
      await tester.tap(find.text('Open detail'));
      await tester.pumpAndSettle();

      final favoriteButtonFinder = find.byKey(
        const ValueKey<String>('asmr_work_detail_favorite'),
      );
      final downloadButtonFinder = find.byKey(
        const ValueKey<String>('asmr_work_detail_download'),
      );

      expect(favoriteButtonFinder, findsOneWidget);
      expect(downloadButtonFinder, findsOneWidget);

      final favoriteRight = tester.getTopRight(favoriteButtonFinder).dx;
      final downloadLeft = tester.getTopLeft(downloadButtonFinder).dx;
      expect(favoriteRight, lessThanOrEqualTo(downloadLeft));

      expect(controller.isFavorite(work.id), isTrue);

      await tester.tap(favoriteButtonFinder);
      await tester.pump();

      expect(controller.isFavorite(work.id), isFalse);

      expect(find.text('已取消收藏。'), findsOneWidget);
      final undoButtonFinder = find.text('撤销 (5s)');
      expect(undoButtonFinder, findsOneWidget);

      await tester.tap(undoButtonFinder);
      await tester.pump();

      expect(controller.isFavorite(work.id), isTrue);
    },
  );

  testWidgets(
    'unfavoriting a work in favorites category animates card collapse and shifts items below upward',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await fixture.languageProvider.setLanguage(AppLanguage.zh);

      final work1 = _work(id: 101, title: 'First Favorite Work');
      final work2 = _work(id: 102, title: 'Second Favorite Work');
      final controller = _TestFavoritesAsmrLibraryController(
        createTestAsmrServices(),
        <AsmrWork>[work1, work2],
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        fixture.build(
          const AsmrTab(),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();

      expect(find.text('First Favorite Work'), findsOneWidget);
      expect(find.text('Second Favorite Work'), findsOneWidget);

      final work2InitialTop =
          tester.getTopLeft(find.text('Second Favorite Work')).dy;

      controller.updateFavorites(<AsmrWork>[work2]);
      await tester.pump();

      expect(find.text('First Favorite Work'), findsOneWidget);
      expect(find.text('Second Favorite Work'), findsOneWidget);

      final sizeTransitionFinder = find.ancestor(
        of: find.byKey(const ValueKey<String>('asmr-work-101')),
        matching: find.byType(SizeTransition),
      );
      expect(sizeTransitionFinder, findsOneWidget);
      final sizeTransition =
          tester.widget<SizeTransition>(sizeTransitionFinder);
      expect(sizeTransition.sizeFactor.value, 1.0);

      await tester.pump(const Duration(milliseconds: 130));
      expect(sizeTransition.sizeFactor.value, lessThan(1.0));
      expect(sizeTransition.sizeFactor.value, greaterThan(0.0));

      final work2MidTop =
          tester.getTopLeft(find.text('Second Favorite Work')).dy;
      expect(work2MidTop, lessThan(work2InitialTop));

      await tester.pumpAndSettle();

      expect(find.text('First Favorite Work'), findsNothing);
      expect(find.text('Second Favorite Work'), findsOneWidget);

      final work2FinalTop =
          tester.getTopLeft(find.text('Second Favorite Work')).dy;
      expect(work2FinalTop, lessThan(work2MidTop));
    },
  );
}

class _TestFavoritesAsmrLibraryController extends AsmrLibraryController {
  _TestFavoritesAsmrLibraryController(
    TestAsmrServices services,
    List<AsmrWork> initialWorks,
  ) : favoriteWorks = List.of(initialWorks),
      super(
        preferencesStore: services.preferencesStore,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: services.accountSyncService,
      );

  List<AsmrWork> favoriteWorks;
  int _revision = 0;

  void updateFavorites(List<AsmrWork> next) {
    favoriteWorks = List.of(next);
    _revision++;
    notifyListeners();
  }

  @override
  bool isFavorite(int workId) => favoriteWorks.any((w) => w.id == workId);

  @override
  Future<void> toggleFavorite(AsmrWork work) async {
    final contains = favoriteWorks.any((w) => w.id == work.id);
    if (contains) {
      favoriteWorks.removeWhere((w) => w.id == work.id);
    } else {
      favoriteWorks.add(work.copyWith(isFavorite: true));
    }
    _revision++;
    notifyListeners();
  }

  @override
  Future<AsmrWorkDetail> loadWorkDetail(AsmrWork work) async {
    return AsmrWorkDetail(
      work: work,
      description: 'Test description',
      ageCategory: 'general',
      languageEditionLabels: const <String>[],
      userRating: null,
    );
  }

  @override
  Future<void> initialize({AsmrContentLanguage? defaultLanguage}) async {}

  @override
  Future<void> refreshCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) async {}

  @override
  Future<void> restoreAsmrAccountSession({bool force = false}) async {}

  @override
  AsmrLibraryGlobalViewState get globalViewState => AsmrLibraryGlobalViewState(
    initialized: true,
    visibleCategories: kDefaultVisibleAsmrCategories,
    contentLanguage: AsmrContentLanguage.zh,
    contentLanguagePreference: ContentLanguagePreference.followPage,
    revision: _revision,
  );

  @override
  List<AsmrWork> worksFor(AsmrCategoryType category) =>
      category == AsmrCategoryType.favorites
          ? favoriteWorks
          : const <AsmrWork>[];

  @override
  int totalCountFor(AsmrCategoryType category) => worksFor(category).length;

  @override
  String activeQueryFor(AsmrCategoryType category) => '';

  @override
  AsmrCategoryViewState categoryViewState(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) {
    final works = worksFor(category);
    return AsmrCategoryViewState(
      category: category,
      works: works,
      isLoading: false,
      isLoadingMore: false,
      isRefreshing: false,
      isStale: false,
      hasAttemptedLoad: true,
      hasMore: false,
      needsLoadMoreRetry: false,
      totalCount: works.length,
      activeQuery: searchQuery,
      lastError: null,
      operationError: null,
      revision: _revision,
    );
  }
}

AsmrWork _work({int id = 123, String title = 'Test work'}) => AsmrWork(
  id: id,
  title: title,
  circleName: 'Test circle',
  sourceId: 'RJ000$id',
  sourceType: 'asmr',
  sourceUrl: '',
  coverUrl: '',
  thumbnailUrl: '',
  mainCoverUrl: '',
  releaseDate: null,
  createDate: null,
  duration: Duration.zero,
  dlCount: 0,
  reviewCount: 0,
  rating: 0,
  voiceActors: const <String>[],
  tags: const <String>[],
  isFavorite: true,
);
