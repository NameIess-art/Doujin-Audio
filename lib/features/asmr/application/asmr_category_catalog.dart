import 'dart:collection';

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
});

typedef _CategoryRequestKey = ({
  AsmrCategoryRequestContext context,
  int serial,
});
typedef _CategoryRequest = ({
  Future<void> task,
  String query,
  _CategoryRequestKey key,
});
typedef _FilteredWorksKey = ({
  AsmrCategoryType category,
  String query,
  int revision,
});

final class _CategoryState {
  List<AsmrWork>? works;
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

  void invalidateRequest() {
    requestSerial++;
    isLoading = false;
    isLoadingMore = false;
    needsLoadMoreRetry = false;
  }
}

/// Owns category requests and derived views, without retaining account state.
final class AsmrCategoryCatalog {
  AsmrCategoryCatalog({
    required AsmrRemoteCatalogService remoteCatalogService,
    required void Function() onChanged,
    required bool Function(AsmrCategoryRequestContext) isContextCurrent,
    required List<AsmrWork> Function(AsmrCategoryType) localWorks,
    required AsmrWork Function(AsmrWork) decorateWork,
  }) : _remoteCatalogService = remoteCatalogService,
       _onChanged = onChanged,
       _isContextCurrent = isContextCurrent,
       _localWorks = localWorks,
       _decorateWork = decorateWork;

  final AsmrRemoteCatalogService _remoteCatalogService;
  final void Function() _onChanged;
  final bool Function(AsmrCategoryRequestContext) _isContextCurrent;
  final List<AsmrWork> Function(AsmrCategoryType) _localWorks;
  final AsmrWork Function(AsmrWork) _decorateWork;
  final Map<AsmrCategoryType, _CategoryState> _categories = {
    for (final category in AsmrCategoryType.values) category: _CategoryState(),
  };
  final Map<AsmrCategoryType, _CategoryRequest> _refreshTasks = {};
  final Map<AsmrCategoryType, String> _pendingAuthRefreshes = {};
  final LinkedHashMap<_FilteredWorksKey, List<AsmrWork>> _filteredWorksCache =
      LinkedHashMap();

  _CategoryState _state(AsmrCategoryType category) => _categories[category]!;

  static bool isRemote(AsmrCategoryType category) =>
      category != AsmrCategoryType.favorites &&
      category != AsmrCategoryType.history;

