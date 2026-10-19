import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/immutable_collections.dart';
import '../../../core/media/search_query_utils.dart';
import '../domain/asmr_models.dart';
import 'asmr_library_view_state.dart';
import 'asmr_remote_catalog_service.dart';
import 'asmr_request_cancellation.dart';

typedef AsmrCategoryRequestContext = ({
  int authEpoch,
  String? token,
  int contentEpoch,
  AsmrContentLanguage language,
  String scope,
});
typedef _CategoryKey = ({
  String scope,
  AsmrCategoryType category,
  String query,
  int searchEpoch,
});
typedef _CategoryRequestKey = ({
  AsmrCategoryRequestContext context,
  int serial,
});

final class _CategoryState {
  List<AsmrWork>? works;
  List<AsmrWork>? localSource;
  Set<int> workIds = const <int>{};
  bool isLoading = false;
  bool isLoadingMore = false;
  int page = 1;
  int? totalCount;
  bool hasMore = false;
  bool needsLoadMoreRetry = false;
  String? query;
  int revision = 0;
  Object? error;
  int requestSerial = 0;
  Future<void>? refreshTask;
  Future<void>? loadMoreTask;
  AsmrRequestCancellationToken? cancellationToken;
  void invalidateRequest() {
    cancellationToken?.cancel();
    cancellationToken = null;
    requestSerial++;
    isLoading = false;
    isLoadingMore = false;
    needsLoadMoreRetry = false;
    refreshTask = null;
    loadMoreTask = null;
  }
}

/// Owns query snapshots and requests; account and language stay in the controller.
final class AsmrCategoryCatalog {
  AsmrCategoryCatalog({
    required AsmrRemoteCatalogService remoteCatalogService,
    required void Function() onChanged,
    required bool Function(AsmrCategoryRequestContext) isContextCurrent,
    required AsmrCategoryRequestContext Function() currentContext,
    required List<AsmrWork> Function(AsmrCategoryType) localWorks,
    required Set<int> Function() favoriteIds,
  }) : _remoteCatalogService = remoteCatalogService,
       _onChanged = onChanged,
       _isContextCurrent = isContextCurrent,
       _currentContext = currentContext,
       _localWorks = localWorks,
       _favoriteIds = favoriteIds;
  final AsmrRemoteCatalogService _remoteCatalogService;
  final void Function() _onChanged;
  final bool Function(AsmrCategoryRequestContext) _isContextCurrent;
  final AsmrCategoryRequestContext Function() _currentContext;
  final List<AsmrWork> Function(AsmrCategoryType) _localWorks;
  final Set<int> Function() _favoriteIds;
  final Map<_CategoryKey, _CategoryState> _categories = {};
  int _searchEpoch = 1;
  int get searchEpoch => _searchEpoch;
  String _searchQuery = '';
  AsmrCategoryType? _searchCategory;
  final Map<AsmrCategoryType, String> _lastQueries = {};
  final Map<AsmrCategoryType, String> _pendingAuthRefreshes = {};
  final Map<AsmrCategoryType, ({List<AsmrWork> works, List<String> text})>
  _localSearchText = {};
  _CategoryKey _key(
    AsmrCategoryType category,
    String query, [
    AsmrCategoryRequestContext? context,
    bool searchSession = false,
  ]) => (
    scope: (context ?? _currentContext()).scope,
    category: category,
    query: normalizeSearchQuery(query),
    // An empty search displays the same loaded pages as the root category.
    searchEpoch: searchSession && normalizeSearchQuery(query).isNotEmpty
        ? _searchEpoch
        : 0,
  );
  _CategoryState _state(
    AsmrCategoryType category, [
    String? query,
    bool searchSession = false,
  ]) {
    final effectiveQuery = normalizeSearchQuery(
      query ?? _lastQueries[category] ?? '',
    );
    // Offstage providers can read the previous keyword during invalidation.
    // Do not recreate discarded query entries while they unsubscribe.
    if (searchSession &&
        effectiveQuery.isNotEmpty &&
        effectiveQuery != _searchQuery) {
      return _CategoryState();
    }
    return _categories.putIfAbsent(
      _key(category, effectiveQuery, null, searchSession),
      _CategoryState.new,
    );
  }

