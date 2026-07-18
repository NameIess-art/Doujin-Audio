import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../../app/application/persisted_state_reloader.dart';
import '../domain/asmr_models.dart';
import '../../../core/media/music_track.dart';
import '../../../core/persistence/audio_database_repository.dart';
import 'asmr_api_service.dart';
import 'asmr_account_sync_service.dart';
import 'asmr_auth_service.dart';
import 'asmr_playback_coordinator.dart';
import 'asmr_preferences.dart';
import 'asmr_remote_catalog_service.dart';
import '../../../core/app_language.dart';
import '../../../core/media/search_query_utils.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';

class AsmrLibraryGlobalViewState {
  const AsmrLibraryGlobalViewState({
    required this.initialized,
    required this.lastError,
    required this.visibleCategories,
    required this.contentLanguage,
    required this.contentLanguagePreference,
    required this.revision,
  });

  final bool initialized;
  final Object? lastError;
  final List<AsmrCategoryType> visibleCategories;
  final AsmrContentLanguage contentLanguage;
  final ContentLanguagePreference contentLanguagePreference;
  final int revision;

  @override
  bool operator ==(Object other) {
    return other is AsmrLibraryGlobalViewState &&
        initialized == other.initialized &&
        lastError == other.lastError &&
        listEquals(visibleCategories, other.visibleCategories) &&
        contentLanguage == other.contentLanguage &&
        contentLanguagePreference == other.contentLanguagePreference &&
        revision == other.revision;
  }

  @override
  int get hashCode => Object.hash(
    initialized,
    lastError,
    Object.hashAll(visibleCategories),
    contentLanguage,
    contentLanguagePreference,
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
    required this.isRestoring,
    required this.userName,
    required this.revision,
  });

  final bool isLoggedIn;
  final bool isRestoring;
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

typedef _AsmrWorkRequestKey = ({int workId, int contentEpoch, int authEpoch});
typedef _AsmrSyncRequestKey = ({int authEpoch, String token});
typedef _AsmrCategoryRequestKey = ({
  int authEpoch,
  String? token,
  int contentEpoch,
  int requestSerial,
});

