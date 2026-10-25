import '../domain/asmr_tag_interest.dart';
import 'dart:async';
import 'dart:io';

import '../domain/asmr_models.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/search_query_utils.dart';
import '../../../core/logging/app_log_service.dart';
import 'asmr_api_service.dart';
import 'asmr_recommendation_engine.dart';
import 'japanese_asmr_api_service.dart';
import '../domain/asmr_persistence_repository.dart';

part 'asmr_catalog_merge.dart';

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
  Map<String, double>? Function() circleWeights = () => null;
  Future<void> Function(List<MusicTrack>)? prepareTagInterests;
  Future<List<AsmrTag>> loadTagCatalog() => _apiService.fetchTagCatalog();
  Future<List<AsmrTag>> loadVoiceActorCatalog() =>
      _apiService.fetchVoiceActorCatalog();
  Future<List<AsmrTag>> loadCircleCatalog() => _apiService.fetchCircleCatalog();
  Future<AsmrSearchSuggestions> loadSearchSuggestions({
    AsmrRequestCancellationToken? cancellationToken,
  }) {
    final japaneseApiService = _japaneseApiService;
    if (japaneseApiService == null) {
      throw StateError('The Eara catalog client is not available.');
    }
    return japaneseApiService.fetchSearchSuggestions(
      cancellationToken: cancellationToken,
    );
  }

  Future<List<MusicTrack>> loadLocalTracksForInterests() =>
      _persistenceRepository.loadTracksForRecommendations();

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
    final localTracksFuture = (() async {
      final loading = _loadLocalTracks();
      final tracks = await (cancellationToken?.waitFor(loading) ?? loading);
      cancellationToken?.throwIfCancelled();
      // A failed read must not seed interests from an empty library.
      if (tracks != null) {
        final preparation = prepareTagInterests?.call(tracks);
        if (preparation != null) {
          await (cancellationToken?.waitFor(preparation) ?? preparation);
        }
      }
      return tracks ?? const <MusicTrack>[];
    })();
    final groups = await Future.wait([
      _loadRecommendationRequests(
        [
          for (final category in _recommendationSources)
            (category, searchQuery),
        ],
        language: language,
        token: token,
        refreshSeed: refreshSeed,
        cancellationToken: cancellationToken,
      ),
      (() async {
        await localTracksFuture;
        cancellationToken?.throwIfCancelled();
        // Interest recall must not broaden an explicit user search.
        if (searchQuery.isNotEmpty) return <_RecommendationPagesResult>[];
        final queries = <String>{};
        for (final weights in [
          tagWeights(),
          voiceActorWeights(),
          circleWeights(),
        ]) {
          final terms =
              (weights?.entries ?? const <MapEntry<String, double>>[])
                  .where(
                    (entry) =>
                        entry.value.isFinite &&
                        entry.value > 0 &&
                        entry.key.trim().isNotEmpty,
                  )
                  .toList()
                ..sort((a, b) {
                  final order = b.value.compareTo(a.value);
                  return order == 0 ? a.key.compareTo(b.key) : order;
                });
          if (terms.isEmpty) continue;
          queries.add(terms.first.key);
          // Keep the strongest interest and rotate the second across refreshes.
          if (terms.length > 1) {
            final offset = refreshSeed > 0 ? refreshSeed - 1 : 0;
            queries.add(terms[1 + offset % (terms.length - 1)].key);
          }
        }
        return _loadRecommendationRequests(
          [for (final query in queries) (AsmrCategoryType.release, query)],
          language: language,
          token: token,
          refreshSeed: refreshSeed,
          firstPageOnly: true,
          cancellationToken: cancellationToken,
        );
      })(),
    ]);
    final results = groups.expand((group) => group).toList(growable: false);
    cancellationToken?.throwIfCancelled();
    final candidates = <String, AsmrWork>{};
    final firstPageIds = <String>{};
    final explorationIds = <String>{};
    Object? firstError;
    int? sourceTotalCount;
    for (var resultIndex = 0; resultIndex < results.length; resultIndex++) {
      final result = results[resultIndex];
      firstError ??= result.error;
      for (var index = 0; index < result.pages.length; index++) {
        final page = result.pages[index];
        if (resultIndex < groups.first.length &&
            index == 0 &&
            page is AsmrMergedWorkPage) {
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
    final localTracks = await localTracksFuture;
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
        circleWeights: circleWeights(),
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

  Future<List<_RecommendationPagesResult>> _loadRecommendationRequests(
    List<(AsmrCategoryType, String)> requests, {
    required AsmrContentLanguage language,
    required String? token,
    required int refreshSeed,
    bool firstPageOnly = false,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    final results = <_RecommendationPagesResult>[];
    // Bound interest searches so large preference lists do not flood either site.
    for (var start = 0; start < requests.length; start += 4) {
      cancellationToken?.throwIfCancelled();
      results.addAll(
        await Future.wait(
          requests
              .skip(start)
              .take(4)
              .map(
                (request) => _loadRecommendationPagesSafely(
                  request.$1,
                  searchQuery: request.$2,
                  language: language,
                  token: token,
                  refreshSeed: refreshSeed,
                  firstPageOnly: firstPageOnly,
                  cancellationToken: cancellationToken,
                ),
              ),
        ),
      );
    }
    return results;
  }

  Future<_RecommendationPagesResult> _loadRecommendationPagesSafely(
    AsmrCategoryType category, {
    required String searchQuery,
    required AsmrContentLanguage language,
    required String? token,
    required int refreshSeed,
    bool firstPageOnly = false,
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
      if (!firstPageOnly && firstPage.hasMore) {
        final totalPages =
            (firstPage.totalCount + firstPage.pageSize - 1) ~/
            firstPage.pageSize;
        final nextPage =
            firstPage is AsmrMergedWorkPage ||
                searchQuery.isNotEmpty ||
                totalPages <= 1 ||
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