  static bool isRemote(AsmrCategoryType category) =>
      category != AsmrCategoryType.favorites &&
      category != AsmrCategoryType.history;
  bool isLoading(AsmrCategoryType category) => _state(category).isLoading;
  bool hasLoaded(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) => _state(category, searchQuery, searchSession).works != null;
  bool hasAttemptedLoad(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) {
    final state = _state(category, searchQuery, searchSession);
    if (!isRemote(category) &&
        normalizeSearchQuery(searchQuery).isNotEmpty &&
        !identical(state.localSource, _localWorks(category))) {
      return state.isLoading;
    }
    return state.query != null || state.error != null || state.isLoading;
  }

  Future<void>? pendingRefresh(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) => _state(category, searchQuery, searchSession).refreshTask;
  bool isLoadingMore(AsmrCategoryType category) =>
      _state(category).isLoadingMore;
  bool hasMore(AsmrCategoryType category) => _state(category).hasMore;
  bool needsLoadMoreRetry(AsmrCategoryType category) =>
      _state(category).needsLoadMoreRetry;
  int totalCount(AsmrCategoryType category) =>
      _state(category).totalCount ?? worksFor(category).length;
  String activeQuery(AsmrCategoryType category) => _state(category).query ?? '';
  Object? errorFor(AsmrCategoryType category) => _state(category).error;

  AsmrCategoryViewState viewState(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) {
    final state = _state(category, searchQuery, searchSession);
    final works = filteredWorksFor(
      category,
      searchQuery: searchQuery,
      searchSession: searchSession,
    );
    return AsmrCategoryViewState(
      category: category,
      works: works,
      isLoading: state.isLoading,
      isLoadingMore: state.isLoadingMore,
      isRefreshing: state.isLoading && state.works != null,
      isStale: state.isLoading && state.works != null,
      hasAttemptedLoad: hasAttemptedLoad(
        category,
        searchQuery: searchQuery,
        searchSession: searchSession,
      ),
      hasMore: state.hasMore,
      needsLoadMoreRetry: state.needsLoadMoreRetry,
      totalCount: isRemote(category)
          ? state.totalCount ?? works.length
          : works.length,
      activeQuery: state.query ?? normalizeSearchQuery(searchQuery),
      lastError: state.error,
      operationError: state.error,
      revision: state.revision,
    );
  }

  List<AsmrWork> worksFor(AsmrCategoryType category) => isRemote(category)
      ? _state(category).works ?? const []
      : _localWorks(category);
  List<AsmrWork> filteredWorksFor(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) {
    if (isRemote(category)) {
      return _state(category, searchQuery, searchSession).works ?? const [];
    }
    final works = _localWorks(category);
    final query = normalizeSearchQuery(searchQuery);
    if (query.isEmpty) return works;
    final state = _state(category, query, searchSession);
    return identical(state.localSource, works)
        ? state.works ?? const []
        : const [];
  }

  void bumpRevision(AsmrCategoryType category) {
    if (!isRemote(category) &&
        !identical(_localSearchText[category]?.works, _localWorks(category))) {
      _localSearchText.remove(category);
    }
    for (final entry in _categories.entries) {
      if (entry.key.category != category) continue;
      final state = entry.value;
      state.revision++;
      if (!isRemote(category) && entry.key.query.isNotEmpty) {
        state.invalidateRequest();
        state.works = null;
        state.localSource = null;
        state.query = null;
        state.error = null;
        unawaited(_reloadLocalSearch(entry.key, state));
      }
    }
  }

