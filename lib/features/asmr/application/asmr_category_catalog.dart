import 'dart:collection';
import 'dart:convert';

import '../../../core/immutable_collections.dart';
import '../../../core/media/search_query_utils.dart';
import '../domain/asmr_models.dart';
import 'asmr_library_view_state.dart';
import 'asmr_remote_catalog_service.dart';

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
});
typedef _CategoryRequestKey = ({
  AsmrCategoryRequestContext context,
  int serial,
});
typedef _FilteredWorksKey = ({
  AsmrCategoryType category,
  String query,
  int revision,
});

final class _CategoryState {
  List<AsmrWork>? works;
  List<AsmrWork>? pendingWorks;
  AsmrWorkPage? pendingPage;
  List<int> firstPageIds = const [];
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
  void invalidateRequest() {
    requestSerial++;
    isLoading = false;
    isLoadingMore = false;
    needsLoadMoreRetry = false;
    refreshTask = null;
    loadMoreTask = null;
    pendingWorks = null;
    pendingPage = null;
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
    required AsmrWork Function(AsmrWork) decorateWork,
    required void Function(String, String, Map<String, Object?>) persist,
  }) : _remoteCatalogService = remoteCatalogService,
       _onChanged = onChanged,
       _isContextCurrent = isContextCurrent,
       _currentContext = currentContext,
       _localWorks = localWorks,
       _decorateWork = decorateWork,
       _persist = persist;
  final AsmrRemoteCatalogService _remoteCatalogService;
  final void Function() _onChanged;
  final bool Function(AsmrCategoryRequestContext) _isContextCurrent;
  final AsmrCategoryRequestContext Function() _currentContext;
  final List<AsmrWork> Function(AsmrCategoryType) _localWorks;
  final AsmrWork Function(AsmrWork) _decorateWork;
  final void Function(String, String, Map<String, Object?>) _persist;
  final Map<_CategoryKey, _CategoryState> _categories = {};
  final Map<AsmrCategoryType, String> _lastQueries = {};
  final Map<AsmrCategoryType, String> _pendingAuthRefreshes = {};
  final LinkedHashMap<_FilteredWorksKey, List<AsmrWork>> _filteredWorksCache =
      LinkedHashMap();
  _CategoryKey _key(
    AsmrCategoryType category,
    String query, [
    AsmrCategoryRequestContext? context,
  ]) => (
    scope: (context ?? _currentContext()).scope,
    category: category,
    query: normalizeSearchQuery(query),
  );
  _CategoryState _state(AsmrCategoryType category, [String? query]) =>
      _categories.putIfAbsent(
        _key(category, query ?? _lastQueries[category] ?? ''),
        _CategoryState.new,
      );
  static bool isRemote(AsmrCategoryType category) =>
      category != AsmrCategoryType.favorites &&
      category != AsmrCategoryType.history;
  bool isLoading(AsmrCategoryType category) => _state(category).isLoading;
  bool hasLoaded(AsmrCategoryType category, {String searchQuery = ''}) =>
      _state(category, searchQuery).works != null;
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
  }) {
    final state = _state(category, searchQuery);
    final works = filteredWorksFor(category, searchQuery: searchQuery);
    return AsmrCategoryViewState(
      category: category,
      works: works,
      isLoading: state.isLoading,
      isLoadingMore: state.isLoadingMore,
      isRefreshing: state.isLoading && state.works != null,
      isStale: state.isLoading && state.works != null,
      hasAttemptedLoad: state.query != null || state.requestSerial > 0,
      hasMore: state.hasMore,
      needsLoadMoreRetry: state.needsLoadMoreRetry,
      totalCount: isRemote(category)
          ? state.totalCount ?? works.length
          : works.length,
      activeQuery: state.query ?? normalizeSearchQuery(searchQuery),
      lastError: state.error,
      operationError: state.error,
      revision: state.revision,
      hasUpdates: state.pendingWorks != null,
    );
  }

  List<AsmrWork> worksFor(AsmrCategoryType category) => isRemote(category)
      ? _state(category).works ?? const []
      : _localWorks(category);
  List<AsmrWork> filteredWorksFor(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) {
    if (isRemote(category)) {
      return _state(category, searchQuery).works ?? const [];
    }
    final works = _localWorks(category);
    final query = normalizeSearchQuery(searchQuery);
    if (query.isEmpty) return works;
    final key = (
      category: category,
      query: query,
      revision: _state(category, query).revision,
    );
    final cached = _filteredWorksCache.remove(key);
    if (cached != null) {
      _filteredWorksCache[key] = cached;
      return cached;
    }
    final terms = normalizedSearchTerms(query);
    final filtered = immutableList(
      works.where(
        (work) => matchesSearchTerms(
          [
            work.title,
            work.circleName,
            work.rjCode,
            ...work.tags,
            ...work.voiceActors,
          ],
          query,
          normalizedTerms: terms,
        ),
      ),
    );
    _filteredWorksCache[key] = filtered;
    if (_filteredWorksCache.length > 24) {
      _filteredWorksCache.remove(_filteredWorksCache.keys.first);
    }
    return filtered;
  }

  void bumpRevision(AsmrCategoryType category) {
    for (final entry in _categories.entries) {
      if (entry.key.category == category) entry.value.revision++;
    }
    _filteredWorksCache.removeWhere((key, _) => key.category == category);
  }

  void setOperationError(AsmrCategoryType category, Object? error) {
    _state(category).error = error;
    bumpRevision(category);
    _onChanged();
  }

  void updateLocalCounts() {
    for (final category in [
      AsmrCategoryType.favorites,
      AsmrCategoryType.history,
    ]) {
      _state(category).totalCount = _localWorks(category).length;
    }
  }

  void updateFavorite(int workId, bool favorite) {
    for (final entry in _categories.entries) {
      final works = entry.value.works;
      if (works == null) continue;
      entry.value.works = immutableList(
        works.map(
          (work) =>
              work.id == workId ? work.copyWith(isFavorite: favorite) : work,
        ),
      );
      entry.value.revision++;
    }
    _filteredWorksCache.clear();
  }

  Map<AsmrCategoryType, String> get loadedRemoteQueries => {
    for (final entry in _categories.entries)
      if (entry.key.scope == _currentContext().scope &&
          isRemote(entry.key.category) &&
          entry.value.query != null)
        entry.key.category: entry.key.query,
  };
  void invalidateForAuthChange() {
    for (final entry in _categories.entries) {
      if (isRemote(entry.key.category) &&
          (entry.value.works != null || entry.value.isLoading)) {
        _pendingAuthRefreshes[entry.key.category] = entry.key.query;
      }
      entry.value.invalidateRequest();
    }
    _lastQueries.clear();
    _filteredWorksCache.clear();
  }

  Map<AsmrCategoryType, String> takePendingAuthRefreshes() {
    final pending = Map<AsmrCategoryType, String>.from(_pendingAuthRefreshes);
    _pendingAuthRefreshes.clear();
    return pending;
  }

  void invalidateForContentChange() {
    for (final state in _categories.values) {
      state.invalidateRequest();
      state.revision++;
    }
    _lastQueries.clear();
    _filteredWorksCache.clear();
  }

  void clearWorks() {
    for (final state in _categories.values) {
      state.invalidateRequest();
    }
    _categories.clear();
    _lastQueries.clear();
    _pendingAuthRefreshes.clear();
    _filteredWorksCache.clear();
  }

  void restore(String scope, Map<String, Map<String, Object?>> snapshots) {
    for (final entry in snapshots.entries) {
      final payload = entry.value;
      if (payload['version'] != 1) continue;
      final key = jsonDecode(entry.key) as List;
      final category = AsmrCategoryType.values.byName(key[0] as String);
      final query = key[1] as String;
      final state = _categories.putIfAbsent((
        scope: scope,
        category: category,
        query: query,
      ), _CategoryState.new);
      if (state.works != null || state.isLoading) continue;
      final works = immutableList(
        (payload['works'] as List).map(
          (item) => _decorateWork(
            AsmrWork.fromJson(Map<String, dynamic>.from(item as Map)),
          ),
        ),
      );
      final page = payload['page'] as int;
      final total = payload['total'] as int;
      final hasMore = payload['hasMore'] as bool;
      final firstPageIds =
          (payload['firstPageIds'] as List?)?.cast<int>().toList() ??
          works.map((work) => work.id).toList();
      state.works = works;
      state.page = page;
      state.totalCount = total;
      state.hasMore = hasMore;
      state.query = query;
      state.firstPageIds = firstPageIds;
      state.revision++;
    }
  }

  void _save(_CategoryKey key, _CategoryState state) {
    if (state.works == null || !isRemote(key.category)) return;
    _persist(key.scope, jsonEncode([key.category.name, key.query]), {
      'version': 1,
      'works': state.works!.map((work) => work.toJson()).toList(),
      'page': state.page,
      'total': state.totalCount,
      'hasMore': state.hasMore,
      'firstPageIds': state.firstPageIds,
    });
  }

  bool _isCurrent(_CategoryKey key, _CategoryRequestKey request) =>
      _isContextCurrent(request.context) &&
      request.serial == _categories[key]?.requestSerial;

  Future<void> refresh(
    AsmrCategoryType category, {
    required String searchQuery,
    required AsmrCategoryRequestContext context,
    bool background = false,
  }) async {
    final query = normalizeSearchQuery(searchQuery);
    _lastQueries[category] = query;
    final cacheKey = _key(category, query, context);
    final state = _categories.putIfAbsent(cacheKey, _CategoryState.new);
    final pagination = state.loadMoreTask;
    if (pagination != null) await pagination;
    if (!_isContextCurrent(context)) return;
    if (state.refreshTask != null) return state.refreshTask;
    final request = (context: context, serial: ++state.requestSerial);
    late final Future<void> task;
    task = _refresh(cacheKey, state, request, background).whenComplete(() {
      if (identical(state.refreshTask, task)) state.refreshTask = null;
    });
    state.refreshTask = task;
    await task;
  }

  Future<AsmrWorkPage> _fetch(
    _CategoryKey key,
    AsmrCategoryRequestContext context,
    int page,
    int serial,
  ) async {
    if (key.category == AsmrCategoryType.recommendation) {
      final ranked = await _remoteCatalogService.loadRecommendations(
        searchQuery: key.query,
        language: context.language,
        token: context.token,
        favoriteWorks: _localWorks(AsmrCategoryType.favorites),
        historyWorks: _localWorks(AsmrCategoryType.history),
        refreshSeed: serial,
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
    );
  }

  Future<void> _refresh(
    _CategoryKey cacheKey,
    _CategoryState state,
    _CategoryRequestKey request,
    bool background,
  ) async {
    state.isLoading = true;
    state.needsLoadMoreRetry = false;
    state.error = null;
    if (_isCurrent(cacheKey, request)) _onChanged();
    try {
      if (!_isCurrent(cacheKey, request)) return;
      if (!isRemote(cacheKey.category)) {
        state.query = cacheKey.query;
        state.hasMore = false;
        return;
      }
      final result = await _fetch(cacheKey, request.context, 1, request.serial);
      if (!_isCurrent(cacheKey, request)) return;
      final ids = <int>{};
      final frozen = immutableList(
        result.works.where((work) => ids.add(work.id)).map(_decorateWork),
      );
      if (background && state.works != null) {
        final oldFirstPage = state.works!
            .take(state.firstPageIds.length)
            .toList();
        if (state.totalCount != result.totalCount ||
            jsonEncode(oldFirstPage.map((work) => work.toJson()).toList()) !=
                jsonEncode(frozen.map((work) => work.toJson()).toList())) {
          // Background checks do not replace the user's loaded range or position.
          state.pendingWorks = frozen;
          state.pendingPage = result;
        } else {
          state.pendingWorks = null;
          state.pendingPage = null;
        }
      } else {
        state.works = frozen;
        state.pendingWorks = null;
        state.pendingPage = null;
        _applyPageResult(state, cacheKey.query, result);
        _save(cacheKey, state);
      }
      state.revision++;
      _onChanged();
    } catch (error) {
      if (_isCurrent(cacheKey, request)) state.error = error;
    } finally {
      if (_isCurrent(cacheKey, request)) {
        state.isLoading = false;
        _onChanged();
      }
    }
  }

  void acceptUpdates(AsmrCategoryType category, {String searchQuery = ''}) {
    final key = _key(category, searchQuery);
    final state = _state(category, searchQuery);
    if (state.pendingWorks == null) return;
    state.works = state.pendingWorks;
    _applyPageResult(state, key.query, state.pendingPage!);
    state.pendingWorks = null;
    state.pendingPage = null;
    state.revision++;
    _save(key, state);
    _onChanged();
  }

  Future<void> loadMore(
    AsmrCategoryType category, {
    required String searchQuery,
    required AsmrCategoryRequestContext context,
  }) async {
    final state = _state(category, searchQuery);
    final refresh = state.refreshTask;
    if (refresh != null) await refresh;
    if (!_isContextCurrent(context)) return;
    final existing = state.loadMoreTask;
    if (existing != null) return existing;
    late final Future<void> task;
    task = _loadMore(category, searchQuery: searchQuery, context: context)
        .whenComplete(() {
          if (identical(state.loadMoreTask, task)) state.loadMoreTask = null;
        });
    state.loadMoreTask = task;
    await task;
  }

  Future<void> _loadMore(
    AsmrCategoryType category, {
    required String searchQuery,
    required AsmrCategoryRequestContext context,
  }) async {
    final query = normalizeSearchQuery(searchQuery);
    final state = _state(category, query);
    final refreshTask = state.refreshTask;
    if (refreshTask != null) await refreshTask;
    if (!isRemote(category) ||
        category == AsmrCategoryType.recommendation ||
        state.isLoadingMore ||
        !_isContextCurrent(context)) {
      return;
    }
    if (state.works == null) {
      await refresh(category, searchQuery: query, context: context);
      return;
    }
    if (!state.hasMore || state.pendingWorks != null) return;
    final key = _key(category, query, context);
    final request = (context: context, serial: state.requestSerial);
    state.isLoadingMore = true;
    state.needsLoadMoreRetry = false;
    state.error = null;
    _onChanged();
    try {
      final result = await _fetch(key, context, state.page + 1, request.serial);
      if (!_isCurrent(key, request)) return;
      final ids = state.works!.map((work) => work.id).toSet();
      final additions = result.works
          .where((work) => ids.add(work.id))
          .map(_decorateWork)
          .toList();
      state.works = immutableList([...state.works!, ...additions]);
      state.revision++;
      _applyPageResult(state, query, result);
      state.needsLoadMoreRetry = additions.isEmpty && state.hasMore;
      _save(key, state);
      _onChanged();
    } catch (error) {
      if (_isCurrent(key, request)) {
        state.error = error;
        state.needsLoadMoreRetry = true;
      }
    } finally {
      if (_isCurrent(key, request)) {
        state.isLoadingMore = false;
        _onChanged();
      }
    }
  }

  void _applyPageResult(
    _CategoryState state,
    String query,
    AsmrWorkPage result,
  ) {
    state.query = query;
    state.page = result.currentPage;
    if (result.currentPage == 1) {
      state.firstPageIds = state.works!.map((work) => work.id).toList();
    }
    state.totalCount = result.totalCount;
    state.hasMore =
        result.hasMore && (state.works?.length ?? 0) < result.totalCount;
  }
}
