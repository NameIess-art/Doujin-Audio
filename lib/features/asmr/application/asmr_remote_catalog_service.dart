import '../domain/asmr_tag_interest.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:io';

import '../domain/asmr_models.dart';
import '../../../core/media/audio_detail.dart';
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
    DateTime Function()? now,
    Duration secondaryJapaneseTimeout = const Duration(seconds: 8),
  }) : _apiService = apiService,
       _persistenceRepository = persistenceRepository,
       _japaneseApiService = japaneseApiService,
       _recommendationEngine = recommendationEngine,
       _now = now ?? DateTime.now,
       _secondaryJapaneseTimeout = secondaryJapaneseTimeout;

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
  static const Duration _mediaHostHealthTtl = Duration(seconds: 60);
  static const Duration _japaneseCooldownDuration = Duration(seconds: 60);
  static const int _japaneseFailureThreshold = 2;
  static const int _recommendationMaxConcurrency = 4;

  final AsmrApiService _apiService;
  final JapaneseAsmrApiService? _japaneseApiService;
  final AsmrPersistenceRepository _persistenceRepository;
  final AsmrRecommendationEngine _recommendationEngine;
  final DateTime Function() _now;
  final Duration _secondaryJapaneseTimeout;
  final Map<String, ({bool healthy, DateTime expiresAt, Object? error})>
  _mediaHostHealth = {};
  int _japaneseConsecutiveFailures = 0;
  DateTime? _japaneseCooldownUntil;
  Object? _japaneseCooldownError;
  Future<List<MusicTrack>>? _localTracksRead;

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
  }) async {
    final japaneseApiService = _japaneseApiService;
    if (japaneseApiService == null) {
      throw StateError('The Eara catalog client is not available.');
    }
    final result = await japaneseApiService.fetchSearchSuggestions(
      cancellationToken: cancellationToken,
    );
    _recordJapaneseCatalogSuccess();
    return result;
  }

  Future<List<MusicTrack>> loadLocalTracksForInterests() {
    final pending = _localTracksRead;
    if (pending != null) return pending;
    late final Future<List<MusicTrack>> read;
    read =
        Future<List<MusicTrack>>.sync(
          _persistenceRepository.loadTracksForRecommendations,
        ).whenComplete(() {
          if (identical(_localTracksRead, read)) _localTracksRead = null;
        });
    return _localTracksRead = read;
  }

  void invalidateLocalTracksRead() => _localTracksRead = null;
  void clearMediaHostHealthCache() {
    _mediaHostHealth.clear();
    _recordJapaneseCatalogSuccess();
  }

  bool _isJapaneseHostFailure(Object error) {
    if (error is TimeoutException ||
        error is SocketException ||
        error is HandshakeException) {
      return true;
    }
    if (error is AsmrApiException) {
      return error.statusCode == HttpStatus.tooManyRequests ||
          error.statusCode >= 500;
    }
    return false;
  }

  Object? _activeJapaneseCooldownError() {
    final until = _japaneseCooldownUntil;
    if (until == null) return null;
    if (_now().isBefore(until)) {
      return _japaneseCooldownError ??
          TimeoutException('Japanese ASMR catalog is cooling down.');
    }
    _recordJapaneseCatalogSuccess();
    return null;
  }

  void _recordJapaneseCatalogSuccess() {
    _japaneseConsecutiveFailures = 0;
    _japaneseCooldownUntil = null;
    _japaneseCooldownError = null;
  }

  void _recordJapaneseCatalogFailure(Object error) {
    if (!_isJapaneseHostFailure(error)) return;
    _japaneseConsecutiveFailures += 1;
    if (_japaneseConsecutiveFailures >= _japaneseFailureThreshold) {
      _japaneseCooldownUntil = _now().add(_japaneseCooldownDuration);
      _japaneseCooldownError = error;
    }
  }

  Future<AsmrWorkPage> _loadSecondaryJapanesePage({
    required String query,
    required int page,
    required int pageSize,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    final cooldownError = _activeJapaneseCooldownError();
    if (cooldownError != null) throw cooldownError;
    final childToken = AsmrRequestCancellationToken();
    final removeParent = cancellationToken?.addListener(childToken.cancel);
    var timedOut = false;
    final timer = Timer(_secondaryJapaneseTimeout, () {
      timedOut = true;
      childToken.cancel();
    });
    try {
      final result = await childToken.waitFor(
        _japaneseApiService!.searchWorks(
          keyword: query,
          page: page,
          pageSize: pageSize,
          cancellationToken: childToken,
        ),
      );
      _recordJapaneseCatalogSuccess();
      return result;
    } on AsmrRequestCancelled {
      if (timedOut && cancellationToken?.isCancelled != true) {
        final error = TimeoutException(
          'Japanese ASMR catalog request timed out.',
          _secondaryJapaneseTimeout,
        );
        _recordJapaneseCatalogFailure(error);
        throw error;
      }
      rethrow;
    } catch (error) {
      _recordJapaneseCatalogFailure(error);
      rethrow;
    } finally {
      timer.cancel();
      removeParent?.call();
    }
  }

  Future<AsmrWorkPage> loadPage(
    AsmrCategoryType category, {
    required String searchQuery,
    required int page,
    required AsmrContentLanguage language,
    required String? token,
    AsmrRequestCancellationToken? cancellationToken,
    AsmrCatalogCursor? cursor,
    bool includeJapanese = true,
  }) {
    final branches = searchElementBranches(searchQuery);
    if (branches.length > 1 ||
        (includeJapanese && _usesJapaneseCatalog(category))) {
      return _loadMergedPage(
        category,
        queries: branches,
        page: page,
        language: language,
        token: token,
        cancellationToken: cancellationToken,
        cursor: cursor,
        includeJapanese: includeJapanese,
      );
    }
    return _loadOnePage(
      category,
      searchQuery: branches.single,
      page: page,
      language: language,
      token: token,
      cancellationToken: cancellationToken,
    );
  }

  bool _usesJapaneseCatalog(AsmrCategoryType category) =>
      _japaneseApiService != null &&
      (category == AsmrCategoryType.collected ||
          category == AsmrCategoryType.release ||
          category == AsmrCategoryType.recommendation);

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
              keyword: searchElementKeyword(searchQuery),
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
    final japanesePages = <(String, int, int), Future<AsmrWorkPage>>{};
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
    final searchBranches = searchElementBranches(searchQuery);
    final semaphore = _AsyncSemaphore(_recommendationMaxConcurrency);
    final groups = await Future.wait([
      _loadRecommendationRequests(
        [
          for (final category in _recommendationSources)
            for (final branch in searchBranches) (category, branch),
        ],
        language: language,
        token: token,
        refreshSeed: refreshSeed,
        japanesePages: japanesePages,
        semaphore: semaphore,
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
          [
            for (final query in queries)
              (AsmrCategoryType.release, legacySearchElements(query)),
          ],
          language: language,
          token: token,
          refreshSeed: refreshSeed,
          japanesePages: japanesePages,
          semaphore: semaphore,
          firstPageOnly: true,
          includeJapanese: false,
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
    onSourceTotalCount?.call(
      searchBranches.length == 1 ? sourceTotalCount : null,
    );
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

  Future<AsmrWork?> findWorkByRjCode(
    String value, {
    required AsmrContentLanguage language,
    required String? token,
  }) async {
    final code = AudioDetail.findRjCodeInText(value);
    if (code == null) return null;
    AsmrWork? exactMatch(AsmrWorkPage page) =>
        page.works.where((work) => work.rjCode == code).firstOrNull;

    Object? oneError;
    try {
      final work = exactMatch(
        await _apiService.searchWorks(
          keyword: code,
          order: 'release',
          sort: 'desc',
          pageSize: 20,
          language: language,
          token: token,
        ),
      );
      if (work != null) return work;
    } catch (error) {
      oneError = error;
    }
    final japanese = _japaneseApiService;
    if (japanese != null) {
      final page = await japanese.searchWorks(keyword: code, pageSize: 20);
      _recordJapaneseCatalogSuccess();
      final work = exactMatch(page);
      if (work != null) return work;
    }
    if (oneError != null) throw oneError;
    return null;
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
          _recordJapaneseCatalogSuccess();
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

  bool _isHostLevelMediaError(Object error) {
    if (error is AsmrApiException) {
      return error.statusCode != HttpStatus.notFound &&
          error.statusCode != HttpStatus.gone;
    }
    return true;
  }

  void _recordMediaHostHealth(String url, {required bool healthy, Object? error}) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return;
    if (!healthy && error != null && !_isHostLevelMediaError(error)) return;
    _mediaHostHealth[host] = (
      healthy: healthy,
      expiresAt: _now().add(_mediaHostHealthTtl),
      error: healthy ? null : error,
    );
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
    }.take(3).toList(growable: false);
    if (candidates.isEmpty) return;

    final now = _now();
    Object? cachedError;
    final toProbe = <String>[];
    for (final url in candidates) {
      final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
      final cached = host.isEmpty ? null : _mediaHostHealth[host];
      if (cached != null) {
        if (now.isBefore(cached.expiresAt)) {
          if (cached.healthy) return;
          cachedError ??= cached.error;
          continue;
        }
        _mediaHostHealth.remove(host);
      }
      toProbe.add(url);
    }
    if (toProbe.isEmpty) {
      if (cachedError != null) throw cachedError;
      return;
    }
    if (toProbe.length == 1) {
      final url = toProbe.single;
      try {
        await _apiService.verifyMediaStream(
          url,
          cancellationToken: cancellationToken,
        );
        _recordMediaHostHealth(url, healthy: true);
        return;
      } on AsmrRequestCancelled {
        rethrow;
      } catch (error) {
        _recordMediaHostHealth(url, healthy: false, error: error);
        rethrow;
      }
    }

    // Race all candidate hosts concurrently and cancel slower probes once
    // any candidate confirms media reachability.
    final childTokens = List<AsmrRequestCancellationToken>.generate(
      toProbe.length,
      (_) => AsmrRequestCancellationToken(),
      growable: false,
    );
    void cancelAllChildren() {
      for (final child in childTokens) {
        child.cancel();
      }
    }

    final removeParentListener = cancellationToken?.addListener(
      cancelAllChildren,
    );
    final winner = Completer<void>();
    Object? firstError = cachedError;
    var remaining = toProbe.length;
    try {
      for (var index = 0; index < toProbe.length; index++) {
        final url = toProbe[index];
        final childToken = childTokens[index];
        unawaited(() async {
          try {
            await _apiService.verifyMediaStream(
              url,
              cancellationToken: childToken,
            );
            _recordMediaHostHealth(url, healthy: true);
            if (!winner.isCompleted) {
              winner.complete();
              cancelAllChildren();
            }
          } on AsmrRequestCancelled {
            if (cancellationToken?.isCancelled == true && !winner.isCompleted) {
              cancelAllChildren();
              winner.completeError(const AsmrRequestCancelled());
            }
          } catch (error) {
            _recordMediaHostHealth(url, healthy: false, error: error);
            firstError ??= error;
          } finally {
            remaining--;
            if (remaining == 0 && !winner.isCompleted) {
              if (cancellationToken?.isCancelled == true) {
                winner.completeError(const AsmrRequestCancelled());
              } else if (firstError != null) {
                winner.completeError(firstError!);
              } else {
                winner.complete();
              }
            }
          }
        }());
      }
      await winner.future;
    } finally {
      removeParentListener?.call();
      cancelAllChildren();
    }
  }

  Future<List<_RecommendationPagesResult>> _loadRecommendationRequests(
    List<(AsmrCategoryType, String)> requests, {
    required AsmrContentLanguage language,
    required String? token,
    required int refreshSeed,
    required Map<(String, int, int), Future<AsmrWorkPage>> japanesePages,
    required _AsyncSemaphore semaphore,
    bool firstPageOnly = false,
    bool includeJapanese = true,
    AsmrRequestCancellationToken? cancellationToken,
  }) {
    // Share one concurrency bound across base sources and interest recall so
    // recommendation refreshes do not create a connection storm.
    return Future.wait(
      requests.map(
        (request) => semaphore.run(
          () => _loadRecommendationPagesSafely(
            request.$1,
            searchQuery: request.$2,
            language: language,
            token: token,
            refreshSeed: refreshSeed,
            japanesePages: japanesePages,
            firstPageOnly: firstPageOnly,
            includeJapanese: includeJapanese,
            cancellationToken: cancellationToken,
          ),
          cancellationToken: cancellationToken,
        ),
      ),
    );
  }

  Future<_RecommendationPagesResult> _loadRecommendationPagesSafely(
    AsmrCategoryType category, {
    required String searchQuery,
    required AsmrContentLanguage language,
    required String? token,
    required int refreshSeed,
    required Map<(String, int, int), Future<AsmrWorkPage>> japanesePages,
    bool firstPageOnly = false,
    bool includeJapanese = true,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    final pages = <AsmrWorkPage>[];
    final cursor = AsmrCatalogCursor().._japanesePages = japanesePages;
    try {
      final firstPage = await loadPage(
        category,
        searchQuery: searchQuery,
        page: 1,
        language: language,
        token: token,
        cancellationToken: cancellationToken,
        cursor: cursor,
        includeJapanese: includeJapanese,
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
            includeJapanese: includeJapanese,
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

class _AsyncSemaphore {
  _AsyncSemaphore(this._maxConcurrent);

  final int _maxConcurrent;
  int _active = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<T> run<T>(
    Future<T> Function() action, {
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    if (_active >= _maxConcurrent) {
      final waiter = Completer<void>();
      _waiters.addLast(waiter);
      try {
        await (cancellationToken?.waitFor(waiter.future) ?? waiter.future);
      } catch (_) {
        if (!_waiters.remove(waiter)) {
          _release();
        }
        rethrow;
      }
    } else {
      _active++;
    }
    try {
      cancellationToken?.throwIfCancelled();
      return await action();
    } finally {
      _release();
    }
  }

  void _release() {
    while (_waiters.isNotEmpty) {
      final next = _waiters.removeFirst();
      if (!next.isCompleted) {
        next.complete();
        return;
      }
    }
    _active--;
  }
}
