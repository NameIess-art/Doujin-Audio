import '../domain/asmr_tag_interest.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

import '../domain/asmr_models.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/search_query_utils.dart';
import '../../../core/logging/app_log_service.dart';
import 'asmr_api_service.dart';
import 'asmr_recommendation_engine.dart';
import 'japanese_asmr_api_service.dart';
import '../domain/asmr_persistence_repository.dart';

part 'asmr_catalog_merge.dart';

List<AsmrWork> _rankDailyDiscovery(
  (List<AsmrWork>, int, Set<String>, Map<String, double>, Map<String, double>)
  input,
) => const AsmrRecommendationEngine().rankDaily(
  candidates: input.$1,
  daySeed: input.$2,
  previousWorkKeys: input.$3,
  tagWeights: input.$4,
  voiceActorWeights: input.$5,
  limit: 80,
);

class AsmrRemoteCatalogService {
  AsmrRemoteCatalogService({
    required AsmrApiService apiService,
    required AsmrPersistenceRepository persistenceRepository,
    JapaneseAsmrApiService? japaneseApiService,
    AsmrRecommendationEngine recommendationEngine =
        const AsmrRecommendationEngine(),
  }) : _apiService = apiService,
       _persistenceRepository = persistenceRepository,
       _japaneseApiService = japaneseApiService,
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
  final JapaneseAsmrApiService? _japaneseApiService;
  final AsmrPersistenceRepository _persistenceRepository;
  final AsmrRecommendationEngine _recommendationEngine;

  bool Function(AsmrWork) isWorkAllowed = (_) => true;
  Map<String, double>? Function() tagWeights = () => null;
  Map<String, double>? Function() voiceActorWeights = () => null;
  Future<void> Function(List<MusicTrack>)? prepareTagInterests;
  Future<List<AsmrTag>> loadTagCatalog() => _apiService.fetchTagCatalog();
  Future<List<AsmrTag>> loadVoiceActorCatalog() =>
      _apiService.fetchVoiceActorCatalog();
  Future<List<MusicTrack>> loadLocalTracksForInterests() =>
      _persistenceRepository.loadTracksForRecommendations();

