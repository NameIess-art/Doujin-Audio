import 'dart:async';
import 'dart:io';

import '../domain/asmr_models.dart';
import '../../../core/media/music_track.dart';
import '../../../core/logging/app_log_service.dart';
import 'asmr_api_service.dart';
import 'asmr_recommendation_engine.dart';
import '../domain/asmr_persistence_repository.dart';

class AsmrRemoteCatalogService {
  AsmrRemoteCatalogService({
    required AsmrApiService apiService,
    required AsmrPersistenceRepository persistenceRepository,
    AsmrRecommendationEngine recommendationEngine =
        const AsmrRecommendationEngine(),
  }) : _apiService = apiService,
       _persistenceRepository = persistenceRepository,
       _recommendationEngine = recommendationEngine;

  static const Map<AsmrCategoryType, int> _pageSizes = <AsmrCategoryType, int>{
    AsmrCategoryType.collected: 40,
    AsmrCategoryType.recommendation: 40,
    AsmrCategoryType.sales: 40,
    AsmrCategoryType.rating: 40,
    AsmrCategoryType.reviews: 40,
    AsmrCategoryType.release: 40,
    AsmrCategoryType.favorites: 60,
    AsmrCategoryType.history: 60,
  };
  static const List<AsmrCategoryType> _recommendationSources =
      <AsmrCategoryType>[
        AsmrCategoryType.collected,
        AsmrCategoryType.sales,
        AsmrCategoryType.rating,
        AsmrCategoryType.release,
      ];
  static const List<Duration> _retryDelays = <Duration>[
    Duration(milliseconds: 350),
    Duration(milliseconds: 900),
  ];

  final AsmrApiService _apiService;
  final AsmrPersistenceRepository _persistenceRepository;
  final AsmrRecommendationEngine _recommendationEngine;

  Future<AsmrWorkPage> loadPage(
    AsmrCategoryType category, {
    required String searchQuery,
    required int page,
    required AsmrContentLanguage language,
    required String? token,
  }) {
    final spec = _sortSpecFor(category);
    final pageSize = _pageSizes[category] ?? 40;
    return _retryTransientLoad(
      category: category,
      page: page,
      load: () => searchQuery.isNotEmpty
          ? _apiService.searchWorks(
              keyword: searchQuery,
              order: spec.order,
              sort: spec.sort,
              page: page,
              pageSize: pageSize,
              token: token,
              language: language,
            )
          : _apiService.fetchWorks(
              order: spec.order,
              sort: spec.sort,
              page: page,
              pageSize: pageSize,
              token: token,
              language: language,
            ),
    );
  }

  Future<List<AsmrWork>> loadRecommendations({
    required String searchQuery,
    required AsmrContentLanguage language,
    required String? token,
    required List<AsmrWork> favoriteWorks,
    required List<AsmrWork> historyWorks,
    required int refreshSeed,
  }) async {
    final localTracksFuture = _loadLocalTracks();
    final results = await Future.wait(
      _recommendationSources.map(
        (category) => _loadRecommendationPagesSafely(
          category,
          searchQuery: searchQuery,
          language: language,
          token: token,
          refreshSeed: refreshSeed,
        ),
      ),
    );
    final candidates = <int, AsmrWork>{};
    final firstPageIds = <int>{};
    final explorationIds = <int>{};
    Object? firstError;
    for (final result in results) {
      firstError ??= result.error;
      for (var index = 0; index < result.pages.length; index++) {
        for (final work in result.pages[index].works) {
          candidates.putIfAbsent(work.id, () => work);
          (index == 0 ? firstPageIds : explorationIds).add(work.id);
        }
      }
    }
    if (candidates.isEmpty && firstError != null) throw firstError;
    explorationIds.removeAll(firstPageIds);
    final promotedIds = searchQuery.isEmpty && refreshSeed > 1
        ? explorationIds
        : const <int>{};
    final candidateList = candidates.values.toList(growable: false);
    final localTracks = await localTracksFuture;
    final request = AsmrRecommendationRankRequest(
      candidates: candidateList,
      localTracks: localTracks,
      favoriteWorks: favoriteWorks,
      historyWorks: historyWorks,
      refreshSeed: refreshSeed,
      limit: null,
      explorationWorkIds: promotedIds,
    );
    return AppLogService.measureAsync(
      'asmr_recommendation_rank',
      () => _recommendationEngine.rankAsync(
        candidates: candidateList,
        localTracks: localTracks,
        favoriteWorks: favoriteWorks,
        historyWorks: historyWorks,
        refreshSeed: refreshSeed,
        explorationWorkIds: promotedIds,
      ),
      details: <String, Object?>{
        'candidates': candidateList.length,
        'localTracks': localTracks.length,
        'favorites': favoriteWorks.length,
        'history': historyWorks.length,
        'backgroundIsolate': _recommendationEngine.usesBackgroundIsolate(
          request,
        ),
      },
    );
  }