class AsmrLibraryController extends ChangeNotifier
    implements AsmrPlaybackSource, PersistedStateReloader {
  AsmrLibraryController({
    AsmrApiService? apiService,
    AsmrAuthService? authService,
    AudioDatabaseRepository? audioDatabaseRepository,
    required AsmrPreferencesStore preferencesStore,
    AsmrRemoteCatalogService? remoteCatalogService,
    AsmrAccountSyncService? accountSyncService,
  }) : _preferencesStore = preferencesStore,
       _remoteCatalogService =
           remoteCatalogService ??
           AsmrRemoteCatalogService(
             apiService: apiService ?? AsmrApiService(),
             audioDatabaseRepository:
                 audioDatabaseRepository ?? AudioDatabaseRepository(),
           ),
       _accountSyncService =
           accountSyncService ??
           AsmrAccountSyncService(
             authService:
                 authService ?? AsmrAuthService(apiService: apiService),
             apiService: apiService ?? AsmrApiService(),
             preferencesStore: preferencesStore,
           );

  static const int _detailCacheLimit = 128;
  static const int _trackCacheLimit = 32;
  static const int _filteredWorksCacheLimit = 24;
  final AsmrPreferencesStore _preferencesStore;
  final AsmrRemoteCatalogService _remoteCatalogService;
  final AsmrAccountSyncService _accountSyncService;
  final Map<AsmrCategoryType, Future<void>> _refreshTasks =
      <AsmrCategoryType, Future<void>>{};
  final Map<AsmrCategoryType, String> _refreshTaskQueries =
      <AsmrCategoryType, String>{};
  final Map<AsmrCategoryType, _AsmrCategoryRequestKey> _refreshTaskKeys =
      <AsmrCategoryType, _AsmrCategoryRequestKey>{};
  final Map<AsmrCategoryType, int> _refreshRequestSerial =
      <AsmrCategoryType, int>{};
  final Map<AsmrCategoryType, String> _pendingAuthCategoryRefreshes =
      <AsmrCategoryType, String>{};
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
  final Map<int, Object> _trackTreeErrors = <int, Object>{};
  final Map<_AsmrWorkRequestKey, Future<AsmrWorkDetail>> _detailTasks =
      <_AsmrWorkRequestKey, Future<AsmrWorkDetail>>{};
  final Map<_AsmrWorkRequestKey, Future<List<AsmrTrackFile>>> _trackTreeTasks =
      <_AsmrWorkRequestKey, Future<List<AsmrTrackFile>>>{};
  final Map<AsmrCategoryType, int> _categoryRevisions =
      <AsmrCategoryType, int>{};
  final Map<int, int> _trackRevisions = <int, int>{};
  final LinkedHashMap<_AsmrFilteredWorksCacheKey, List<AsmrWork>>
  _filteredWorksCache = LinkedHashMap();

  List<AsmrCategoryType> _visibleCategories = kDefaultVisibleAsmrCategories;
  ContentLanguagePreference _contentLanguagePreference =
      ContentLanguagePreference.followPage;
  AppLanguage _pageLanguage = AppLanguage.zh;
  AsmrContentLanguage _contentLanguage = AsmrContentLanguage.zh;
  List<AsmrWork> _favoriteWorks = const <AsmrWork>[];
  Set<int> _favoriteIds = const <int>{};
  List<AsmrWork> _historyWorks = const <AsmrWork>[];
  List<AsmrSyncOperation> _syncOperations = const <AsmrSyncOperation>[];
  AsmrAuthSession? _authSession;
  AsmrSyncPhase _syncPhase = AsmrSyncPhase.idle;
  DateTime? _lastSyncAt;
  Object? _lastSyncError;
  Future<void>? _initializeTask;
  Future<void>? _authRestoreTask;
  final Map<_AsmrSyncRequestKey, Future<void>> _syncTasks =
      <_AsmrSyncRequestKey, Future<void>>{};
  AsmrSyncCancellationToken? _activeSyncCancellationToken;
  Future<void> _stateMutationTail = Future<void>.value();
  bool _initialized = false;
  Object? _lastError;
  int _globalRevision = 0;
  int _authEpoch = 0;
  int _contentEpoch = 0;

  void _commitPresentation(
    String key,
    VoidCallback commit, {
    bool Function()? isCurrent,
    bool preserveAcrossUiGenerations = false,
  }) {
    final coordinator = UiInteractionCoordinator.instance;
    final uiGeneration = coordinator.generation;
    void guardedCommit() {
      if (isCurrent != null && !isCurrent()) return;
      commit();
    }

    if (coordinator.isInteracting) {
      coordinator.scheduleCommit(
        key: key,
        generation: preserveAcrossUiGenerations ? null : uiGeneration,
        priority: 10,
        commit: guardedCommit,
      );
    } else {
      guardedCommit();
    }
  }

  Future<T> _runStateMutation<T>(Future<T> Function() mutation) {
    final result = _stateMutationTail.then((_) => mutation());
    _stateMutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  _AsmrWorkRequestKey _workRequestKey(int workId) =>
      (workId: workId, contentEpoch: _contentEpoch, authEpoch: _authEpoch);

  bool _isWorkRequestCurrent(_AsmrWorkRequestKey key) =>
      key.contentEpoch == _contentEpoch && key.authEpoch == _authEpoch;

  _AsmrCategoryRequestKey _categoryRequestKey(int requestSerial) => (
    authEpoch: _authEpoch,
    token: _authSession?.token,
    contentEpoch: _contentEpoch,
    requestSerial: requestSerial,
  );

  bool _isCategoryRequestCurrent(
    AsmrCategoryType category,
    _AsmrCategoryRequestKey key,
  ) =>
      key.authEpoch == _authEpoch &&
      key.token == _authSession?.token &&
      key.contentEpoch == _contentEpoch &&
      key.requestSerial == _refreshRequestSerial[category];

  bool _isRemoteCategory(AsmrCategoryType category) =>
      category != AsmrCategoryType.favorites &&
      category != AsmrCategoryType.history;

  void _invalidateCategoryRequestsForAuthChange() {
    for (final category in AsmrCategoryType.values) {
      if (_isRemoteCategory(category) &&
          (_queryByCategory.containsKey(category) ||
              _worksByCategory.containsKey(category) ||
              _refreshTaskQueries.containsKey(category))) {
        _pendingAuthCategoryRefreshes.putIfAbsent(
          category,
          () =>
              _refreshTaskQueries[category] ?? _queryByCategory[category] ?? '',
        );
      }
      _refreshRequestSerial[category] =
          (_refreshRequestSerial[category] ?? 0) + 1;
      _loadingByCategory[category] = false;
      _loadingMoreByCategory[category] = false;
      if (_isRemoteCategory(category)) {
        _currentPageByCategory.remove(category);
        _totalCountByCategory.remove(category);
        _hasMoreByCategory.remove(category);
      }
    }
    _refreshTasks.clear();
    _refreshTaskQueries.clear();
    _refreshTaskKeys.clear();
  }

  void _refreshLoadedCategoriesForCurrentAuth() {
    if (_pendingAuthCategoryRefreshes.isEmpty) return;
    final pending = Map<AsmrCategoryType, String>.from(
      _pendingAuthCategoryRefreshes,
    );
    _pendingAuthCategoryRefreshes.clear();
    for (final entry in pending.entries) {
      unawaited(refreshCategory(entry.key, searchQuery: entry.value));
    }
  }

  void _invalidateRemoteWorkCaches() {
    _detailCache.clear();
    _trackCache.clear();
    _visibleTrackCache.clear();
    _trackTreeErrors.clear();
  }

  void _applyAccountSnapshot(AsmrAccountSnapshot snapshot) {
    _authSession = snapshot.session;
    _favoriteWorks = snapshot.favoriteWorks;
    _favoriteIds = snapshot.favoriteIds;
    _historyWorks = snapshot.historyWorks;
    _syncOperations = snapshot.pendingOperations;
    _lastSyncAt = snapshot.lastSyncAt;
  }

  void _cancelActiveSync() {
    _activeSyncCancellationToken?.cancel();
    _activeSyncCancellationToken = null;
  }

  bool get initialized => _initialized;
  Object? get lastError => _lastError;

  List<AsmrCategoryType> get visibleCategories => _visibleCategories;
  ContentLanguagePreference get contentLanguagePreference =>
      _contentLanguagePreference;
  AppLanguage get pageLanguage => _pageLanguage;
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
    contentLanguagePreference: _contentLanguagePreference,
    revision: _globalRevision,
  );

  AsmrAuthViewState get authViewState => AsmrAuthViewState(
    isLoggedIn: isAsmrAccountLoggedIn,
    isRestoring: !_initialized || _authRestoreTask != null,
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
      operationError: _trackTreeErrors[workId],
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
    _visibleCategories = await _preferencesStore.loadVisibleCategories();
    if (defaultLanguage != null) {
      _pageLanguage = defaultLanguage.appLanguage;
    }
    _contentLanguagePreference = await _preferencesStore
        .loadContentLanguagePreference();
    _contentLanguage = _resolveContentLanguage();
    _applyAccountSnapshot(await _accountSyncService.initialize());
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
        _bumpGlobalRevision();
        _commitPresentation('asmr_auth_restore_complete', notifyListeners);
      }
    });
    _authRestoreTask = task;
    _bumpGlobalRevision();
    _commitPresentation('asmr_auth_restore_start', notifyListeners);
    return task;
  }

  Future<void> _restoreAsmrAccountSessionInternal() async {
    final requestEpoch = _authEpoch;
    final previousSession = _authSession;
    try {
      final snapshot = await _accountSyncService.restoreSession();
      if (requestEpoch != _authEpoch) return;
      final restored = snapshot.session;
      if (previousSession?.token == restored?.token &&
          previousSession?.userName == restored?.userName) {
        return;
      }
      _authEpoch++;
      _cancelActiveSync();
      _invalidateCategoryRequestsForAuthChange();
      _invalidateRemoteWorkCaches();
      _applyAccountSnapshot(snapshot);
      _lastSyncError = null;
      _bumpGlobalRevision();
      final appliedEpoch = _authEpoch;
      _commitPresentation(
        'asmr_auth_restore',
        notifyListeners,
        isCurrent: () => appliedEpoch == _authEpoch,
      );
      _refreshLoadedCategoriesForCurrentAuth();
    } catch (error) {
      if (requestEpoch != _authEpoch) return;
      _lastSyncError = error;
      _bumpGlobalRevision();
      _commitPresentation(
        'asmr_auth_restore_error',
        notifyListeners,
        isCurrent: () => requestEpoch == _authEpoch,
      );
    }
  }

  @override
  Future<void> reloadPersistedState() async {
    _initialized = false;
    _worksByCategory.clear();
    _detailCache.clear();
    _trackCache.clear();
    _visibleTrackCache.clear();
    _trackTreeErrors.clear();
    _filteredWorksCache.clear();
    await initialize();
  }

  Future<void> loginAsmrAccount(String name, String password) async {
    var operationEpoch = ++_authEpoch;
    _cancelActiveSync();
    _invalidateCategoryRequestsForAuthChange();
    _invalidateRemoteWorkCaches();
    _authSession = null;
    _syncPhase = AsmrSyncPhase.syncing;
    _lastSyncError = null;
    _bumpGlobalRevision();
    notifyListeners();
    try {
      final snapshot = await _accountSyncService.login(name, password);
      if (operationEpoch != _authEpoch) return;
      operationEpoch = ++_authEpoch;
      _invalidateCategoryRequestsForAuthChange();
      _applyAccountSnapshot(snapshot);
      await syncAsmrAccount(force: true);
      _refreshLoadedCategoriesForCurrentAuth();
    } catch (error) {
      if (operationEpoch != _authEpoch) return;
      _authSession = null;
      _syncPhase = AsmrSyncPhase.failed;
      _lastSyncError = error;
      _bumpGlobalRevision();
      notifyListeners();
      _refreshLoadedCategoriesForCurrentAuth();
      rethrow;
    }
  }

  Future<void> logoutAsmrAccount() async {
    final logoutEpoch = ++_authEpoch;
    _cancelActiveSync();
    _invalidateCategoryRequestsForAuthChange();
    _invalidateRemoteWorkCaches();
    final snapshot = await _accountSyncService.logout();
    if (logoutEpoch != _authEpoch) return;
    _applyAccountSnapshot(snapshot);
    _syncPhase = AsmrSyncPhase.idle;
    _lastSyncError = null;
    _bumpGlobalRevision();
    notifyListeners();
    _refreshLoadedCategoriesForCurrentAuth();
  }

  Future<void> syncAsmrAccount({bool force = false}) {
    final session = _authSession;
    if (session == null || !session.isValid) return Future<void>.value();
    final key = (authEpoch: _authEpoch, token: session.token);
    final existing = _syncTasks[key];
    if (existing != null) {
      return existing;
    }
    late final Future<void> task;
    task = _syncAsmrAccountInternal(key).whenComplete(() {
      if (identical(_syncTasks[key], task)) {
        _syncTasks.remove(key);
      }
    });
    _syncTasks[key] = task;
    return task;
  }

  Future<void> _syncAsmrAccountInternal(_AsmrSyncRequestKey key) async {
    if (key.authEpoch != _authEpoch || key.token != _authSession?.token) return;
    final cancellationToken = AsmrSyncCancellationToken();
    _activeSyncCancellationToken?.cancel();
    _activeSyncCancellationToken = cancellationToken;
    _syncPhase = AsmrSyncPhase.syncing;
    _lastSyncError = null;
    _bumpGlobalRevision();
    notifyListeners();
    var tokenChanged = false;
    try {
      final result = await _accountSyncService.synchronize(
        language: _contentLanguage,
        cancellationToken: cancellationToken,
      );
      if (cancellationToken.isCancelled || key.authEpoch != _authEpoch) return;
      final previousToken = _authSession?.token;
      _applyAccountSnapshot(result.snapshot);
      tokenChanged = _authSession?.token != previousToken;
      if (tokenChanged) {
        _authEpoch++;
        _invalidateCategoryRequestsForAuthChange();
        _invalidateRemoteWorkCaches();
      }
      _syncPhase = result.succeeded
          ? AsmrSyncPhase.succeeded
          : AsmrSyncPhase.failed;
      _lastSyncError = result.failure;
    } on AsmrSyncCancelled {
      return;
    } finally {
      if (identical(_activeSyncCancellationToken, cancellationToken)) {
        _activeSyncCancellationToken = null;
        _updateLocalCategoryCounts();
        _bumpCategoryRevision(AsmrCategoryType.favorites);
        _bumpCategoryRevision(AsmrCategoryType.history);
        _bumpGlobalRevision();
        notifyListeners();
        if (tokenChanged) {
          _refreshLoadedCategoriesForCurrentAuth();
        }
      }
    }
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

  Future<void> setVisibleCategories(List<AsmrCategoryType> categories) async {
    final next = _sanitizeVisibleCategories(categories);
    if (listEquals(next, _visibleCategories)) {
      return;
    }
    _visibleCategories = next;
    await _preferencesStore.saveVisibleCategories(next);
    _bumpGlobalRevision();
    notifyListeners();
  }

  bool setPageLanguage(AppLanguage language) {
    if (_pageLanguage == language) return false;
    _pageLanguage = language;
    if (!_initialized ||
        _contentLanguagePreference != ContentLanguagePreference.followPage) {
      return false;
    }
    final nextLanguage = _resolveContentLanguage();
    if (_contentLanguage == nextLanguage) return false;
    _applyContentLanguage(nextLanguage);
    return true;
  }

  Future<void> setContentLanguage(AsmrContentLanguage language) {
    return setContentLanguagePreference(
      ContentLanguagePreference.fromAppLanguage(language.appLanguage),
    );
  }

  Future<void> setContentLanguagePreference(
    ContentLanguagePreference preference,
  ) async {
    if (_contentLanguagePreference == preference) {
      return;
    }
    _contentLanguagePreference = preference;
    await _preferencesStore.saveContentLanguagePreference(preference);
    final nextLanguage = _resolveContentLanguage();
    if (_contentLanguage == nextLanguage) {
      _bumpGlobalRevision();
      notifyListeners();
      return;
    }
    _applyContentLanguage(nextLanguage);
  }

  AsmrContentLanguage _resolveContentLanguage() {
    return AsmrContentLanguage.fromAppLanguage(
      _contentLanguagePreference.resolve(_pageLanguage),
    );
  }

  void _applyContentLanguage(AsmrContentLanguage language) {
    _contentLanguage = language;
    _contentEpoch++;
    for (final category in AsmrCategoryType.values) {
      _refreshRequestSerial[category] =
          (_refreshRequestSerial[category] ?? 0) + 1;
      _loadingByCategory[category] = false;
      _loadingMoreByCategory[category] = false;
    }
    _refreshTasks.clear();
    _refreshTaskQueries.clear();
    _refreshTaskKeys.clear();
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
  }) async {
    await initialize();
    final existing = _refreshTasks[category];
    final normalizedQuery = normalizeSearchQuery(searchQuery);
    final existingKey = _refreshTaskKeys[category];
    if (existing != null &&
        _refreshTaskQueries[category] == normalizedQuery &&
        existingKey != null &&
        existingKey.authEpoch == _authEpoch &&
        existingKey.token == _authSession?.token &&
        existingKey.contentEpoch == _contentEpoch) {
      return existing;
    }
    final requestId = (_refreshRequestSerial[category] ?? 0) + 1;
    _refreshRequestSerial[category] = requestId;
    final requestKey = _categoryRequestKey(requestId);
    final requestLanguage = _contentLanguage;
    late final Future<void> task;
    task =
        _refreshCategoryInternal(
          category,
          searchQuery: normalizedQuery,
          requestKey: requestKey,
          language: requestLanguage,
        ).whenComplete(() {
          if (identical(_refreshTasks[category], task)) {
            _refreshTasks.remove(category);
            _refreshTaskQueries.remove(category);
            _refreshTaskKeys.remove(category);
          }
        });
    _refreshTasks[category] = task;
    _refreshTaskQueries[category] = normalizedQuery;
    _refreshTaskKeys[category] = requestKey;
    await task;
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

    final requestId = _refreshRequestSerial[category] ?? 0;
    final requestKey = _categoryRequestKey(requestId);
    _loadingMoreByCategory[category] = true;
    _commitPresentation(
      'asmr_loading_more_start_${category.name}',
      notifyListeners,
      isCurrent: () => _isCategoryRequestCurrent(category, requestKey),
    );
    final requestLanguage = _contentLanguage;
    try {
      final page = (_currentPageByCategory[category] ?? 1) + 1;
      final pageResult = await _loadRemotePage(
        category,
        searchQuery: normalizedQuery,
        page: page,
        language: requestLanguage,
        token: requestKey.token,
      );
      if (!_isCategoryRequestCurrent(category, requestKey)) {
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
      _commitPresentation(
        'asmr_page_${category.name}',
        () {
          _worksByCategory[category] = decorated;
          _bumpCategoryRevision(category);
          _applyPageResult(
            category,
            query: normalizedQuery,
            pageResult: pageResult,
          );
          notifyListeners();
        },
        isCurrent: () => _isCategoryRequestCurrent(category, requestKey),
      );
    } catch (error) {
      if (_isCategoryRequestCurrent(category, requestKey)) {
        _lastError = error;
      }
    } finally {
      if (_isCategoryRequestCurrent(category, requestKey)) {
        _commitPresentation(
          'asmr_loading_more_${category.name}',
          () {
            _loadingMoreByCategory[category] = false;
            notifyListeners();
          },
          isCurrent: () => _isCategoryRequestCurrent(category, requestKey),
          preserveAcrossUiGenerations: true,
        );
      }
    }
  }

  Future<void> _refreshCategoryInternal(
    AsmrCategoryType category, {
    required String searchQuery,
    required _AsmrCategoryRequestKey requestKey,
    required AsmrContentLanguage language,
  }) async {
    final normalizedQuery = normalizeSearchQuery(searchQuery);
    _loadingByCategory[category] = true;
    _lastError = null;
    _commitPresentation(
      'asmr_loading_start_${category.name}',
      notifyListeners,
      isCurrent: () => _isCategoryRequestCurrent(category, requestKey),
    );
    try {
      if (!_isCategoryRequestCurrent(category, requestKey)) return;
      switch (category) {
        case AsmrCategoryType.collected:
          await _loadWorks(
            category,
            searchQuery: normalizedQuery,
            requestKey: requestKey,
            language: language,
          );
          break;
        case AsmrCategoryType.recommendation:
          await _loadRecommendedWorks(
            category,
            searchQuery: normalizedQuery,
            requestKey: requestKey,
            language: language,
          );
          break;
        case AsmrCategoryType.sales:
          await _loadWorks(
            category,
            searchQuery: normalizedQuery,
            requestKey: requestKey,
            language: language,
          );
          break;
        case AsmrCategoryType.rating:
          await _loadWorks(
            category,
            searchQuery: normalizedQuery,
            requestKey: requestKey,
            language: language,
          );
          break;
        case AsmrCategoryType.reviews:
          await _loadWorks(
            category,
            searchQuery: normalizedQuery,
            requestKey: requestKey,
            language: language,
          );
          break;
        case AsmrCategoryType.release:
          await _loadWorks(
            category,
            searchQuery: normalizedQuery,
            requestKey: requestKey,
            language: language,
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
      if (_isCategoryRequestCurrent(category, requestKey)) {
        _lastError = error;
      }
    } finally {
      if (_isCategoryRequestCurrent(category, requestKey)) {
        _commitPresentation(
          'asmr_loading_end_${category.name}',
          () {
            _loadingByCategory[category] = false;
            notifyListeners();
          },
          isCurrent: () => _isCategoryRequestCurrent(category, requestKey),
          preserveAcrossUiGenerations: true,
        );
      }
    }
  }

  Future<void> _loadWorks(
    AsmrCategoryType category, {
    required String searchQuery,
    required _AsmrCategoryRequestKey requestKey,
    required AsmrContentLanguage language,
  }) async {
    final pageResult = await _loadRemotePage(
      category,
      searchQuery: searchQuery,
      page: 1,
      language: language,
      token: requestKey.token,
    );
    if (!_isCategoryRequestCurrent(category, requestKey)) {
      return;
    }
    final decorated = pageResult.works
        .map(_decorateWork)
        .toList(growable: false);
    _commitPresentation(
      'asmr_refresh_${category.name}',
      () {
        _worksByCategory[category] = decorated;
        _bumpCategoryRevision(category);
        _applyPageResult(category, query: searchQuery, pageResult: pageResult);
        notifyListeners();
      },
      isCurrent: () => _isCategoryRequestCurrent(category, requestKey),
    );
  }

  Future<void> _loadRecommendedWorks(
    AsmrCategoryType category, {
    required String searchQuery,
    required _AsmrCategoryRequestKey requestKey,
    required AsmrContentLanguage language,
  }) async {
    final ranked = await _remoteCatalogService.loadRecommendations(
      searchQuery: searchQuery,
      language: language,
      token: requestKey.token,
      favoriteWorks: _favoriteWorks,
      historyWorks: _historyWorks,
      refreshSeed: requestKey.requestSerial,
    );
    if (!_isCategoryRequestCurrent(category, requestKey)) {
      return;
    }
    final decorated = ranked.map(_decorateWork).toList(growable: false);
    _commitPresentation(
      'asmr_refresh_${category.name}',
      () {
        _worksByCategory[category] = decorated;
        _bumpCategoryRevision(category);
        _applyPageResult(
          category,
          query: searchQuery,
          pageResult: AsmrWorkPage(
            works: decorated,
            currentPage: 1,
            pageSize: decorated.length,
            totalCount: decorated.length,
          ),
        );
        _hasMoreByCategory[category] = false;
        notifyListeners();
      },
      isCurrent: () => _isCategoryRequestCurrent(category, requestKey),
    );
  }

  Future<AsmrWorkPage> _loadRemotePage(
    AsmrCategoryType category, {
    required String searchQuery,
    required int page,
    required AsmrContentLanguage language,
    required String? token,
  }) async {
    return _remoteCatalogService.loadPage(
      category,
      searchQuery: searchQuery,
      page: page,
      language: language,
      token: token,
    );
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

  Future<AsmrWorkDetail> loadWorkDetail(AsmrWork work) {
    final cached = _detailCache.remove(work.id);
    if (cached != null) {
      _detailCache[work.id] = cached;
      return SynchronousFuture<AsmrWorkDetail>(cached);
    }
    final key = _workRequestKey(work.id);
    final existing = _detailTasks[key];
    if (existing != null) return existing;
    late final Future<AsmrWorkDetail> task;
    task = _loadWorkDetailOnce(work, key).whenComplete(() {
      if (identical(_detailTasks[key], task)) _detailTasks.remove(key);
    });
    _detailTasks[key] = task;
    return task;
  }

  Future<AsmrWorkDetail> _loadWorkDetailOnce(
    AsmrWork work,
    _AsmrWorkRequestKey key,
  ) async {
    final language = _contentLanguage;
    final detail = await _remoteCatalogService.loadWorkDetail(
      work.id,
      token: _authSession?.token,
      language: language,
    );
    if (!_isWorkRequestCurrent(key)) return loadWorkDetail(work);
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

  @override
  Future<List<MusicTrack>> loadPlayableTracks(AsmrWork work) async {
    final tree = await ensureTrackTree(work);
    return _flattenTracks(work, tree);
  }

  List<MusicTrack> buildPlayableTracksFromNode(
    AsmrWork work,
    AsmrTrackFile node,
  ) {
    return _flattenTracks(work, <AsmrTrackFile>[node]);
  }

  @override
  Future<List<MusicTrack>> loadPlayableTracksStartingAt(
    AsmrWork work,
    AsmrTrackFile target,
  ) async {
    final tracks = await loadPlayableTracks(work);
    final targetIndex = tracks.indexWhere(
      (track) =>
          track.remoteMetadata?['trackRelativePath'] == target.relativePath,
    );
    if (targetIndex < 0) {
      final targetTrackPath = target.toMusicTrack().path;
      final fallbackIndex = tracks.indexWhere(
        (track) => track.path == targetTrackPath,
      );
      if (fallbackIndex <= 0) return tracks;
      return <MusicTrack>[
        ...tracks.skip(fallbackIndex),
        ...tracks.take(fallbackIndex),
      ];
    }
    if (targetIndex == 0) return tracks;
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

  Future<List<AsmrTrackFile>> ensureTrackTree(AsmrWork work) {
    final cached = _cachedTrackTree(work.id);
    if (cached != null) {
      return SynchronousFuture<List<AsmrTrackFile>>(cached);
    }
    final key = _workRequestKey(work.id);
    final existing = _trackTreeTasks[key];
    if (existing != null) return existing;
    _trackTreeErrors.remove(work.id);
    if (!_trackTreeTasks.keys.any((candidate) => candidate.workId == work.id) &&
        _loadingTrackWorkIds.add(work.id)) {
      _bumpTrackRevision(work.id);
      notifyListeners();
    }
    late final Future<List<AsmrTrackFile>> task;
    task = _loadTrackTreeOnce(work, key).whenComplete(() {
      if (identical(_trackTreeTasks[key], task)) {
        _trackTreeTasks.remove(key);
      }
      if (!_trackTreeTasks.keys.any(
        (candidate) => candidate.workId == work.id,
      )) {
        _loadingTrackWorkIds.remove(work.id);
        _trimTrackCache();
        _bumpTrackRevision(work.id);
        notifyListeners();
      }
    });
    _trackTreeTasks[key] = task;
    return task;
  }

  Future<List<AsmrTrackFile>> _loadTrackTreeOnce(
    AsmrWork work,
    _AsmrWorkRequestKey key,
  ) async {
    try {
      final tree = await _remoteCatalogService.loadTrackTree(
        work.id,
        token: _authSession?.token,
      );
      if (_isWorkRequestCurrent(key)) {
        _trackTreeErrors.remove(work.id);
        final sortedTree = _storeTrackTree(work.id, tree);
        _bumpTrackRevision(work.id);
        return sortedTree;
      }
      return ensureTrackTree(work);
    } catch (error) {
      if (_isWorkRequestCurrent(key)) {
        _trackTreeErrors[work.id] = error;
        _bumpTrackRevision(work.id);
      }
      rethrow;
    }
  }

  Future<void> toggleFavorite(AsmrWork work) {
    return _runStateMutation(() => _toggleFavoriteNow(work));
  }

  Future<void> _toggleFavoriteNow(AsmrWork work) async {
    final mutationAuthEpoch = _authEpoch;
    final snapshot = await _accountSyncService.toggleFavorite(work);
    if (mutationAuthEpoch != _authEpoch) return;
    _applyAccountSnapshot(snapshot);
    final shouldFavorite = _favoriteIds.contains(work.id);
    final updatedWork = work.copyWith(isFavorite: shouldFavorite);
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

  @override
  Future<void> recordHistory(AsmrWork work) {
    return _runStateMutation(() => _recordHistoryNow(work));
  }

  Future<void> _recordHistoryNow(AsmrWork work) async {
    final mutationAuthEpoch = _authEpoch;
    final snapshot = await _accountSyncService.recordHistory(work);
    if (mutationAuthEpoch != _authEpoch) return;
    _applyAccountSnapshot(snapshot);
    _bumpGlobalRevision();
    if (isAsmrAccountLoggedIn) {
      unawaited(syncAsmrAccount());
    }
    _updateLocalCategoryCounts();
    _bumpCategoryRevision(AsmrCategoryType.history);
    notifyListeners();
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

  List<AsmrTrackFile> _storeTrackTree(int workId, List<AsmrTrackFile> tree) {
    final sortedTree = sortAsmrTrackTreeNaturally(tree);
    _trackCache.remove(workId);
    _trackCache[workId] = sortedTree;
    _visibleTrackCache.remove(workId);
    _trimTrackCache();
    return sortedTree;
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
