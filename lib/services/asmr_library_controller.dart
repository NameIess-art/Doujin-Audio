import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../models/asmr_models.dart';
import '../providers/audio_provider.dart';
import 'audio_database_repository.dart';
import 'asmr_api_service.dart';
import 'asmr_auth_service.dart';
import 'asmr_preferences.dart';
import 'asmr_recommendation_engine.dart';
import 'search_query_utils.dart';
import 'ui_interaction_coordinator.dart';

class AsmrLibraryGlobalViewState {
  const AsmrLibraryGlobalViewState({
    required this.initialized,
    required this.lastError,
    required this.visibleCategories,
    required this.contentLanguage,
    required this.revision,
  });

  final bool initialized;
  final Object? lastError;
  final List<AsmrCategoryType> visibleCategories;
  final AsmrContentLanguage contentLanguage;
  final int revision;

  @override
  bool operator ==(Object other) {
    return other is AsmrLibraryGlobalViewState &&
        initialized == other.initialized &&
        lastError == other.lastError &&
        listEquals(visibleCategories, other.visibleCategories) &&
        contentLanguage == other.contentLanguage &&
        revision == other.revision;
  }

  @override
  int get hashCode => Object.hash(
    initialized,
    lastError,
    Object.hashAll(visibleCategories),
    contentLanguage,
    revision,
  );
}

class AsmrCategoryViewState {
  const AsmrCategoryViewState({
    required this.category,
    required this.works,
    required this.isLoading,
    required this.isLoadingMore,
    required this.isRefreshing,
    required this.isStale,
    required this.hasAttemptedLoad,
    required this.hasMore,
    required this.totalCount,
    required this.activeQuery,
    required this.lastError,
    required this.operationError,
    required this.revision,
  });

  final AsmrCategoryType category;
  final List<AsmrWork> works;
  final bool isLoading;
  final bool isLoadingMore;
  final bool isRefreshing;
  final bool isStale;
  final bool hasAttemptedLoad;
  final bool hasMore;
  final int totalCount;
  final String activeQuery;
  final Object? lastError;
  final Object? operationError;
  final int revision;

  @override
  bool operator ==(Object other) {
    return other is AsmrCategoryViewState &&
        category == other.category &&
        identical(works, other.works) &&
        isLoading == other.isLoading &&
        isLoadingMore == other.isLoadingMore &&
        isRefreshing == other.isRefreshing &&
        isStale == other.isStale &&
        hasAttemptedLoad == other.hasAttemptedLoad &&
        hasMore == other.hasMore &&
        totalCount == other.totalCount &&
        activeQuery == other.activeQuery &&
        lastError == other.lastError &&
        operationError == other.operationError &&
        revision == other.revision;
  }

  @override
  int get hashCode => Object.hash(
    category,
    identityHashCode(works),
    isLoading,
    isLoadingMore,
    isRefreshing,
    isStale,
    hasAttemptedLoad,
    hasMore,
    totalCount,
    activeQuery,
    lastError,
    operationError,
    revision,
  );
}

class AsmrTrackTreeViewState {
  const AsmrTrackTreeViewState({
    required this.workId,
    required this.tree,
    required this.visibleTree,
    required this.isLoading,
    required this.isRefreshing,
    required this.isStale,
    required this.operationError,
    required this.revision,
  });

  final int workId;
  final List<AsmrTrackFile>? tree;
  final List<AsmrTrackFile>? visibleTree;
  final bool isLoading;
  final bool isRefreshing;
  final bool isStale;
  final Object? operationError;
  final int revision;

  @override
  bool operator ==(Object other) {
    return other is AsmrTrackTreeViewState &&
        workId == other.workId &&
        identical(tree, other.tree) &&
        identical(visibleTree, other.visibleTree) &&
        isLoading == other.isLoading &&
        isRefreshing == other.isRefreshing &&
        isStale == other.isStale &&
        operationError == other.operationError &&
        revision == other.revision;
  }

  @override
  int get hashCode => Object.hash(
    workId,
    identityHashCode(tree),
    identityHashCode(visibleTree),
    isLoading,
    isRefreshing,
    isStale,
    operationError,
    revision,
  );
}

class AsmrAuthViewState {
  const AsmrAuthViewState({
    required this.isLoggedIn,
    required this.userName,
    required this.revision,
  });

  final bool isLoggedIn;
  final String userName;
  final int revision;
}

class AsmrSyncViewState {
  const AsmrSyncViewState({
    required this.phase,
    required this.lastSyncAt,
    required this.pendingCount,
    required this.lastError,
    required this.revision,
  });

  final AsmrSyncPhase phase;
  final DateTime? lastSyncAt;
  final int pendingCount;
  final Object? lastError;
  final int revision;
}

class _AsmrFilteredWorksCacheKey {
  const _AsmrFilteredWorksCacheKey({
    required this.category,
    required this.query,
    required this.revision,
  });

  final AsmrCategoryType category;
  final String query;
  final int revision;

  @override
  bool operator ==(Object other) {
    return other is _AsmrFilteredWorksCacheKey &&
        category == other.category &&
        query == other.query &&
        revision == other.revision;
  }

  @override
  int get hashCode => Object.hash(category, query, revision);
}

class _RecommendationCandidatePageResult {
  const _RecommendationCandidatePageResult({
    this.pages = const <AsmrWorkPage>[],
    this.error,
  });

  final List<AsmrWorkPage> pages;
  final Object? error;
}

class AsmrLibraryController extends ChangeNotifier {
  AsmrLibraryController({
    AsmrApiService? apiService,
    AsmrAuthService? authService,
    AudioDatabaseRepository? audioDatabaseRepository,
    AsmrRecommendationEngine recommendationEngine =
        const AsmrRecommendationEngine(),
  }) : _apiService = apiService ?? AsmrApiService(),
       _authService = authService ?? AsmrAuthService(apiService: apiService),
       _audioDatabaseRepository =
           audioDatabaseRepository ?? AudioDatabaseRepository(),
       _recommendationEngine = recommendationEngine;

  static const int _historyLimit = 60;
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
  static const List<AsmrCategoryType> _recommendationCandidateCategories =
      <AsmrCategoryType>[
        AsmrCategoryType.collected,
        AsmrCategoryType.sales,
        AsmrCategoryType.rating,
        AsmrCategoryType.release,
      ];
  static const int _recommendationCandidatePagesPerRefresh = 2;
  static const int _detailCacheLimit = 128;
  static const int _trackCacheLimit = 32;
  static const int _filteredWorksCacheLimit = 24;
  static const List<Duration> _transientRemoteLoadRetryDelays = <Duration>[
    Duration(milliseconds: 350),
    Duration(milliseconds: 900),
  ];