  Future<void> _reloadLocalSearch(
    _CategoryKey key,
    _CategoryState state,
  ) async {
    // Let the account mutation finish publishing its new immutable snapshots.
    await Future<void>.value();
    if (!identical(_categories[key], state) ||
        key.scope != _currentContext().scope ||
        (key.searchEpoch != 0 &&
            !isSearchRequestCurrent(key.query, key.category))) {
      return;
    }
    await refresh(
      key.category,
      searchQuery: key.query,
      context: _currentContext(),
      searchSession: key.searchEpoch != 0,
    );
  }

  void setOperationError(AsmrCategoryType category, Object? error) {
    final state = _state(category);
    state.error = error;
    state.revision++;
    _onChanged();
  }

  void refreshLocalSearch() {
    final category = _searchCategory;
    if (category == null || isRemote(category) || _searchQuery.isEmpty) return;
    final state = _state(category, _searchQuery, true);
    final source = _localWorks(category);
    if (identical(state.localSource, source) && state.query != null) {
      return;
    }
    if (state.refreshTask != null && !identical(state.localSource, source)) {
      // A refresh for the previous snapshot will reject its result; cancel it
      // so refresh() can start preparing the replacement instead of joining it.
      state.invalidateRequest();
    }
    unawaited(
      _reloadLocalSearch(_key(category, _searchQuery, null, true), state),
    );
  }

  void updateLocalCounts() {
    for (final category in [
      AsmrCategoryType.favorites,
      AsmrCategoryType.history,
    ]) {
      _state(category).totalCount = _localWorks(category).length;
    }
  }

  void updateFavorites(Map<int, bool> favorites) {
    for (final entry in _categories.entries) {
      if (!isRemote(entry.key.category)) continue;
      final works = entry.value.works;
      if (works == null ||
          !works.any((work) => favorites.containsKey(work.id))) {
        continue;
      }
      entry.value.works = immutableList(
        works.map(
          (work) => favorites.containsKey(work.id)
              ? work.copyWith(isFavorite: favorites[work.id])
              : work,
        ),
      );
      entry.value.revision++;
    }
  }

  Map<AsmrCategoryType, String> get loadedRemoteQueries => {
    for (final entry in _categories.entries)
      if (entry.key.scope == _currentContext().scope &&
          entry.key.searchEpoch == 0 &&
          isRemote(entry.key.category) &&
          entry.value.query != null)
        entry.key.category: entry.key.query,
  };
  void invalidateForAuthChange() {
    for (final entry in _categories.entries) {
      if (entry.key.searchEpoch == 0 &&
          isRemote(entry.key.category) &&
          (entry.value.works != null || entry.value.isLoading)) {
        _pendingAuthRefreshes[entry.key.category] = entry.key.query;
      }
      entry.value.invalidateRequest();
      if (!isRemote(entry.key.category)) {
        entry.value.localSource = null;
        entry.value.works = null;
        entry.value.query = null;
      }
    }
    _lastQueries.clear();
  }

  Map<AsmrCategoryType, String> takePendingAuthRefreshes() {
    final pending = Map<AsmrCategoryType, String>.from(_pendingAuthRefreshes);
    _pendingAuthRefreshes.clear();
    return pending;
  }

  void invalidateForContentChange() {
    for (final entry in _categories.entries) {
      final state = entry.value;
      state.invalidateRequest();
      state.revision++;
      if (!isRemote(entry.key.category)) {
        state.localSource = null;
        state.works = null;
        state.query = null;
      }
    }
    _lastQueries.clear();
  }

  void cancelRequests() {
    for (final state in _categories.values) {
      state.invalidateRequest();
    }
  }

  void clearWorks() {
    cancelRequests();
    _categories.clear();
    _lastQueries.clear();
    _pendingAuthRefreshes.clear();
    _localSearchText.clear();
    refreshLocalSearch();
  }

  void clearSearchQueries() {
    _searchEpoch++;
    _searchQuery = '';
    _searchCategory = null;
    _categories.removeWhere((key, state) {
      if (key.searchEpoch == 0) return false;
      state.invalidateRequest();
      return true;
    });
  }