  bool isLoading(AsmrCategoryType category) => _state(category).isLoading;
  bool hasLoaded(AsmrCategoryType category) => _state(category).works != null;
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
    final state = _state(category);
    final works = filteredWorksFor(category, searchQuery: searchQuery);
    return AsmrCategoryViewState(
      category: category,
      works: works,
      isLoading: state.isLoading,
      isLoadingMore: state.isLoadingMore,
      isRefreshing: state.isLoading && works.isNotEmpty,
      isStale: state.isLoading && works.isNotEmpty,
      hasAttemptedLoad: state.query != null || state.requestSerial > 0,
      hasMore: state.hasMore,
      needsLoadMoreRetry: state.needsLoadMoreRetry,
      totalCount: isRemote(category) ? totalCount(category) : works.length,
      activeQuery: activeQuery(category),
      lastError: state.error,
      operationError: state.error,
      revision: state.revision,
    );
  }

  List<AsmrWork> worksFor(AsmrCategoryType category) => isRemote(category)
      ? _state(category).works ?? const <AsmrWork>[]
      : _localWorks(category);

  List<AsmrWork> filteredWorksFor(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) {
    final works = worksFor(category);
    final query = normalizeSearchQuery(searchQuery);
    if (query.isEmpty || isRemote(category)) return works;
    final key = (
      category: category,
      query: query,
      revision: _state(category).revision,
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
    while (_filteredWorksCache.length > 24) {
      _filteredWorksCache.remove(_filteredWorksCache.keys.first);
    }
    return filtered;
  }

  void bumpRevision(AsmrCategoryType category) {
    _state(category).revision++;
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
      _state(category).totalCount = filteredWorksFor(
        category,
        searchQuery: activeQuery(category),
      ).length;
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
      bumpRevision(entry.key);
    }
  }

  Map<AsmrCategoryType, String> get loadedRemoteQueries => {
    for (final entry in _categories.entries)
      if (isRemote(entry.key) && entry.value.query != null)
        entry.key: entry.value.query!,
  };

  void invalidateForAuthChange() {
    for (final entry in _categories.entries) {
      final category = entry.key;
      final state = entry.value;
      if (isRemote(category) &&
          (state.query != null ||
              state.works != null ||
              _refreshTasks.containsKey(category))) {
        _pendingAuthRefreshes.putIfAbsent(
          category,
          () => _refreshTasks[category]?.query ?? state.query ?? '',
        );
      }
      state.invalidateRequest();
      if (isRemote(category)) {
        state.error = null;
        state.page = 1;
        state.totalCount = null;
        state.hasMore = false;
      }
    }
    _refreshTasks.clear();
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
      state.works = null;
      state.error = null;
      if (isRemote(entry.key)) state.query = null;
      bumpRevision(entry.key);
    }
    _refreshTasks.clear();
  }

  void clearWorks() {
    for (final state in _categories.values) {
      state.works = null;
    }
    _filteredWorksCache.clear();
  }

  bool _isCurrent(AsmrCategoryType category, _CategoryRequestKey key) =>
      _isContextCurrent(key.context) &&
      key.serial == _state(category).requestSerial;

  Future<void> refresh(
    AsmrCategoryType category, {
    required String searchQuery,
    required AsmrCategoryRequestContext context,
  }) async {
    final query = normalizeSearchQuery(searchQuery);
    final existing = _refreshTasks[category];
    if (existing != null &&
        existing.query == query &&
        existing.key.context == context) {
      return existing.task;
    }
    final key = (context: context, serial: ++_state(category).requestSerial);
    late final Future<void> task;
    task = _refresh(category, query: query, key: key).whenComplete(() {
      if (identical(_refreshTasks[category]?.task, task)) {
        _refreshTasks.remove(category);
      }
    });
    _refreshTasks[category] = (task: task, query: query, key: key);
    await task;
  }

  Future<void> _refresh(
    AsmrCategoryType category, {
    required String query,
    required _CategoryRequestKey key,
  }) async {
    final state = _state(category);
    state.isLoading = true;
    state.needsLoadMoreRetry = false;
    state.error = null;
    if (_isCurrent(category, key)) _onChanged();
    try {
      if (!_isCurrent(category, key)) return;
      if (!isRemote(category)) {
        state.query = query;
        state.totalCount = filteredWorksFor(
          category,
          searchQuery: query,
        ).length;
        state.hasMore = false;
        return;
      }
      final context = key.context;
      final AsmrWorkPage result;
      if (category == AsmrCategoryType.recommendation) {
        final ranked = await _remoteCatalogService.loadRecommendations(
          searchQuery: query,
          language: context.language,
          token: context.token,
          favoriteWorks: _localWorks(AsmrCategoryType.favorites),
          historyWorks: _localWorks(AsmrCategoryType.history),
          refreshSeed: key.serial,
        );
        result = AsmrWorkPage(
          works: ranked,
          currentPage: 1,
          pageSize: ranked.length,
          totalCount: ranked.length,
        );
      } else {
        result = await _remoteCatalogService.loadPage(
          category,
          searchQuery: query,
          page: 1,
          language: context.language,
          token: context.token,
        );
      }
      if (!_isCurrent(category, key)) return;
      state.works = immutableList(result.works.map(_decorateWork));
      bumpRevision(category);
      _applyPageResult(category, query, result);
      if (category == AsmrCategoryType.recommendation) state.hasMore = false;
      _onChanged();
    } catch (error) {
      if (_isCurrent(category, key)) state.error = error;
    } finally {
      if (_isCurrent(category, key)) {
        state.isLoading = false;
        _onChanged();
      }
    }
  }

  Future<void> loadMore(
    AsmrCategoryType category, {
    required String searchQuery,
    required AsmrCategoryRequestContext context,
  }) async {
    final query = normalizeSearchQuery(searchQuery);
    final state = _state(category);
    if (!isRemote(category) ||
        category == AsmrCategoryType.recommendation ||
        state.isLoading ||
        state.isLoadingMore) {
      return;
    }
    if (activeQuery(category) != query) {
      await refresh(category, searchQuery: query, context: context);
      return;
    }
    if (!state.hasMore) return;
    final key = (context: context, serial: state.requestSerial);
    state.isLoadingMore = true;
    state.needsLoadMoreRetry = false;
    state.error = null;
    if (_isCurrent(category, key)) _onChanged();
    try {
      final result = await _remoteCatalogService.loadPage(
        category,
        searchQuery: query,
        page: state.page + 1,
        language: context.language,
        token: context.token,
      );
      if (!_isCurrent(category, key)) return;
      final existingIds = (state.works ?? const <AsmrWork>[])
          .map((work) => work.id)
          .toSet();
      final additions = result.works
          .where((work) => existingIds.add(work.id))
          .toList(growable: false);
      state.works = immutableList([
        ...?state.works,
        ...additions.map(_decorateWork),
      ]);
      bumpRevision(category);
      _applyPageResult(category, query, result);
      state.needsLoadMoreRetry = additions.isEmpty && state.hasMore;
      _onChanged();
    } catch (error) {
      if (_isCurrent(category, key)) {
        state.error = error;
        state.needsLoadMoreRetry = true;
      }
    } finally {
      if (_isCurrent(category, key)) {
        state.isLoadingMore = false;
        _onChanged();
      }
    }
  }

  void _applyPageResult(
    AsmrCategoryType category,
    String query,
    AsmrWorkPage result,
  ) {
    final state = _state(category);
    state.query = query;
    state.page = result.currentPage;
    state.totalCount = result.totalCount;
    state.hasMore =
        result.hasMore && (state.works?.length ?? 0) < result.totalCount;
  }
}