  final AsmrApiService _apiService;
  final AsmrAuthService _authService;
  final AudioDatabaseRepository _audioDatabaseRepository;
  final AsmrRecommendationEngine _recommendationEngine;
  final Map<AsmrCategoryType, Future<void>> _refreshTasks =
      <AsmrCategoryType, Future<void>>{};
  final Map<AsmrCategoryType, String> _refreshTaskQueries =
      <AsmrCategoryType, String>{};
  final Map<AsmrCategoryType, int> _refreshRequestSerial =
      <AsmrCategoryType, int>{};
  final Map<AsmrCategoryType, List<AsmrWork>> _worksByCategory =
      <AsmrCategoryType, List<AsmrWork>>{};
  final Map<AsmrCategoryType, bool> _loadingByCategory =
      <AsmrCategoryType, bool>{};
  final Map<AsmrCategoryType, bool> _loadingMoreByCategory =
      <AsmrCategoryType, bool>{};
  final Map<AsmrCategoryType, int> _currentPageByCategory =
      <AsmrCategoryType, int>{};
  final Map<AsmrCategoryType, int> _totalCountByCategory =
      <AsmrCategoryType, int>{};
  final Map<AsmrCategoryType, bool> _hasMoreByCategory =
      <AsmrCategoryType, bool>{};
  final Map<AsmrCategoryType, String> _queryByCategory =
      <AsmrCategoryType, String>{};
  final LinkedHashMap<int, AsmrWorkDetail> _detailCache = LinkedHashMap();
  final LinkedHashMap<int, List<AsmrTrackFile>> _trackCache = LinkedHashMap();
  final LinkedHashMap<int, List<AsmrTrackFile>> _visibleTrackCache =
      LinkedHashMap();
  final Set<int> _loadingTrackWorkIds = <int>{};
  final Map<AsmrCategoryType, int> _categoryRevisions =
      <AsmrCategoryType, int>{};
  final Map<int, int> _trackRevisions = <int, int>{};
  final LinkedHashMap<_AsmrFilteredWorksCacheKey, List<AsmrWork>>
  _filteredWorksCache = LinkedHashMap();

  List<AsmrCategoryType> _visibleCategories = kDefaultVisibleAsmrCategories;
  AsmrContentLanguage _contentLanguage = AsmrContentLanguage.zh;
  List<AsmrWork> _favoriteWorks = const <AsmrWork>[];
  Set<int> _favoriteIds = const <int>{};
  List<AsmrWork> _historyWorks = const <AsmrWork>[];
  List<AsmrSyncOperation> _syncOperations = const <AsmrSyncOperation>[];
  Map<int, String> _remoteProgressByWorkId = const <int, String>{};
  AsmrAuthSession? _authSession;
  AsmrSyncPhase _syncPhase = AsmrSyncPhase.idle;
  DateTime? _lastSyncAt;
  Object? _lastSyncError;
  Future<void>? _initializeTask;
  Future<void>? _authRestoreTask;
  Future<void>? _syncTask;
  bool _initialized = false;
  Object? _lastError;
  int _globalRevision = 0;

  void _commitPresentation(String key, VoidCallback commit) {
    final coordinator = UiInteractionCoordinator.instance;
    if (coordinator.isInteracting) {
      coordinator.scheduleCommit(key: key, priority: 10, commit: commit);
    } else {
      commit();
    }
  }

  bool get initialized => _initialized;
  Object? get lastError => _lastError;

  List<AsmrCategoryType> get visibleCategories => _visibleCategories;
  AsmrContentLanguage get contentLanguage => _contentLanguage;
  bool get isAsmrAccountLoggedIn {
    final session = _authSession;
    return session != null &&
        session.isValid &&
        session.userName.trim().isNotEmpty;
  }

  String get asmrAccountName => _authSession?.userName.trim() ?? '';

  bool isLoadingCategory(AsmrCategoryType category) =>
      _loadingByCategory[category] ?? false;
  bool isLoadingMoreCategory(AsmrCategoryType category) =>
      _loadingMoreByCategory[category] ?? false;
  bool hasMoreCategory(AsmrCategoryType category) =>
      _hasMoreByCategory[category] ?? false;
  int totalCountFor(AsmrCategoryType category) =>
      _totalCountByCategory[category] ?? worksFor(category).length;
  String activeQueryFor(AsmrCategoryType category) =>
      _queryByCategory[category] ?? '';
  bool isTrackTreeLoading(int workId) => _loadingTrackWorkIds.contains(workId);
  List<AsmrTrackFile>? trackTreeFor(int workId) => _cachedTrackTree(workId);

  AsmrLibraryGlobalViewState get globalViewState => AsmrLibraryGlobalViewState(
    initialized: _initialized,
    lastError: _lastError,
    visibleCategories: _visibleCategories,
    contentLanguage: _contentLanguage,
    revision: _globalRevision,
  );

  AsmrAuthViewState get authViewState => AsmrAuthViewState(
    isLoggedIn: isAsmrAccountLoggedIn,
    userName: asmrAccountName,
    revision: _globalRevision,
  );

  AsmrSyncViewState get syncViewState => AsmrSyncViewState(
    phase: _syncPhase,
    lastSyncAt: _lastSyncAt,
    pendingCount: _syncOperations.length,
    lastError: _lastSyncError,
    revision: _globalRevision,
  );

  AsmrCategoryViewState categoryViewState(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) {
    final works = filteredWorksFor(category, searchQuery: searchQuery);
    return AsmrCategoryViewState(
      category: category,
      works: works,
      isLoading: isLoadingCategory(category),
      isLoadingMore: isLoadingMoreCategory(category),
      isRefreshing: isLoadingCategory(category) && works.isNotEmpty,
      isStale: isLoadingCategory(category) && works.isNotEmpty,
      hasAttemptedLoad:
          _queryByCategory.containsKey(category) ||
          (_refreshRequestSerial[category] ?? 0) > 0,
      hasMore: hasMoreCategory(category),
      totalCount:
          category == AsmrCategoryType.favorites ||
              category == AsmrCategoryType.history
          ? works.length
          : totalCountFor(category),
      activeQuery: activeQueryFor(category),
      lastError: _lastError,
      operationError: _lastError,
      revision: _categoryRevisionFor(category),
    );
  }

  AsmrTrackTreeViewState trackTreeViewState(int workId) {
    final tree = _cachedTrackTree(workId);
    return AsmrTrackTreeViewState(
      workId: workId,
      tree: tree,
      visibleTree: tree == null ? null : _visibleTrackTreeFor(workId, tree),
      isLoading: isTrackTreeLoading(workId),
      isRefreshing: isTrackTreeLoading(workId) && tree != null,
      isStale: isTrackTreeLoading(workId) && tree != null,
      operationError: null,
      revision: _trackRevisions[workId] ?? 0,
    );
  }

  List<AsmrWork> worksFor(AsmrCategoryType category) {
    switch (category) {
      case AsmrCategoryType.favorites:
        return _favoriteWorks;
      case AsmrCategoryType.history:
        return _historyWorks;
      default:
        return _worksByCategory[category] ?? const <AsmrWork>[];
    }
  }

  List<AsmrWork> filteredWorksFor(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) {
    final works = worksFor(category);
    final normalizedQuery = normalizeSearchQuery(searchQuery);
    if (normalizedQuery.isEmpty) {
      return works;
    }
    if (category != AsmrCategoryType.favorites &&
        category != AsmrCategoryType.history) {
      return works;
    }
    final cacheKey = _AsmrFilteredWorksCacheKey(
      category: category,
      query: normalizedQuery,
      revision: _categoryRevisionFor(category),
    );
    final cached = _filteredWorksCache.remove(cacheKey);
    if (cached != null) {
      _filteredWorksCache[cacheKey] = cached;
      return cached;
    }
    final terms = extractSearchTerms(normalizedQuery);
    final filtered = works
        .where((work) => _matchesQuery(work, normalizedQuery, terms: terms))
        .toList(growable: false);
    _filteredWorksCache[cacheKey] = filtered;
    while (_filteredWorksCache.length > _filteredWorksCacheLimit) {
      _filteredWorksCache.remove(_filteredWorksCache.keys.first);
    }
    return filtered;
  }