  void setSearchQuery(String query, AsmrCategoryType category) {
    final normalized = normalizeSearchQuery(query);
    final changed = normalized != _searchQuery || category != _searchCategory;
    if (!changed) return;
    var stateChanged = false;
    if (normalized != _searchQuery) {
      stateChanged = _categories.entries.any(
        (entry) =>
            entry.key.searchEpoch != 0 && entry.value.cancellationToken != null,
      );
      clearSearchQueries();
    }
    _searchQuery = normalized;
    _searchCategory = category;
    for (final entry in _categories.entries) {
      if (entry.key.searchEpoch != 0 &&
          entry.key.category != category &&
          entry.value.cancellationToken != null) {
        entry.value.invalidateRequest();
        stateChanged = true;
      }
    }
    // Query-dependent views subscribe to the new key themselves. Only broadcast
    // cancellation of live state; completed query eviction does not alter roots.
    if (stateChanged) _onChanged();
  }

  bool isSearchRequestCurrent(String query, AsmrCategoryType category) =>
      normalizeSearchQuery(query) == _searchQuery &&
      (_searchQuery.isEmpty || _searchCategory == category);

  bool _isCurrent(_CategoryKey key, _CategoryRequestKey request) =>
      _isContextCurrent(request.context) &&
      request.serial == _categories[key]?.requestSerial;

  Future<void> refresh(
    AsmrCategoryType category, {
    required String searchQuery,
    required AsmrCategoryRequestContext context,
    bool searchSession = false,
  }) async {
    final query = normalizeSearchQuery(searchQuery);
    if (searchSession && !isSearchRequestCurrent(query, category)) return;
    if (!searchSession) _lastQueries[category] = query;
    final cacheKey = _key(category, query, context, searchSession);
    final state = _categories.putIfAbsent(cacheKey, _CategoryState.new);
    final pagination = state.loadMoreTask;
    if (pagination != null) await pagination;
    if (!_isContextCurrent(context) ||
        (searchSession && !isSearchRequestCurrent(query, category)) ||
        (cacheKey.searchEpoch != 0 && cacheKey.searchEpoch != _searchEpoch)) {
      return;
    }
    if (state.refreshTask != null) return state.refreshTask;
    final request = (context: context, serial: ++state.requestSerial);
    final cancellationToken = AsmrRequestCancellationToken();
    state.cancellationToken = cancellationToken;
    late final Future<void> task;
    task = _refresh(cacheKey, state, request, cancellationToken).whenComplete(
      () {
        if (identical(state.refreshTask, task)) state.refreshTask = null;
        if (identical(state.cancellationToken, cancellationToken)) {
          state.cancellationToken = null;
        }
      },
    );
    state.refreshTask = task;
    await task;
  }

  Future<AsmrWorkPage> _fetch(
    _CategoryKey key,
    AsmrCategoryRequestContext context,
    int page,
    int serial,
    AsmrRequestCancellationToken cancellationToken,
  ) async {
    if (key.category == AsmrCategoryType.recommendation) {
      final ranked = await _remoteCatalogService.loadRecommendations(
        searchQuery: key.query,
        language: context.language,
        token: context.token,
        favoriteWorks: _localWorks(AsmrCategoryType.favorites),
        historyWorks: _localWorks(AsmrCategoryType.history),
        refreshSeed: serial,
        cancellationToken: cancellationToken,
      );
      return AsmrWorkPage(
        works: ranked,
        currentPage: 1,
        pageSize: ranked.length,
        totalCount: ranked.length,
      );
    }
    return _remoteCatalogService.loadPage(
      key.category,
      searchQuery: key.query,
      page: page,
      language: context.language,
      token: context.token,
      cancellationToken: cancellationToken,
    );
  }