  Future<List<AsmrWork>> loadDailyRecommendations({
    required AsmrContentLanguage language,
    required int daySeed,
    required Set<String> previousWorkKeys,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    final results = await Future.wait(
      _recommendationSources.map(
        (category) => _loadRecommendationPagesSafely(
          category,
          searchQuery: '',
          language: language,
          token: null,
          refreshSeed: daySeed,
          cancellationToken: cancellationToken,
        ),
      ),
    );
    cancellationToken?.throwIfCancelled();
    final candidates = <String, AsmrWork>{};
    Object? error;
    for (final result in results) {
      error ??= result.error;
      for (final page in result.pages) {
        for (final work in page.works) {
          candidates.update(
            work.workKey,
            (old) => old.mergedWith(work),
            ifAbsent: () => work,
          );
        }
      }
    }
    if (candidates.isEmpty && error != null) throw error;
    // Keep reserves in the daily cache so exclusions can refill the visible 20.
    final ranking = await compute(_rankDailyDiscovery, (
      candidates.values.where(isWorkAllowed).toList(growable: false),
      daySeed,
      previousWorkKeys,
      tagWeights() ?? const <String, double>{},
      voiceActorWeights() ?? const <String, double>{},
    ));
    cancellationToken?.throwIfCancelled();
    return ranking;
  }

  Future<AsmrWorkPage> loadPage(
    AsmrCategoryType category, {
    required String searchQuery,
    required int page,
    required AsmrContentLanguage language,
    required String? token,
    AsmrRequestCancellationToken? cancellationToken,
    AsmrCatalogCursor? cursor,
  }) {
    if (_japaneseApiService != null &&
        (category == AsmrCategoryType.collected ||
            category == AsmrCategoryType.release ||
            category == AsmrCategoryType.recommendation)) {
      return _loadMergedPage(
        category,
        searchQuery: searchQuery,
        page: page,
        language: language,
        token: token,
        cancellationToken: cancellationToken,
        cursor: cursor,
      );
    }
    return _loadOnePage(
      category,
      searchQuery: searchQuery,
      page: page,
      language: language,
      token: token,
      cancellationToken: cancellationToken,
    );
  }

  Future<AsmrWorkPage> _loadOnePage(
    AsmrCategoryType category, {
    required String searchQuery,
    required int page,
    required AsmrContentLanguage language,
    required String? token,
    AsmrRequestCancellationToken? cancellationToken,
  }) {
    cancellationToken?.throwIfCancelled();
    final spec = _sortSpecFor(category);
    final pageSize = _pageSizes[category] ?? 40;
    return _retryTransientLoad(
      category: category,
      page: page,
      cancellationToken: cancellationToken,
      load: () => searchQuery.isNotEmpty
          ? _apiService.searchWorks(
              keyword: normalizeSearchQuery(searchQuery),
              order: spec.order,
              sort: spec.sort,
              page: page,
              pageSize: pageSize,
              token: token,
              language: language,
              cancellationToken: cancellationToken,
            )
          : _apiService.fetchWorks(
              order: spec.order,
              sort: spec.sort,
              page: page,
              pageSize: pageSize,
              token: token,
              language: language,
              cancellationToken: cancellationToken,
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
    AsmrRequestCancellationToken? cancellationToken,
    void Function(AsmrPartialCatalogException?)? onPartialError,
    void Function(int?)? onSourceTotalCount,
  }) async {
    cancellationToken?.throwIfCancelled();
    final localTracksFuture = _loadLocalTracks();
    final results = await Future.wait(
      _recommendationSources.map(
        (category) => _loadRecommendationPagesSafely(
          category,
          searchQuery: searchQuery,
          language: language,
          token: token,
          refreshSeed: refreshSeed,
          cancellationToken: cancellationToken,
        ),
      ),
    );
    cancellationToken?.throwIfCancelled();
    final candidates = <String, AsmrWork>{};
    final firstPageIds = <String>{};
    final explorationIds = <String>{};
    Object? firstError;
    int? sourceTotalCount;
    for (final result in results) {
      firstError ??= result.error;
      for (var index = 0; index < result.pages.length; index++) {
        final page = result.pages[index];
        if (index == 0 && page is AsmrMergedWorkPage) {
          sourceTotalCount ??= page.sourceTotalCount;
        }
        for (final work in result.pages[index].works) {
          candidates.update(
            work.workKey,
            (old) => old.mergedWith(work),
            ifAbsent: () => work,
          );
          (index == 0 ? firstPageIds : explorationIds).add(work.workKey);
        }
      }
    }
    if (candidates.isEmpty && firstError != null) throw firstError;
    onSourceTotalCount?.call(sourceTotalCount);
    final failedSources = <AsmrCatalogSource>{
      for (final result in results)
        for (final page in result.pages.whereType<AsmrMergedWorkPage>())
          ...?page.partialError?.sources,
    };
    onPartialError?.call(
      failedSources.isEmpty ? null : AsmrPartialCatalogException(failedSources),
    );
    explorationIds.removeAll(firstPageIds);
    final promotedIds = searchQuery.isEmpty && refreshSeed > 1
        ? explorationIds
        : const <String>{};
    final candidateList = candidates.values
        .where(isWorkAllowed)
        .toList(growable: false);
    final loadedTracks =
        await (cancellationToken?.waitFor(localTracksFuture) ??
            localTracksFuture);
    cancellationToken?.throwIfCancelled();
    // A failed read must not permanently seed interests from an empty library.
    if (loadedTracks != null) {
      final preparation = prepareTagInterests?.call(loadedTracks);
      if (preparation != null) {
        await (cancellationToken?.waitFor(preparation) ?? preparation);
      }
    }
    cancellationToken?.throwIfCancelled();
    final localTracks = loadedTracks ?? const <MusicTrack>[];
    final ranking = AppLogService.measureAsync(
      'asmr_recommendation_rank',
      () => _recommendationEngine.rankAsync(
        candidates: candidateList,
        localTracks: localTracks,
        favoriteWorks: favoriteWorks,
        historyWorks: historyWorks,
        refreshSeed: refreshSeed,
        explorationWorkIds: promotedIds,
        tagWeights: tagWeights(),
        voiceActorWeights: voiceActorWeights(),
      ),
      details: <String, Object?>{
        'candidates': candidateList.length,
        'localTracks': localTracks.length,
        'favorites': favoriteWorks.length,
        'history': historyWorks.length,
        'backgroundIsolate': true,
      },
    );
    return await (cancellationToken?.waitFor(ranking) ?? ranking);
  }

  Future<List<AsmrTrackFile>> loadTrackTree(
    AsmrWork work, {
    required String? token,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    Object? firstError;
    for (final source in const [
      AsmrCatalogSource.asmrOne,
      AsmrCatalogSource.japaneseAsmr,
    ]) {
      cancellationToken?.throwIfCancelled();
      try {
        List<AsmrTrackFile> tree;
        if (source == AsmrCatalogSource.asmrOne) {
          final one = work.resourceFor(source);
          if (one == null) continue;
          tree = await _apiService.fetchTrackTree(
            one.id,
            token: token,
            cancellationToken: cancellationToken,
          );
          cancellationToken?.throwIfCancelled();
          if (tree.any((node) => node.hasBrowsableContent) &&
              _japaneseApiService != null &&
              work.workCode.isNotEmpty) {
            await _verifyOneMedia(tree, cancellationToken);
          }
        } else {
          final japanese = _japaneseApiService;
          if (japanese == null || work.workCode.isEmpty) continue;
          tree = await japanese.fetchTrackTree(
            work,
            cancellationToken: cancellationToken,
          );
        }
        cancellationToken?.throwIfCancelled();
        if (tree.any((node) => node.hasBrowsableContent)) return tree;
      } on AsmrRequestCancelled {
        rethrow;
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) throw firstError;
    return const [];
  }

  Future<void> _verifyOneMedia(
    List<AsmrTrackFile> tree,
    AsmrRequestCancellationToken? cancellationToken,
  ) async {
    AsmrTrackFile? firstAudio(Iterable<AsmrTrackFile> nodes) {
      for (final node in nodes) {
        if (node.isAudio) return node;
        final child = firstAudio(node.children);
        if (child != null) return child;
      }
      return null;
    }

    final node = firstAudio(tree);
    if (node == null) return;
    final candidates = <String>{
      if (node.streamUrl?.isNotEmpty == true) node.streamUrl!,
      if (node.downloadUrl?.isNotEmpty == true) node.downloadUrl!,
      if (AsmrApiService.isOfficialMediaUrl(node.streamUrl))
        ...AsmrApiService.mediaStreamUrlsForHash(node.hash),
    }.take(3);
    Object? firstError;
    for (final url in candidates) {
      try {
        await _apiService.verifyMediaStream(
          url,
          cancellationToken: cancellationToken,
        );
        return;
      } on AsmrRequestCancelled {
        rethrow;
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) throw firstError;
  }

  Future<_RecommendationPagesResult> _loadRecommendationPagesSafely(
    AsmrCategoryType category, {
    required String searchQuery,
    required AsmrContentLanguage language,
    required String? token,
    required int refreshSeed,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    final pages = <AsmrWorkPage>[];
    final cursor = AsmrCatalogCursor();
    try {
      final firstPage = await loadPage(
        category,
        searchQuery: searchQuery,
        page: 1,
        language: language,
        token: token,
        cancellationToken: cancellationToken,
        cursor: cursor,
      );
      cancellationToken?.throwIfCancelled();
      pages.add(firstPage);
      if (firstPage.hasMore) {
        final totalPages =
            (firstPage.totalCount + firstPage.pageSize - 1) ~/
            firstPage.pageSize;
        final nextPage =
            firstPage is AsmrMergedWorkPage ||
                searchQuery.isNotEmpty ||
                refreshSeed <= 1
            ? 2
            : 2 + (refreshSeed - 1) % (totalPages - 1);
        pages.add(
          await loadPage(
            category,
            searchQuery: searchQuery,
            page: nextPage,
            language: language,
            token: token,
            cancellationToken: cancellationToken,
            cursor: cursor,
          ),
        );
      }
      return _RecommendationPagesResult(pages: pages);
    } on AsmrRequestCancelled {
      rethrow;
    } catch (error, stackTrace) {
      AppLogService.error(
        'asmr_recommendation_candidate_load_failed category=${category.name}',
        error: error,
        stackTrace: stackTrace,
      );
      return _RecommendationPagesResult(pages: pages, error: error);
    }
  }

  Future<List<MusicTrack>?> _loadLocalTracks() async {
    try {
      return await loadLocalTracksForInterests();
    } catch (error, stackTrace) {
      AppLogService.error(
        'asmr_recommendation_local_tracks_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<AsmrWorkPage> _retryTransientLoad({
    required AsmrCategoryType category,
    required int page,
    required Future<AsmrWorkPage> Function() load,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    for (var attempt = 0; ; attempt++) {
      cancellationToken?.throwIfCancelled();
      try {
        final loading = load();
        final result = await (cancellationToken?.waitFor(loading) ?? loading);
        cancellationToken?.throwIfCancelled();
        return result;
      } catch (error, stackTrace) {
        cancellationToken?.throwIfCancelled();
        if (error is AsmrRequestCancelled) rethrow;
        if (attempt >= _retryDelays.length || !_isTransient(error)) rethrow;
        AppLogService.warning(
          'asmr_catalog_transient_retry category=${category.name} '
          'page=$page attempt=${attempt + 1}',
          error: error,
          stackTrace: stackTrace,
        );
        if (cancellationToken == null) {
          await Future<void>.delayed(_retryDelays[attempt]);
        } else {
          await cancellationToken.delay(_retryDelays[attempt]);
        }
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