  Future<void> initialize({AsmrContentLanguage? defaultLanguage}) {
    if (_initialized) return Future<void>.value();
    final existing = _initializeTask;
    if (existing != null) {
      return existing;
    }
    late final Future<void> task;
    task = _initializeLocalState(defaultLanguage: defaultLanguage).whenComplete(
      () {
        if (identical(_initializeTask, task)) {
          _initializeTask = null;
        }
      },
    );
    _initializeTask = task;
    return task;
  }

  Future<void> _initializeLocalState({
    AsmrContentLanguage? defaultLanguage,
  }) async {
    _visibleCategories = await AsmrPreferences.loadVisibleCategories();
    _contentLanguage = await AsmrPreferences.loadContentLanguage(
      defaultLanguage ?? AsmrContentLanguage.zh,
    );
    _favoriteWorks = await AsmrPreferences.loadFavoriteWorks();
    _favoriteIds = _favoriteWorks.map((work) => work.id).toSet();
    _historyWorks = await AsmrPreferences.loadHistoryWorks();
    _syncOperations = await AsmrPreferences.loadSyncOperations();
    await _seedSyncOutboxIfNeeded();
    _lastSyncAt = await AsmrPreferences.loadLastSyncAt();
    _updateLocalCategoryCounts();
    _initialized = true;
    _bumpGlobalRevision();
    _commitPresentation('asmr_initialize', notifyListeners);
    unawaited(restoreAsmrAccountSession());
  }

  Future<void> restoreAsmrAccountSession({bool force = false}) {
    if (!force && _authSession != null) {
      return Future<void>.value();
    }
    final existing = _authRestoreTask;
    if (!force && existing != null) {
      return existing;
    }
    late final Future<void> task;
    task = _restoreAsmrAccountSessionInternal().whenComplete(() {
      if (identical(_authRestoreTask, task)) {
        _authRestoreTask = null;
      }
    });
    _authRestoreTask = task;
    return task;
  }

  Future<void> _restoreAsmrAccountSessionInternal() async {
    final previousSession = _authSession;
    final AsmrAuthSession? restored;
    try {
      restored = await _authService.restoreSession();
    } catch (error) {
      _lastSyncError = error;
      _bumpGlobalRevision();
      _commitPresentation('asmr_auth_restore_error', notifyListeners);
      return;
    }
    if (previousSession?.token == restored?.token &&
        previousSession?.userName == restored?.userName) {
      return;
    }
    _authSession = restored;
    _lastSyncError = null;
    _bumpGlobalRevision();
    _commitPresentation('asmr_auth_restore', notifyListeners);
  }

  Future<void> reloadPersistedStateAfterBackupRestore() async {
    _initialized = false;
    _worksByCategory.clear();
    _detailCache.clear();
    _trackCache.clear();
    _visibleTrackCache.clear();
    _filteredWorksCache.clear();
    await initialize();
  }

  Future<void> loginAsmrAccount(String name, String password) async {
    _syncPhase = AsmrSyncPhase.syncing;
    _lastSyncError = null;
    _bumpGlobalRevision();
    notifyListeners();
    try {
      _authSession = await _authService.login(name.trim(), password);
      await syncAsmrAccount(force: true);
    } catch (error) {
      _authSession = null;
      _syncPhase = AsmrSyncPhase.failed;
      _lastSyncError = error;
      _bumpGlobalRevision();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> logoutAsmrAccount() async {
    await _authService.logout();
    _authSession = null;
    _remoteProgressByWorkId = const <int, String>{};
    _syncPhase = AsmrSyncPhase.idle;
    _lastSyncError = null;
    _bumpGlobalRevision();
    notifyListeners();
  }

  Future<void> syncAsmrAccount({bool force = false}) {
    final existing = _syncTask;
    if (existing != null) {
      return existing;
    }
    late final Future<void> task;
    task = _syncAsmrAccountInternal().whenComplete(() {
      if (identical(_syncTask, task)) {
        _syncTask = null;
      }
    });
    _syncTask = task;
    return task;
  }

  Future<void> _syncAsmrAccountInternal() async {
    final session = _authSession;
    if (session == null || !session.isValid) {
      return;
    }
    _syncPhase = AsmrSyncPhase.syncing;
    _lastSyncError = null;
    _bumpGlobalRevision();
    notifyListeners();
    try {
      await _runAsmrAccountSync(session.token);
      await _markAsmrAccountSyncSucceeded();
    } catch (error) {
      var failure = error;
      final recovered = await _recoverAsmrAccountSession(error);
      if (recovered != null) {
        try {
          await _runAsmrAccountSync(recovered.token);
          await _markAsmrAccountSyncSucceeded();
          return;
        } catch (retryError) {
          failure = retryError;
        }
      }
      if (AsmrApiException.isAuthenticationError(failure)) {
        await _authService.logout();
        _authSession = null;
      }
      _syncPhase = AsmrSyncPhase.failed;
      _lastSyncError = failure;
    } finally {
      _updateLocalCategoryCounts();
      _bumpCategoryRevision(AsmrCategoryType.favorites);
      _bumpCategoryRevision(AsmrCategoryType.history);
      _bumpGlobalRevision();
      notifyListeners();
    }
  }

  Future<void> _runAsmrAccountSync(String token) async {
    do {
      final batch = _syncOperations.toList(growable: false)
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (batch.any(
        (operation) =>
            operation.type == AsmrSyncOperationType.historyListening ||
            operation.type == AsmrSyncOperationType.favoriteRemove,
      )) {
        await _preflightProtectedRemoteProgress(token);
      }
      final uploaded = await _flushSyncOperations(token, batch);
      await _pullRemoteReviewState(token);
      if (uploaded.isNotEmpty) {
        _syncOperations = _syncOperations
            .where(
              (operation) => !uploaded.any(
                (uploadedOperation) => identical(uploadedOperation, operation),
              ),
            )
            .toList(growable: false);
        await AsmrPreferences.saveSyncOperations(_syncOperations);
      }
    } while (_syncOperations.isNotEmpty);
  }

  Future<void> refreshCategoryWithSync(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) async {
    if (isAsmrAccountLoggedIn) {
      await syncAsmrAccount(force: true);
      if (_syncPhase == AsmrSyncPhase.failed) {
        _lastError = _lastSyncError;
        _bumpGlobalRevision();
        notifyListeners();
        return;
      }
    }
    await refreshCategory(category, searchQuery: searchQuery);
  }

  Future<void> _markAsmrAccountSyncSucceeded() async {
    _lastSyncAt = DateTime.now();
    await AsmrPreferences.saveLastSyncAt(_lastSyncAt!);
    _syncPhase = AsmrSyncPhase.succeeded;
  }

  Future<AsmrAuthSession?> _recoverAsmrAccountSession(Object error) async {
    if (!AsmrApiException.isAuthenticationError(error)) {
      return null;
    }
    final recovered = await _authService.restoreSession();
    if (recovered == null || !recovered.isValid) {
      return null;
    }
    _authSession = recovered;
    return recovered;
  }

  Future<void> setVisibleCategories(List<AsmrCategoryType> categories) async {
    final next = _sanitizeVisibleCategories(categories);
    if (listEquals(next, _visibleCategories)) {
      return;
    }
    _visibleCategories = next;
    await AsmrPreferences.saveVisibleCategories(next);
    _bumpGlobalRevision();
    notifyListeners();
  }

  Future<void> setContentLanguage(AsmrContentLanguage language) async {
    if (_contentLanguage == language) {
      return;
    }
    _contentLanguage = language;
    await AsmrPreferences.saveContentLanguage(language);
    _worksByCategory.clear();
    _detailCache.clear();
    _trackCache.clear();
    _visibleTrackCache.clear();
    _queryByCategory.removeWhere(
      (category, _) =>
          category != AsmrCategoryType.favorites &&
          category != AsmrCategoryType.history,
    );
    for (final category in AsmrCategoryType.values) {
      _bumpCategoryRevision(category);
    }
    _bumpAllTrackRevisions();
    _bumpGlobalRevision();
    notifyListeners();
  }

  Future<void> refreshCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) {
    final existing = _refreshTasks[category];
    final normalizedQuery = normalizeSearchQuery(searchQuery);
    if (existing != null && _refreshTaskQueries[category] == normalizedQuery) {
      return existing;
    }
    final requestId = (_refreshRequestSerial[category] ?? 0) + 1;
    _refreshRequestSerial[category] = requestId;
    late final Future<void> task;
    task =
        _refreshCategoryInternal(
          category,
          searchQuery: normalizedQuery,
          requestId: requestId,
        ).whenComplete(() {
          if (identical(_refreshTasks[category], task)) {
            _refreshTasks.remove(category);
            _refreshTaskQueries.remove(category);
          }
        });
    _refreshTasks[category] = task;
    _refreshTaskQueries[category] = normalizedQuery;
    return task;
  }

  Future<void> loadMoreCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) async {
    await initialize();
    final normalizedQuery = normalizeSearchQuery(searchQuery);
    if (category == AsmrCategoryType.favorites ||
        category == AsmrCategoryType.history ||
        category == AsmrCategoryType.recommendation) {
      return;
    }
    if (isLoadingCategory(category) || isLoadingMoreCategory(category)) {
      return;
    }
    final existingQuery = _queryByCategory[category] ?? '';
    if (existingQuery != normalizedQuery) {
      await refreshCategory(category, searchQuery: normalizedQuery);
      return;
    }
    if (!hasMoreCategory(category)) {
      return;
    }

    _loadingMoreByCategory[category] = true;
    notifyListeners();
    try {
      final requestId = _refreshRequestSerial[category] ?? 0;
      final page = (_currentPageByCategory[category] ?? 1) + 1;
      final pageResult = await _loadRemotePage(
        category,
        searchQuery: normalizedQuery,
        page: page,
      );
      if (_refreshRequestSerial[category] != requestId) {
        return;
      }
      final existingIds = (_worksByCategory[category] ?? const <AsmrWork>[])
          .map((work) => work.id)
          .toSet();
      final merged = <AsmrWork>[
        ...?_worksByCategory[category],
        ...pageResult.works.where((work) => existingIds.add(work.id)),
      ];
      final decorated = merged.map(_decorateWork).toList(growable: false);
      _commitPresentation('asmr_page_${category.name}', () {
        _worksByCategory[category] = decorated;
        _bumpCategoryRevision(category);
        _applyPageResult(
          category,
          query: normalizedQuery,
          pageResult: pageResult,
        );
        notifyListeners();
      });
    } catch (error) {
      _lastError = error;
    } finally {
      _commitPresentation('asmr_loading_more_${category.name}', () {
        _loadingMoreByCategory[category] = false;
        notifyListeners();
      });
    }
  }