  Future<void> _refresh(
    _CategoryKey cacheKey,
    _CategoryState state,
    _CategoryRequestKey request,
    AsmrRequestCancellationToken cancellationToken,
  ) async {
    state.isLoading = true;
    state.needsLoadMoreRetry = false;
    state.error = null;
    if (_isCurrent(cacheKey, request)) _onChanged();
    try {
      if (!_isCurrent(cacheKey, request)) return;
      if (!isRemote(cacheKey.category)) {
        final source = _localWorks(cacheKey.category);
        if (!identical(state.localSource, source)) state.works = null;
        state.localSource = source;
        if (cacheKey.query.isNotEmpty) {
          final searchable = _localSearchText[cacheKey.category];
          final prepared = await cancellationToken.waitFor(
            compute(_prepareLocalSearch, (
              works: source,
              text: identical(searchable?.works, source)
                  ? searchable!.text
                  : null,
              query: cacheKey.query,
            )),
          );
          if (!_isCurrent(cacheKey, request) ||
              !identical(source, _localWorks(cacheKey.category))) {
            return;
          }
          _localSearchText[cacheKey.category] = (
            works: source,
            text: prepared.text,
          );
          state.works = prepared.works;
        }
        state.query = cacheKey.query;
        state.hasMore = false;
        state.revision++;
        return;
      }
      final result = await _fetch(
        cacheKey,
        request.context,
        1,
        request.serial,
        cancellationToken,
      );
      if (!_isCurrent(cacheKey, request)) return;
      final prepared = await _preparePage(state, result, cancellationToken);
      if (!_isCurrent(cacheKey, request)) return;
      state.works = prepared.additions;
      state.workIds = prepared.ids;
      _applyPageResult(state, cacheKey.query, result);
      state.revision++;
      _onChanged();
    } on AsmrRequestCancelled {
      // Superseded searches are normal invalidation, not network failures.
    } catch (error) {
      if (_isCurrent(cacheKey, request)) state.error = error;
    } finally {
      if (_isCurrent(cacheKey, request)) {
        state.isLoading = false;
        _onChanged();
      }
    }
  }

  Future<void> loadMore(
    AsmrCategoryType category, {
    required String searchQuery,
    required AsmrCategoryRequestContext context,
    bool searchSession = false,
  }) async {
    if (searchSession && !isSearchRequestCurrent(searchQuery, category)) return;
    final state = _state(category, searchQuery, searchSession);
    final refresh = state.refreshTask;
    if (refresh != null) await refresh;
    if (!_isContextCurrent(context) ||
        (searchSession && !isSearchRequestCurrent(searchQuery, category)) ||
        (searchSession && !_categories.containsValue(state))) {
      return;
    }
    final existing = state.loadMoreTask;
    if (existing != null) return existing;
    late final Future<void> task;
    task =
        _loadMore(
          category,
          searchQuery: searchQuery,
          context: context,
          searchSession: searchSession,
        ).whenComplete(() {
          if (identical(state.loadMoreTask, task)) state.loadMoreTask = null;
        });
    state.loadMoreTask = task;
    await task;
  }