  Future<AsmrWorkDetail> loadWorkDetail(
    int workId, {
    required AsmrContentLanguage language,
    required String? token,
  }) {
    return _apiService.fetchWorkDetail(
      workId,
      token: token,
      language: language,
    );
  }

  Future<List<AsmrTrackFile>> loadTrackTree(
    int workId, {
    required String? token,
  }) {
    return _apiService.fetchTrackTree(workId, token: token);
  }

  Future<_RecommendationPagesResult> _loadRecommendationPagesSafely(
    AsmrCategoryType category, {
    required String searchQuery,
    required AsmrContentLanguage language,
    required String? token,
    required int refreshSeed,
  }) async {
    final pages = <AsmrWorkPage>[];
    try {
      final firstPage = await loadPage(
        category,
        searchQuery: searchQuery,
        page: 1,
        language: language,
        token: token,
      );
      pages.add(firstPage);
      if (firstPage.hasMore) {
        final totalPages =
            (firstPage.totalCount + firstPage.pageSize - 1) ~/
            firstPage.pageSize;
        final nextPage = searchQuery.isNotEmpty || refreshSeed <= 1
            ? 2
            : 2 + (refreshSeed - 1) % (totalPages - 1);
        pages.add(
          await loadPage(
            category,
            searchQuery: searchQuery,
            page: nextPage,
            language: language,
            token: token,
          ),
        );
      }
      return _RecommendationPagesResult(pages: pages);
    } catch (error, stackTrace) {
      AppLogService.error(
        'asmr_recommendation_candidate_load_failed category=${category.name}',
        error: error,
        stackTrace: stackTrace,
      );
      return _RecommendationPagesResult(pages: pages, error: error);
    }
  }

  Future<List<MusicTrack>> _loadLocalTracks() async {
    try {
      return await _persistenceRepository.loadTracksForRecommendations();
    } catch (error, stackTrace) {
      AppLogService.error(
        'asmr_recommendation_local_tracks_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return const <MusicTrack>[];
    }
  }

  Future<AsmrWorkPage> _retryTransientLoad({
    required AsmrCategoryType category,
    required int page,
    required Future<AsmrWorkPage> Function() load,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await load();
      } catch (error, stackTrace) {
        if (attempt >= _retryDelays.length || !_isTransient(error)) rethrow;
        AppLogService.warning(
          'asmr_catalog_transient_retry category=${category.name} '
          'page=$page attempt=${attempt + 1}',
          error: error,
          stackTrace: stackTrace,
        );
        await Future<void>.delayed(_retryDelays[attempt]);
      }
    }
  }

  bool _isTransient(Object error) {
    if (error is HandshakeException ||
        error is SocketException ||
        error is TimeoutException) {
      return true;
    }
    if (error is AsmrApiException) {
      return error.statusCode == HttpStatus.tooManyRequests ||
          error.statusCode >= 500;
    }
    return false;
  }

  ({String order, String sort}) _sortSpecFor(AsmrCategoryType category) {
    return switch (category) {
      AsmrCategoryType.collected ||
      AsmrCategoryType.recommendation => (order: 'create_date', sort: 'desc'),
      AsmrCategoryType.sales => (order: 'dl_count', sort: 'desc'),
      AsmrCategoryType.rating => (order: 'rate_average_2dp', sort: 'desc'),
      AsmrCategoryType.reviews => (order: 'review_count', sort: 'desc'),
      AsmrCategoryType.release ||
      AsmrCategoryType.favorites ||
      AsmrCategoryType.history => (order: 'release', sort: 'desc'),
    };
  }
}

class _RecommendationPagesResult {
  _RecommendationPagesResult({List<AsmrWorkPage> pages = const [], this.error})
    : pages = List<AsmrWorkPage>.unmodifiable(pages);

  final List<AsmrWorkPage> pages;
  final Object? error;
}