  Future<void> _refreshCategoryInternal(
    AsmrCategoryType category, {
    required String searchQuery,
    required int requestId,
  }) async {
    final normalizedQuery = normalizeSearchQuery(searchQuery);
    _loadingByCategory[category] = true;
    _lastError = null;
    _commitPresentation('asmr_loading_start_${category.name}', notifyListeners);
    try {
      await initialize();
      switch (category) {
        case AsmrCategoryType.collected:
          await _loadWorks(
            category,
            searchQuery: normalizedQuery,
            requestId: requestId,
          );
          break;
        case AsmrCategoryType.recommendation:
          await _loadRecommendedWorks(
            category,
            searchQuery: normalizedQuery,
            requestId: requestId,
          );
          break;
        case AsmrCategoryType.sales:
          await _loadWorks(
            category,
            searchQuery: normalizedQuery,
            requestId: requestId,
          );
          break;
        case AsmrCategoryType.rating:
          await _loadWorks(
            category,
            searchQuery: normalizedQuery,
            requestId: requestId,
          );
          break;
        case AsmrCategoryType.reviews:
          await _loadWorks(
            category,
            searchQuery: normalizedQuery,
            requestId: requestId,
          );
          break;
        case AsmrCategoryType.release:
          await _loadWorks(
            category,
            searchQuery: normalizedQuery,
            requestId: requestId,
          );
          break;
        case AsmrCategoryType.favorites:
          _queryByCategory[category] = normalizedQuery;
          _totalCountByCategory[category] = filteredWorksFor(
            category,
            searchQuery: normalizedQuery,
          ).length;
          _hasMoreByCategory[category] = false;
          break;
        case AsmrCategoryType.history:
          _queryByCategory[category] = normalizedQuery;
          _totalCountByCategory[category] = filteredWorksFor(
            category,
            searchQuery: normalizedQuery,
          ).length;
          _hasMoreByCategory[category] = false;
          break;
      }
    } catch (error) {
      _lastError = error;
    } finally {
      if (_refreshRequestSerial[category] == requestId) {
        _commitPresentation('asmr_loading_end_${category.name}', () {
          _loadingByCategory[category] = false;
          notifyListeners();
        });
      }
    }
  }

  Future<void> _loadWorks(
    AsmrCategoryType category, {
    required String searchQuery,
    required int requestId,
  }) async {
    final pageResult = await _loadRemotePage(
      category,
      searchQuery: searchQuery,
      page: 1,
    );
    if (_refreshRequestSerial[category] != requestId) {
      return;
    }
    final decorated = pageResult.works
        .map(_decorateWork)
        .toList(growable: false);
    _commitPresentation('asmr_refresh_${category.name}', () {
      if (_refreshRequestSerial[category] != requestId) return;
      _worksByCategory[category] = decorated;
      _bumpCategoryRevision(category);
      _applyPageResult(category, query: searchQuery, pageResult: pageResult);
      notifyListeners();
    });
  }