  Future<void> _loadMore(
    AsmrCategoryType category, {
    required String searchQuery,
    required AsmrCategoryRequestContext context,
    bool searchSession = false,
  }) async {
    final query = normalizeSearchQuery(searchQuery);
    if (searchSession && !isSearchRequestCurrent(query, category)) return;
    final state = _state(category, query, searchSession);
    final refreshTask = state.refreshTask;
    if (refreshTask != null) await refreshTask;
    if (!isRemote(category) ||
        (searchSession && !isSearchRequestCurrent(query, category)) ||
        category == AsmrCategoryType.recommendation ||
        state.isLoadingMore ||
        !_isContextCurrent(context)) {
      return;
    }
    if (state.works == null) {
      await refresh(
        category,
        searchQuery: query,
        context: context,
        searchSession: searchSession,
      );
      return;
    }
    if (!state.hasMore) return;
    final key = _key(category, query, context, searchSession);
    final request = (context: context, serial: ++state.requestSerial);
    final cancellationToken = AsmrRequestCancellationToken();
    state.cancellationToken = cancellationToken;
    state.isLoadingMore = true;
    state.needsLoadMoreRetry = false;
    state.error = null;
    _onChanged();
    try {
      final result = await _fetch(
        key,
        context,
        state.page + 1,
        request.serial,
        cancellationToken,
      );
      if (!_isCurrent(key, request)) return;
      final prepared = await _preparePage(
        state,
        result,
        cancellationToken,
        append: true,
      );
      if (!_isCurrent(key, request)) return;
      // Retain existing model identities and any favorites changed while the
      // worker prepared this page. Only the new page crosses the isolate back.
      state.works = immutableList([...state.works!, ...prepared.additions]);
      state.workIds = prepared.ids;
      state.revision++;
      _applyPageResult(state, query, result);
      state.needsLoadMoreRetry = prepared.additions.isEmpty && state.hasMore;
      _onChanged();
    } on AsmrRequestCancelled {
      // Retain completed pages so returning to this category can resume.
    } catch (error) {
      if (_isCurrent(key, request)) {
        state.error = error;
        state.needsLoadMoreRetry = true;
      }
    } finally {
      if (identical(state.cancellationToken, cancellationToken)) {
        state.cancellationToken = null;
      }
      if (_isCurrent(key, request)) {
        state.isLoadingMore = false;
        _onChanged();
      }
    }
  }

  Future<_PreparedCategoryPage> _preparePage(
    _CategoryState state,
    AsmrWorkPage page,
    AsmrRequestCancellationToken cancellationToken, {
    bool append = false,
  }) async {
    while (true) {
      cancellationToken.throwIfCancelled();
      final favorites = _favoriteIds();
      final prepared = await cancellationToken.waitFor(
        compute(_prepareCategoryPage, (
          existingIds: append ? state.workIds : const <int>{},
          incoming: page.works,
          favoriteIds: favorites,
        )),
      );
      cancellationToken.throwIfCancelled();
      if (identical(favorites, _favoriteIds())) return prepared;
    }
  }

  void _applyPageResult(
    _CategoryState state,
    String query,
    AsmrWorkPage result,
  ) {
    state.query = query;
    state.page = result.currentPage;
    state.totalCount = result.totalCount;
    state.hasMore =
        result.hasMore && (state.works?.length ?? 0) < result.totalCount;
  }
}

({List<AsmrWork> works, List<String> text}) _prepareLocalSearch(
  ({List<AsmrWork> works, List<String>? text, String query}) request,
) {
  final whitespace = RegExp(r'\s+');
  final text =
      request.text ??
      [
        for (final work in request.works)
          [
                work.title,
                work.circleName,
                work.rjCode,
                ...work.tags,
                ...work.voiceActors,
              ]
              .map(
                (value) =>
                    value.replaceAll(whitespace, ' ').trim().toLowerCase(),
              )
              .join('\n'),
      ];
  final terms = normalizedSearchTerms(request.query);
  return (
    works: immutableList([
      for (var i = 0; i < request.works.length; i++)
        if (terms.every(text[i].contains)) request.works[i],
    ]),
    text: text,
  );
}

typedef _PreparedCategoryPage = ({List<AsmrWork> additions, Set<int> ids});

_PreparedCategoryPage _prepareCategoryPage(
  ({Set<int> existingIds, List<AsmrWork> incoming, Set<int> favoriteIds})
  request,
) {
  final ids = <int>{...request.existingIds};
  final additions = <AsmrWork>[];
  for (final work in request.incoming) {
    if (!ids.add(work.id)) continue;
    final favorite = request.favoriteIds.contains(work.id);
    additions.add(
      work.isFavorite == favorite ? work : work.copyWith(isFavorite: favorite),
    );
  }
  return (additions: immutableList(additions), ids: immutableSet(ids));
}
