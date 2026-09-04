import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/application/asmr_preferences.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_page.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_tab.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_work_detail_sheet.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_asmr_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
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
      final controller = _TestFavoritesAsmrLibraryController(<AsmrWork>[work]);
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
      final controller = _TestFavoritesAsmrLibraryController(<AsmrWork>[
        work1,
        work2,
      ]);
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
  _TestFavoritesAsmrLibraryController(List<AsmrWork> initialWorks)
      : favoriteWorks = List.of(initialWorks),
        super(
          preferencesStore: AsmrPreferencesStore(
            repository: SqliteAsmrRepository(database: AppDatabase.instance),
          ),
          persistenceRepository: SqliteAsmrRepository(
            database: AppDatabase.instance,
          ),
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