  Future<void> _loadRecommendedWorks(
    AsmrCategoryType category, {
    required String searchQuery,
    required int requestId,
  }) async {
    final localTracksFuture = _loadLocalTracksForRecommendation();
    final pageResults =
        await Future.wait(<Future<_RecommendationCandidatePageResult>>[
          for (final sourceCategory in _recommendationCandidateCategories)
            _loadRecommendationCandidatePageResult(
              sourceCategory,
              searchQuery: searchQuery,
            ),
        ]);
    if (_refreshRequestSerial[category] != requestId) {
      return;
    }
    Object? firstError;
    final pageGroups = <List<AsmrWorkPage>>[];
    for (final result in pageResults) {
      final error = result.error;
      if (error != null) {
        firstError ??= error;
      }
      pageGroups.add(result.pages);
    }
    final candidatesById = <int, AsmrWork>{};
    for (final page in pageGroups.expand((group) => group)) {
      for (final work in page.works) {
        candidatesById.putIfAbsent(work.id, () => work);
      }
    }
    if (candidatesById.isEmpty && firstError != null) {
      throw firstError;
    }
    final localTracks = await localTracksFuture;
    if (_refreshRequestSerial[category] != requestId) {
      return;
    }
    final ranked = _recommendationEngine.rank(
      candidates: candidatesById.values.map(_decorateWork).toList(),
      localTracks: localTracks,
      favoriteWorks: _favoriteWorks,
      historyWorks: _historyWorks,
      refreshSeed: requestId,
    );
    _worksByCategory[category] = ranked;
    _bumpCategoryRevision(category);
    _applyPageResult(
      category,
      query: searchQuery,
      pageResult: AsmrWorkPage(
        works: ranked,
        currentPage: 1,
        pageSize: ranked.length,
        totalCount: ranked.length,
      ),
    );
    _hasMoreByCategory[category] = false;
  }

  Future<_RecommendationCandidatePageResult>
  _loadRecommendationCandidatePageResult(
    AsmrCategoryType category, {
    required String searchQuery,
  }) async {
    try {
      return _RecommendationCandidatePageResult(
        pages: await _loadRecommendationCandidatePages(
          category,
          searchQuery: searchQuery,
        ),
      );
    } catch (error) {
      debugPrint(
        'AsmrLibraryController recommendation candidate load error '
        '($category): $error',
      );
      return _RecommendationCandidatePageResult(error: error);
    }
  }

  Future<List<AsmrWorkPage>> _loadRecommendationCandidatePages(
    AsmrCategoryType category, {
    required String searchQuery,
  }) async {
    final pages = <AsmrWorkPage>[];
    var page = await _loadRemotePage(
      category,
      searchQuery: searchQuery,
      page: 1,
    );
    pages.add(page);
    while (page.hasMore &&
        pages.length < _recommendationCandidatePagesPerRefresh) {
      page = await _loadRemotePage(
        category,
        searchQuery: searchQuery,
        page: pages.length + 1,
      );
      pages.add(page);
    }
    return pages;
  }

  Future<List<MusicTrack>> _loadLocalTracksForRecommendation() async {
    try {
      return await _audioDatabaseRepository.loadAllTracks();
    } catch (error) {
      debugPrint(
        'AsmrLibraryController recommendation local load error: $error',
      );
      return const <MusicTrack>[];
    }
  }

  Future<AsmrWorkPage> _loadRemotePage(
    AsmrCategoryType category, {
    required String searchQuery,
    required int page,
  }) async {
    final spec = _sortSpecFor(category);
    final pageSize = _pageSizes[category] ?? 40;
    return _retryTransientRemoteLoad(
      category: category,
      page: page,
      load: () {
        if (searchQuery.isNotEmpty) {
          return _apiService.searchWorks(
            keyword: searchQuery,
            order: spec.order,
            sort: spec.sort,
            page: page,
            pageSize: pageSize,
            token: _authSession?.token,
            language: _contentLanguage,
          );
        }
        return _apiService.fetchWorks(
          order: spec.order,
          sort: spec.sort,
          page: page,
          pageSize: pageSize,
          token: _authSession?.token,
          language: _contentLanguage,
        );
      },
    );
  }

  Future<AsmrWorkPage> _retryTransientRemoteLoad({
    required AsmrCategoryType category,
    required int page,
    required Future<AsmrWorkPage> Function() load,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await load();
      } catch (error) {
        if (attempt >= _transientRemoteLoadRetryDelays.length ||
            !_isTransientRemoteLoadError(error)) {
          rethrow;
        }
        debugPrint(
          'AsmrLibraryController transient load error '
          '(${category.name}, page $page), retrying: $error',
        );
        await Future<void>.delayed(_transientRemoteLoadRetryDelays[attempt]);
      }
    }
  }

  bool _isTransientRemoteLoadError(Object error) {
    if (error is HandshakeException ||
        error is SocketException ||
        error is TimeoutException) {
      return true;
    }
    if (error is AsmrApiException) {
      final statusCode = error.statusCode;
      return statusCode == HttpStatus.tooManyRequests || statusCode >= 500;
    }
    return false;
  }

  ({String order, String sort}) _sortSpecFor(AsmrCategoryType category) {
    switch (category) {
      case AsmrCategoryType.collected:
        return (order: 'create_date', sort: 'desc');
      case AsmrCategoryType.recommendation:
        return (order: 'create_date', sort: 'desc');
      case AsmrCategoryType.sales:
        return (order: 'dl_count', sort: 'desc');
      case AsmrCategoryType.rating:
        return (order: 'rate_average_2dp', sort: 'desc');
      case AsmrCategoryType.reviews:
        return (order: 'review_count', sort: 'desc');
      case AsmrCategoryType.release:
        return (order: 'release', sort: 'desc');
      case AsmrCategoryType.favorites:
      case AsmrCategoryType.history:
        return (order: 'release', sort: 'desc');
    }
  }

  void _applyPageResult(
    AsmrCategoryType category, {
    required String query,
    required AsmrWorkPage pageResult,
  }) {
    _queryByCategory[category] = query;
    _currentPageByCategory[category] = pageResult.currentPage;
    _totalCountByCategory[category] = pageResult.totalCount;
    _hasMoreByCategory[category] = pageResult.hasMore;
  }

  AsmrWork _decorateWork(AsmrWork work) {
    return work.copyWith(isFavorite: _favoriteIds.contains(work.id));
  }

  Future<AsmrWorkDetail> loadWorkDetail(AsmrWork work) async {
    final cached = _detailCache.remove(work.id);
    if (cached != null) {
      _detailCache[work.id] = cached;
      return cached;
    }
    final detail = await _apiService.fetchWorkDetail(
      work.id,
      token: _authSession?.token,
      language: _contentLanguage,
    );
    final merged = AsmrWorkDetail(
      work: _decorateWork(detail.work),
      description: detail.description,
      ageCategory: detail.ageCategory,
      languageEditionLabels: detail.languageEditionLabels,
      userRating: detail.userRating,
    );
    _storeDetail(merged);
    return merged;
  }

  Future<List<MusicTrack>> loadPlayableTracks(AsmrWork work) async {
    final tree =
        _cachedTrackTree(work.id) ??
        await _apiService.fetchTrackTree(work.id, token: _authSession?.token);
    _storeTrackTree(work.id, tree);
    return _flattenTracks(work, tree);
  }

  List<MusicTrack> buildPlayableTracksFromNode(
    AsmrWork work,
    AsmrTrackFile node,
  ) {
    return _flattenTracks(work, <AsmrTrackFile>[node]);
  }

  Future<List<MusicTrack>> loadPlayableTracksStartingAt(
    AsmrWork work,
    AsmrTrackFile target,
  ) async {
    final tracks = await loadPlayableTracks(work);
    final targetTrackPath = target.toMusicTrack().path;
    final targetIndex = tracks.indexWhere(
      (track) => track.path == targetTrackPath,
    );
    if (targetIndex <= 0) return tracks;
    return <MusicTrack>[
      ...tracks.skip(targetIndex),
      ...tracks.take(targetIndex),
    ];
  }

  List<MusicTrack> _flattenTracks(
    AsmrWork work,
    Iterable<AsmrTrackFile> roots, {
    bool Function(AsmrTrackFile node)? includeAudioNode,
  }) {
    final result = <MusicTrack>[];
    final subtitleByStem = <String, AsmrTrackFile>{};
    final subtitlesByBaseName = <String, List<AsmrTrackFile>>{};

    void indexSubtitles(Iterable<AsmrTrackFile> nodes) {
      for (final node in nodes) {
        if (node.isSubtitle) {
          subtitleByStem.putIfAbsent(node.stemKey, () => node);
          subtitlesByBaseName
              .putIfAbsent(node.baseNameStem, () => <AsmrTrackFile>[])
              .add(node);
        }
        if (node.children.isNotEmpty) {
          indexSubtitles(node.children);
        }
      }
    }

    Map<String, Object?> remoteMetadataForTrack(AsmrTrackFile node) {
      final metadata = Map<String, Object?>.from(work.toJson());
      metadata['trackRelativePath'] = node.relativePath;
      metadata['trackDirectoryPath'] = path.dirname(node.relativePath);
      final subtitle =
          subtitleByStem[node.stemKey] ??
          switch (subtitlesByBaseName[node.baseNameStem]) {
            final List<AsmrTrackFile> matches when matches.length == 1 =>
              matches.first,
            _ => null,
          };
      final subtitleUrl = (subtitle?.streamUrl ?? subtitle?.downloadUrl ?? '')
          .trim();
      if (subtitleUrl.isEmpty) {
        return metadata;
      }
      metadata['subtitleUrl'] = subtitleUrl;
      metadata['subtitleExtension'] = subtitle!.resolvedExtension;
      metadata['subtitleSourcePath'] = subtitle.relativePath;
      metadata['subtitleTitle'] = subtitle.title;
      return metadata;
    }

    indexSubtitles(roots);

    void visit(Iterable<AsmrTrackFile> nodes) {
      for (final node in nodes) {
        if (node.isAudio) {
          if (includeAudioNode != null && !includeAudioNode(node)) {
            continue;
          }
          final usesOfficialMedia = <String?>[
            node.streamUrl,
            node.downloadUrl,
            node.lowQualityUrl,
          ].any(AsmrApiService.isOfficialMediaUrl);
          final track = node.toMusicTrack(
            groupTitleOverride: work.title,
            remoteCoverUrl: work.preferredCoverUrl,
            remoteMetadataKind: 'asmr.one',
            remoteMetadata: remoteMetadataForTrack(node),
            preferredPlaybackUrls: usesOfficialMedia
                ? AsmrApiService.mediaStreamUrlsForHash(node.hash)
                : const <String>[],
          );
          if (track.path.isNotEmpty) {
            result.add(track);
          }
          continue;
        }
        if (node.children.isNotEmpty) {
          visit(node.children);
        }
      }
    }

    visit(roots);
    return result;
  }

  Future<List<AsmrTrackFile>> ensureTrackTree(AsmrWork work) async {
    final cached = _cachedTrackTree(work.id);
    if (cached != null) {
      return cached;
    }
    if (_loadingTrackWorkIds.add(work.id)) {
      _bumpTrackRevision(work.id);
      notifyListeners();
    }
    try {
      final tree = await _apiService.fetchTrackTree(
        work.id,
        token: _authSession?.token,
      );
      _storeTrackTree(work.id, tree);
      _bumpTrackRevision(work.id);
      return tree;
    } finally {
      _loadingTrackWorkIds.remove(work.id);
      _trimTrackCache();
      _bumpTrackRevision(work.id);
      notifyListeners();
    }
  }

  Future<void> toggleFavorite(AsmrWork work) async {
    final existingIndex = _favoriteWorks.indexWhere(
      (item) => item.id == work.id,
    );
    final shouldFavorite = existingIndex < 0;
    final updatedWork = work.copyWith(isFavorite: shouldFavorite);
    final nextFavoriteWorks = shouldFavorite
        ? <AsmrWork>[
            updatedWork,
            ..._favoriteWorks.where((item) => item.id != work.id),
          ]
        : _favoriteWorks
              .where((item) => item.id != work.id)
              .toList(growable: false);
    final operation = AsmrSyncOperation(
      type: shouldFavorite
          ? AsmrSyncOperationType.favoriteAdd
          : AsmrSyncOperationType.favoriteRemove,
      workId: work.id,
      sourceId: work.sourceId,
      createdAt: DateTime.now(),
    );
    final nextSyncOperations = _syncOperationsAfterEnqueue(operation);
    await AsmrPreferences.saveWorkListAndSyncOperations(
      'favorites',
      nextFavoriteWorks,
      nextSyncOperations,
    );

    _favoriteWorks = nextFavoriteWorks;
    _syncOperations = nextSyncOperations;
    _favoriteIds = _favoriteWorks.map((item) => item.id).toSet();
    final cachedDetail = _detailCache.remove(work.id);
    _storeDetail(
      cachedDetail == null
          ? AsmrWorkDetail(
              work: updatedWork,
              description: '',
              ageCategory: '',
              languageEditionLabels: const <String>[],
              userRating: null,
            )
          : AsmrWorkDetail(
              work: updatedWork,
              description: cachedDetail.description,
              ageCategory: cachedDetail.ageCategory,
              languageEditionLabels: cachedDetail.languageEditionLabels,
              userRating: cachedDetail.userRating,
            ),
    );
    for (final entry in _worksByCategory.entries) {
      _worksByCategory[entry.key] = entry.value
          .map(
            (item) => item.id == work.id
                ? item.copyWith(isFavorite: shouldFavorite)
                : item,
          )
          .toList(growable: false);
      _bumpCategoryRevision(entry.key);
    }
    _bumpGlobalRevision();
    if (isAsmrAccountLoggedIn) {
      unawaited(syncAsmrAccount());
    }
    _updateLocalCategoryCounts();
    _bumpCategoryRevision(AsmrCategoryType.favorites);
    notifyListeners();
  }

  Future<void> recordHistory(AsmrWork work) async {
    final nextHistoryWorks = <AsmrWork>[
      work,
      ..._historyWorks.where((item) => item.id != work.id),
    ].take(_historyLimit).toList(growable: false);
    final operation = AsmrSyncOperation(
      type: AsmrSyncOperationType.historyListening,
      workId: work.id,
      sourceId: work.sourceId,
      createdAt: DateTime.now(),
    );
    final nextSyncOperations = _syncOperationsAfterEnqueue(operation);
    await AsmrPreferences.saveWorkListAndSyncOperations(
      'history',
      nextHistoryWorks,
      nextSyncOperations,
    );

    _historyWorks = nextHistoryWorks;
    _syncOperations = nextSyncOperations;
    _bumpGlobalRevision();
    if (isAsmrAccountLoggedIn) {
      unawaited(syncAsmrAccount());
    }
    _updateLocalCategoryCounts();
    _bumpCategoryRevision(AsmrCategoryType.history);
    notifyListeners();
  }

  Future<void> playWork(
    AudioProvider provider,
    AsmrWork work, {
    bool? autoPlay,
  }) async {
    final tracks = await loadPlayableTracks(work);
    if (tracks.isEmpty) {
      return;
    }
    await recordHistory(work);
    await provider.spawnSessionWithQueue(
      tracks,
      autoPlay: autoPlay,
      loopMode: tracks.length > 1
          ? SessionLoopMode.folderSequential
          : SessionLoopMode.single,
    );
  }

  Future<void> playTrack(
    AudioProvider provider,
    AsmrWork work,
    AsmrTrackFile target, {
    bool? autoPlay,
  }) async {
    final queue = await loadPlayableTracksStartingAt(work, target);
    if (queue.isEmpty) {
      return;
    }
    await recordHistory(work);
    await provider.spawnSessionWithQueue(
      queue,
      autoPlay: autoPlay,
      loopMode: queue.length > 1
          ? SessionLoopMode.folderSequential
          : SessionLoopMode.single,
    );
  }

  List<AsmrSyncOperation> _syncOperationsAfterEnqueue(
    AsmrSyncOperation operation,
  ) {
    final withoutSuperseded = _syncOperations
        .where((existing) {
          if (existing.workId != operation.workId) {
            return true;
          }
          if (operation.type == AsmrSyncOperationType.favoriteAdd ||
              operation.type == AsmrSyncOperationType.favoriteRemove) {
            return existing.type != AsmrSyncOperationType.favoriteAdd &&
                existing.type != AsmrSyncOperationType.favoriteRemove;
          }
          return existing.type != operation.type;
        })
        .toList(growable: true);
    withoutSuperseded.add(operation);
    return withoutSuperseded;
  }

  Future<void> _seedSyncOutboxIfNeeded() async {
    if (await AsmrPreferences.isSyncOutboxSeeded()) {
      return;
    }
    final existingKeys = _syncOperations
        .map((operation) => '${operation.type.name}:${operation.workId}')
        .toSet();
    final seeded = <AsmrSyncOperation>[];
    var createdAt = DateTime.now().subtract(
      Duration(milliseconds: _favoriteWorks.length + _historyWorks.length),
    );
    for (final work in _historyWorks.reversed) {
      final key = '${AsmrSyncOperationType.historyListening.name}:${work.id}';
      if (existingKeys.add(key)) {
        seeded.add(
          AsmrSyncOperation(
            type: AsmrSyncOperationType.historyListening,
            workId: work.id,
            sourceId: work.sourceId,
            createdAt: createdAt,
          ),
        );
        createdAt = createdAt.add(const Duration(milliseconds: 1));
      }
    }
    for (final work in _favoriteWorks.reversed) {
      final key = '${AsmrSyncOperationType.favoriteAdd.name}:${work.id}';
      if (existingKeys.add(key)) {
        seeded.add(
          AsmrSyncOperation(
            type: AsmrSyncOperationType.favoriteAdd,
            workId: work.id,
            sourceId: work.sourceId,
            createdAt: createdAt,
          ),
        );
        createdAt = createdAt.add(const Duration(milliseconds: 1));
      }
    }
    if (seeded.isNotEmpty) {
      _syncOperations = <AsmrSyncOperation>[..._syncOperations, ...seeded];
      await AsmrPreferences.saveSyncOperations(_syncOperations);
    }
    await AsmrPreferences.markSyncOutboxSeeded();
  }

  Future<List<AsmrSyncOperation>> _flushSyncOperations(
    String token,
    List<AsmrSyncOperation> batch,
  ) async {
    if (batch.isEmpty) {
      return const <AsmrSyncOperation>[];
    }
    final uploaded = <AsmrSyncOperation>[];
    var hadFailure = false;
    for (final operation in batch) {
      if (!_syncOperations.any((item) => identical(item, operation))) {
        continue;
      }
      try {
        switch (operation.type) {
          case AsmrSyncOperationType.favoriteAdd:
            await _apiService.putReviewProgress(
              workId: operation.workId,
              progress: 'marked',
              token: token,
            );
            _remoteProgressByWorkId = <int, String>{
              ..._remoteProgressByWorkId,
              operation.workId: 'marked',
            };
            break;
          case AsmrSyncOperationType.favoriteRemove:
            if (_remoteProgressByWorkId[operation.workId] == 'marked') {
              await _apiService.deleteReview(
                workId: operation.workId,
                token: token,
              );
              _remoteProgressByWorkId = <int, String>{
                ..._remoteProgressByWorkId,
              }..remove(operation.workId);
            }
            if (_historyWorks.any((work) => work.id == operation.workId)) {
              await _apiService.putReviewProgress(
                workId: operation.workId,
                progress: 'listening',
                token: token,
              );
              _remoteProgressByWorkId = <int, String>{
                ..._remoteProgressByWorkId,
                operation.workId: 'listening',
              };
            }
            break;
          case AsmrSyncOperationType.historyListening:
            if (_favoriteIds.contains(operation.workId)) {
              await _apiService.putReviewProgress(
                workId: operation.workId,
                progress: 'marked',
                token: token,
              );
              _remoteProgressByWorkId = <int, String>{
                ..._remoteProgressByWorkId,
                operation.workId: 'marked',
              };
            } else if (!_isRemoteProgressProtected(operation.workId)) {
              await _apiService.putReviewProgress(
                workId: operation.workId,
                progress: 'listening',
                token: token,
              );
              _remoteProgressByWorkId = <int, String>{
                ..._remoteProgressByWorkId,
                operation.workId: 'listening',
              };
            }
            break;
        }
        uploaded.add(operation);
      } catch (error) {
        if (AsmrApiException.isAuthenticationError(error)) {
          rethrow;
        }
        hadFailure = true;
        final index = _syncOperations.indexWhere(
          (item) => identical(item, operation),
        );
        if (index >= 0) {
          final updated = _syncOperations.toList(growable: true);
          updated[index] = operation.copyWith(
            retryCount: operation.retryCount + 1,
          );
          _syncOperations = updated;
        }
      }
    }
    if (hadFailure) {
      _syncOperations = _syncOperations
          .where(
            (operation) => !uploaded.any(
              (uploadedOperation) => identical(uploadedOperation, operation),
            ),
          )
          .toList(growable: false);
      await AsmrPreferences.saveSyncOperations(_syncOperations);
      throw const HttpException('ASMR sync operations failed.');
    }
    return uploaded;
  }

  Future<void> _preflightProtectedRemoteProgress(String token) async {
    const protectedFilters = <String>[
      'marked',
      'listened',
      'replay',
      'postponed',
    ];
    final pages = await Future.wait(
      protectedFilters.map((filter) => _fetchAllReviewRecords(token, filter)),
    );
    _remoteProgressByWorkId = <int, String>{
      for (final record in pages.expand((records) => records))
        record.work.id: record.progress,
    };
  }

  bool _isRemoteProgressProtected(int workId) {
    final progress = _remoteProgressByWorkId[workId];
    return progress == 'marked' ||
        progress == 'listened' ||
        progress == 'replay' ||
        progress == 'postponed';
  }

  Future<void> _mergeRemoteMarkedFavorites(
    List<AsmrReviewRecord> records,
  ) async {
    final pendingRemoves = _syncOperations
        .where(
          (operation) => operation.type == AsmrSyncOperationType.favoriteRemove,
        )
        .map((operation) => operation.workId)
        .toSet();
    final pendingAdds =
        _syncOperations
            .where(
              (operation) =>
                  operation.type == AsmrSyncOperationType.favoriteAdd,
            )
            .toList(growable: false)
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final sortedRecords =
        records
            .where((record) => record.progress == 'marked')
            .toList(growable: false)
          ..sort(_compareReviewRecordsNewestFirst);
    final byId = <int, AsmrWork>{};
    for (final operation in pendingAdds) {
      final work = _favoriteWorks
          .where((work) => work.id == operation.workId)
          .firstOrNull;
      if (work != null && !pendingRemoves.contains(work.id)) {
        byId[work.id] = work.copyWith(isFavorite: true);
      }
    }
    for (final work in _favoriteWorks) {
      if (!pendingRemoves.contains(work.id)) {
        byId[work.id] = work.copyWith(isFavorite: true);
      }
    }
    for (final record in sortedRecords) {
      final work = record.work;
      if (!pendingRemoves.contains(work.id)) {
        byId[work.id] = _decorateWork(work).copyWith(isFavorite: true);
      }
    }
    _favoriteWorks = byId.values.toList(growable: false);
    _favoriteIds = _favoriteWorks.map((work) => work.id).toSet();
    await AsmrPreferences.saveFavoriteWorks(_favoriteWorks);
  }

  Future<void> _pullRemoteReviewState(String token) async {
    const filters = <String>[
      'marked',
      'listening',
      'listened',
      'replay',
      'postponed',
    ];
    final pages = await Future.wait(
      filters.map((filter) => _fetchAllReviewRecords(token, filter)),
    );
    final records = pages.expand((records) => records).toList(growable: false);
    _remoteProgressByWorkId = <int, String>{
      for (final record in records) record.work.id: record.progress,
    };
    await _mergeRemoteMarkedFavorites(records);
    await _mergeRemoteHistory(records);
  }

  Future<List<AsmrReviewRecord>> _fetchAllReviewRecords(
    String token,
    String filter,
  ) async {
    final records = <AsmrReviewRecord>[];
    var page = 1;
    while (true) {
      final pageRecords = await _apiService.fetchReviews(
        token: token,
        filter: filter,
        page: page,
        language: _contentLanguage,
      );
      if (pageRecords.isEmpty) {
        break;
      }
      records.addAll(pageRecords);
      page++;
    }
    return records;
  }

  Future<void> _mergeRemoteHistory(List<AsmrReviewRecord> records) async {
    final historyRecords = records
        .where((record) => record.progress != 'marked')
        .toList(growable: false);
    if (historyRecords.isEmpty && _historyWorks.isEmpty) {
      return;
    }
    historyRecords.sort(_compareReviewRecordsNewestFirst);

    final merged = <AsmrWork>[];
    final seenIds = <int>{};

    for (final work in _historyWorks) {
      if (seenIds.add(work.id)) {
        merged.add(_decorateWork(work));
      }
    }

    for (final record in historyRecords) {
      if (seenIds.add(record.work.id)) {
        merged.add(_decorateWork(record.work));
      }
    }

    _historyWorks = merged.take(_historyLimit).toList(growable: false);
    await AsmrPreferences.saveHistoryWorks(_historyWorks);
  }

  static int _compareReviewRecordsNewestFirst(
    AsmrReviewRecord a,
    AsmrReviewRecord b,
  ) {
    final left = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final right = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final byTime = right.compareTo(left);
    return byTime != 0 ? byTime : b.work.id.compareTo(a.work.id);
  }

  bool _matchesQuery(AsmrWork work, String query, {List<String>? terms}) {
    final haystacks = <String>[
      work.title,
      work.circleName,
      work.rjCode,
      ...work.tags,
      ...work.voiceActors,
    ];
    return matchesSearchTerms(haystacks, query, terms: terms);
  }

  void _updateLocalCategoryCounts() {
    for (final category in <AsmrCategoryType>[
      AsmrCategoryType.favorites,
      AsmrCategoryType.history,
    ]) {
      final query = _queryByCategory[category] ?? '';
      _totalCountByCategory[category] = filteredWorksFor(
        category,
        searchQuery: query,
      ).length;
    }
  }

  int _categoryRevisionFor(AsmrCategoryType category) {
    return _categoryRevisions[category] ?? 0;
  }

  void _bumpCategoryRevision(AsmrCategoryType category) {
    _categoryRevisions[category] = _categoryRevisionFor(category) + 1;
    _filteredWorksCache.removeWhere((key, _) => key.category == category);
  }

  void _bumpTrackRevision(int workId) {
    _trackRevisions[workId] = (_trackRevisions[workId] ?? 0) + 1;
  }

  void _bumpAllTrackRevisions() {
    for (final workId in _trackRevisions.keys.toList(growable: false)) {
      _bumpTrackRevision(workId);
    }
  }

  void _bumpGlobalRevision() {
    _globalRevision++;
  }

  void _storeDetail(AsmrWorkDetail detail) {
    _detailCache.remove(detail.work.id);
    _detailCache[detail.work.id] = detail;
    while (_detailCache.length > _detailCacheLimit) {
      _detailCache.remove(_detailCache.keys.first);
    }
  }

  List<AsmrTrackFile>? _cachedTrackTree(int workId) {
    final cached = _trackCache.remove(workId);
    if (cached != null) _trackCache[workId] = cached;
    return cached;
  }

  void _storeTrackTree(int workId, List<AsmrTrackFile> tree) {
    _trackCache.remove(workId);
    _trackCache[workId] = tree;
    _visibleTrackCache.remove(workId);
    _trimTrackCache();
  }

  void _trimTrackCache() {
    while (_trackCache.length > _trackCacheLimit) {
      final evictedWorkId = _trackCache.keys.firstWhere(
        (workId) => !_loadingTrackWorkIds.contains(workId),
        orElse: () => -1,
      );
      if (evictedWorkId < 0) return;
      _trackCache.remove(evictedWorkId);
      _visibleTrackCache.remove(evictedWorkId);
    }
  }

  List<AsmrTrackFile> _visibleTrackTreeFor(
    int workId,
    List<AsmrTrackFile> tree,
  ) {
    final cached = _visibleTrackCache.remove(workId);
    if (cached != null) {
      _visibleTrackCache[workId] = cached;
      return cached;
    }
    final visible = tree
        .where((node) => node.hasBrowsableContent)
        .toList(growable: false);
    _visibleTrackCache[workId] = visible;
    while (_visibleTrackCache.length > _trackCacheLimit) {
      _visibleTrackCache.remove(_visibleTrackCache.keys.first);
    }
    return visible;
  }

  static List<AsmrCategoryType> _sanitizeVisibleCategories(
    List<AsmrCategoryType> categories,
  ) {
    final result = <AsmrCategoryType>[];
    for (final category in categories) {
      if (!kAsmrSelectableCategories.contains(category) ||
          result.contains(category)) {
        continue;
      }
      result.add(category);
      if (!Platform.isWindows && result.length == 5) {
        break;
      }
    }
    return result.isEmpty
        ? kDefaultVisibleAsmrCategories
        : result.toList(growable: false);
  }
}
