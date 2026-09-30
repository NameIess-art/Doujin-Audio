import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';

import '../../../core/persistence/persisted_state_reloader.dart';
import '../../../core/immutable_collections.dart';
import '../domain/asmr_models.dart';
import '../../../core/media/music_track.dart';
import '../../library/application/work_text_service.dart';
import 'asmr_account_sync_service.dart';
import 'asmr_download_manager.dart';
import 'asmr_playback_coordinator.dart';
import 'asmr_preferences.dart';
import 'asmr_remote_catalog_service.dart';
import 'asmr_library_view_state.dart';
import 'asmr_work_content_mapping.dart';
import 'asmr_work_content_store.dart';
import '../../../core/app_language.dart';
import '../../../core/media/search_query_utils.dart';

export 'asmr_library_view_state.dart';
export 'asmr_work_content_mapping.dart' show collectAsmrWorkTextFiles;

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

typedef _AsmrSyncRequestKey = ({int authEpoch, String token});
typedef _AsmrCategoryRequestKey = ({
  int authEpoch,
  String? token,
  int contentEpoch,
  int requestSerial,
});

final class _AsmrCategoryState {
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

typedef _AsmrCategoryRequest = ({
  Future<void> task,
  String query,
  _AsmrCategoryRequestKey key,
});

class AsmrLibraryController extends ChangeNotifier
    implements AsmrPlaybackSource, PersistedStateReloader {
  AsmrLibraryController({
    required AsmrPreferencesStore preferencesStore,
    required AsmrRemoteCatalogService remoteCatalogService,
    required AsmrAccountSyncService accountSyncService,
  }) : _preferencesStore = preferencesStore,
       _remoteCatalogService = remoteCatalogService,
       _accountSyncService = accountSyncService;

  static const int _filteredWorksCacheLimit = 24;
  final AsmrPreferencesStore _preferencesStore;
  final AsmrRemoteCatalogService _remoteCatalogService;
  final AsmrAccountSyncService _accountSyncService;
  late final AsmrWorkContentStore _workContent = AsmrWorkContentStore(
    onChanged: notifyListeners,
  );
  final Map<AsmrCategoryType, _AsmrCategoryState> _categories = {
    for (final category in AsmrCategoryType.values)
      category: _AsmrCategoryState(),
  };
  final Map<AsmrCategoryType, _AsmrCategoryRequest> _refreshTasks = {};

  _AsmrCategoryState _category(AsmrCategoryType category) =>
      _categories[category]!;
  final Map<AsmrCategoryType, String> _pendingAuthCategoryRefreshes =
      <AsmrCategoryType, String>{};
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
  bool _skipRestoreForNextInitialize = false;
  Future<void>? _authRestoreTask;
  final Map<_AsmrSyncRequestKey, Future<void>> _syncTasks =
      <_AsmrSyncRequestKey, Future<void>>{};
  AsmrSyncCancellationToken? _activeSyncCancellationToken;
  Future<void> _stateMutationTail = Future<void>.value();
  bool _initialized = false;
  int _globalRevision = 0;
  int _authEpoch = 0;
  int _contentEpoch = 0;
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  void _commitPresentation(VoidCallback commit, {bool Function()? isCurrent}) {
    if (isCurrent != null && !isCurrent()) return;
    commit();
  }

  Future<T> _runStateMutation<T>(Future<T> Function() mutation) {
    final result = _stateMutationTail.then((_) => mutation());
    _stateMutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  AsmrWorkRequestKey _workRequestKey(int workId) =>
      (workId: workId, contentEpoch: _contentEpoch, authEpoch: _authEpoch);

  bool _isWorkRequestCurrent(AsmrWorkRequestKey key) =>
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
      key.requestSerial == _category(category).requestSerial;

  bool _isRemoteCategory(AsmrCategoryType category) =>
      category != AsmrCategoryType.favorites &&
      category != AsmrCategoryType.history;

  void _invalidateCategoryRequestsForAuthChange() {
    for (final category in AsmrCategoryType.values) {
      if (_isRemoteCategory(category) &&
          ((_category(category).query != null) ||
              (_category(category).works != null) ||
              _refreshTasks.containsKey(category))) {
        _pendingAuthCategoryRefreshes.putIfAbsent(
          category,
          () =>
              _refreshTasks[category]?.query ?? _category(category).query ?? '',
        );
      }
      _category(category).invalidateRequest();
      if (_isRemoteCategory(category)) {
        _category(category).error = null;
        _category(category).page = 1;
        _category(category).totalCount = null;
        _category(category).hasMore = false;
      }
    }
    _refreshTasks.clear();
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
    _workContent.clearCaches(clearErrors: true);
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
  List<AsmrCategoryType> get visibleCategories => _visibleCategories;
  ContentLanguagePreference get contentLanguagePreference =>
      _contentLanguagePreference;
  AppLanguage get pageLanguage => _pageLanguage;
  AsmrContentLanguage get contentLanguage => _contentLanguage;
  bool isFavorite(int workId) => _favoriteIds.contains(workId);
  bool get isAsmrAccountLoggedIn {
    final session = _authSession;
    return session != null &&
        session.isValid &&
        session.userName.trim().isNotEmpty;
  }

  String get asmrAccountName => _authSession?.userName.trim() ?? '';

  bool isLoadingCategory(AsmrCategoryType category) =>
      _category(category).isLoading;
  bool isLoadingMoreCategory(AsmrCategoryType category) =>
      _category(category).isLoadingMore;
  bool hasMoreCategory(AsmrCategoryType category) =>
      _category(category).hasMore;
  bool needsLoadMoreRetryCategory(AsmrCategoryType category) =>
      _category(category).needsLoadMoreRetry;
  int totalCountFor(AsmrCategoryType category) =>
      _category(category).totalCount ?? worksFor(category).length;
  String activeQueryFor(AsmrCategoryType category) =>
      _category(category).query ?? '';
  bool isTrackTreeLoading(int workId) => _workContent.isLoading(workId);
  List<AsmrTrackFile>? trackTreeFor(int workId) =>
      _workContent.cachedTrackTree(workId);

  AsmrLibraryGlobalViewState get globalViewState => AsmrLibraryGlobalViewState(
    initialized: _initialized,
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
          (_category(category).query != null) ||
          (_category(category).requestSerial) > 0,
      hasMore: hasMoreCategory(category),
      needsLoadMoreRetry: needsLoadMoreRetryCategory(category),
      totalCount:
          category == AsmrCategoryType.favorites ||
              category == AsmrCategoryType.history
          ? works.length
          : totalCountFor(category),
      activeQuery: activeQueryFor(category),
      lastError: _category(category).error,
      operationError: _category(category).error,
      revision: _categoryRevisionFor(category),
    );
  }

  AsmrTrackTreeViewState trackTreeViewState(int workId) =>
      _workContent.trackTreeViewState(workId);

  List<AsmrWork> worksFor(AsmrCategoryType category) {
    switch (category) {
      case AsmrCategoryType.favorites:
        return _favoriteWorks;
      case AsmrCategoryType.history:
        return _historyWorks;
      default:
        return _category(category).works ?? const <AsmrWork>[];
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
    final terms = normalizedSearchTerms(normalizedQuery);
    final filtered = immutableList(
      works.where((work) => _matchesQuery(work, normalizedQuery, terms: terms)),
    );
    _filteredWorksCache[cacheKey] = filtered;
    while (_filteredWorksCache.length > _filteredWorksCacheLimit) {
      _filteredWorksCache.remove(_filteredWorksCache.keys.first);
    }
    return filtered;
  }

  Future<void> initialize({AsmrContentLanguage? defaultLanguage}) {
    final restoreAccountSession = !_skipRestoreForNextInitialize;
    _skipRestoreForNextInitialize = false;
    return _initialize(
      defaultLanguage: defaultLanguage,
      restoreAccountSession: restoreAccountSession,
    );
  }

  Future<void> initializeForVisiblePage({
    AsmrContentLanguage? defaultLanguage,
  }) {
    _skipRestoreForNextInitialize = true;
    final task = initialize(defaultLanguage: defaultLanguage);
    return task.whenComplete(() {
      _skipRestoreForNextInitialize = false;
    });
  }

  Future<void> _initialize({
    AsmrContentLanguage? defaultLanguage,
    required bool restoreAccountSession,
  }) {
    if (_disposed || _initialized) return Future<void>.value();
    final existing = _initializeTask;
    if (existing != null) {
      return existing;
    }
    late final Future<void> task;
    task =
        _initializeLocalState(
          defaultLanguage: defaultLanguage,
          restoreAccountSession: restoreAccountSession,
        ).whenComplete(() {
          if (identical(_initializeTask, task)) {
            _initializeTask = null;
          }
        });
    _initializeTask = task;
    return task;
  }

  Future<void> _initializeLocalState({
    AsmrContentLanguage? defaultLanguage,
    required bool restoreAccountSession,
  }) async {
    final hiddenTracks = await _preferencesStore.loadHiddenTracks();
    if (_disposed) return;
    _workContent.replaceHiddenTracks(hiddenTracks);
    final visibleCategories = await _preferencesStore.loadVisibleCategories();
    if (_disposed) return;
    _visibleCategories = visibleCategories;
    if (defaultLanguage != null) {
      _pageLanguage = defaultLanguage.appLanguage;
    }
    final contentLanguagePreference = await _preferencesStore
        .loadContentLanguagePreference();
    if (_disposed) return;
    _contentLanguagePreference = contentLanguagePreference;
    _contentLanguage = _resolveContentLanguage();
    final accountSnapshot = await _accountSyncService.initialize();
    if (_disposed) return;
    _applyAccountSnapshot(accountSnapshot);
    _updateLocalCategoryCounts();
    _initialized = true;
    _bumpGlobalRevision();
    _commitPresentation(notifyListeners);
    if (restoreAccountSession) {
      unawaited(restoreAsmrAccountSession());
    }
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
        _commitPresentation(notifyListeners);
      }
    });
    _authRestoreTask = task;
    _bumpGlobalRevision();
    _commitPresentation(notifyListeners);
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
        notifyListeners,
        isCurrent: () => appliedEpoch == _authEpoch,
      );
      _refreshLoadedCategoriesForCurrentAuth();
    } catch (error) {
      if (requestEpoch != _authEpoch) return;
      _lastSyncError = error;
      _bumpGlobalRevision();
      _commitPresentation(
        notifyListeners,
        isCurrent: () => requestEpoch == _authEpoch,
      );
    }
  }

  @override
  Future<void> reloadPersistedState() async {
    _initialized = false;
    for (final state in _categories.values) {
      state.works = null;
    }
    _workContent.clearCaches(clearErrors: true);
    _filteredWorksCache.clear();
    await initialize();
    await restoreAsmrAccountSession();
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
    if (_category(category).error != null) {
      _category(category).error = null;
      _bumpCategoryRevision(category);
      notifyListeners();
    }
    if (isAsmrAccountLoggedIn) {
      await syncAsmrAccount(force: true);
      if (_syncPhase == AsmrSyncPhase.failed) {
        _category(category).error = _lastSyncError;
        _bumpCategoryRevision(category);
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
    final refreshQueries = <AsmrCategoryType, String>{
      for (final entry in _categories.entries)
        if (_isRemoteCategory(entry.key) && entry.value.query != null)
          entry.key: entry.value.query!,
    };
    _contentLanguagePreference = preference;
    await _preferencesStore.saveContentLanguagePreference(preference);
    final nextLanguage = _resolveContentLanguage();
    if (_contentLanguage == nextLanguage) {
      _bumpGlobalRevision();
      notifyListeners();
      return;
    }
    _applyContentLanguage(nextLanguage);
    await Future.wait(
      refreshQueries.entries.map(
        (entry) => refreshCategory(entry.key, searchQuery: entry.value),
      ),
    );
  }

  AsmrContentLanguage _resolveContentLanguage() {
    return AsmrContentLanguage.fromAppLanguage(
      _contentLanguagePreference.resolve(_pageLanguage),
    );
  }

  void _applyContentLanguage(AsmrContentLanguage language) {
    _contentLanguage = language;
    _contentEpoch++;
    for (final entry in _categories.entries) {
      final state = entry.value;
      state.invalidateRequest();
      state.works = null;
      state.error = null;
      if (_isRemoteCategory(entry.key)) state.query = null;
      _bumpCategoryRevision(entry.key);
    }
    _refreshTasks.clear();
    _workContent.clearCaches();
    _workContent.bumpAllTrackRevisions();
    _bumpGlobalRevision();
    notifyListeners();
  }

  Future<void> refreshCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) async {
    await initialize();
    if (_disposed) return;
    final existing = _refreshTasks[category];
    final normalizedQuery = normalizeSearchQuery(searchQuery);
    final existingKey = existing?.key;
    if (existing != null &&
        existing.query == normalizedQuery &&
        existingKey != null &&
        existingKey.authEpoch == _authEpoch &&
        existingKey.token == _authSession?.token &&
        existingKey.contentEpoch == _contentEpoch) {
      return existing.task;
    }
    final requestId = _category(category).requestSerial + 1;
    _category(category).requestSerial = requestId;
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
          if (identical(_refreshTasks[category]?.task, task)) {
            _refreshTasks.remove(category);
          }
        });
    _refreshTasks[category] = (
      task: task,
      query: normalizedQuery,
      key: requestKey,
    );
    await task;
  }

  Future<void> loadMoreCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) async {
    await initialize();
    if (_disposed) return;
    final normalizedQuery = normalizeSearchQuery(searchQuery);
    if (category == AsmrCategoryType.favorites ||
        category == AsmrCategoryType.history ||
        category == AsmrCategoryType.recommendation) {
      return;
    }
    if (isLoadingCategory(category) || isLoadingMoreCategory(category)) {
      return;
    }
    final existingQuery = _category(category).query ?? '';
    if (existingQuery != normalizedQuery) {
      await refreshCategory(category, searchQuery: normalizedQuery);
      return;
    }
    if (!hasMoreCategory(category)) {
      return;
    }

    final requestId = _category(category).requestSerial;
    final requestKey = _categoryRequestKey(requestId);
    _category(category).isLoadingMore = true;
    _category(category).needsLoadMoreRetry = false;
    _category(category).error = null;
    _commitPresentation(
      notifyListeners,
      isCurrent: () => _isCategoryRequestCurrent(category, requestKey),
    );
    final requestLanguage = _contentLanguage;
    try {
      final page = (_category(category).page) + 1;
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
      final existingIds = (_category(category).works ?? const <AsmrWork>[])
          .map((work) => work.id)
          .toSet();
      final additions = pageResult.works
          .where((work) => existingIds.add(work.id))
          .toList(growable: false);
      final merged = <AsmrWork>[...?_category(category).works, ...additions];
      final decorated = immutableList(merged.map(_decorateWork));
      _commitPresentation(() {
        _category(category).works = decorated;
        _bumpCategoryRevision(category);
        _applyPageResult(
          category,
          query: normalizedQuery,
          pageResult: pageResult,
        );
        _category(category).needsLoadMoreRetry =
            additions.isEmpty && hasMoreCategory(category);
        notifyListeners();
      }, isCurrent: () => _isCategoryRequestCurrent(category, requestKey));
    } catch (error) {
      if (_isCategoryRequestCurrent(category, requestKey)) {
        _category(category).error = error;
        _category(category).needsLoadMoreRetry = true;
      }
    } finally {
      if (_isCategoryRequestCurrent(category, requestKey)) {
        _commitPresentation(() {
          _category(category).isLoadingMore = false;
          notifyListeners();
        }, isCurrent: () => _isCategoryRequestCurrent(category, requestKey));
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
    _category(category).isLoading = true;
    _category(category).needsLoadMoreRetry = false;
    _category(category).error = null;
    _commitPresentation(
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
          _category(category).query = normalizedQuery;
          _category(category).totalCount = filteredWorksFor(
            category,
            searchQuery: normalizedQuery,
          ).length;
          _category(category).hasMore = false;
          break;
        case AsmrCategoryType.history:
          _category(category).query = normalizedQuery;
          _category(category).totalCount = filteredWorksFor(
            category,
            searchQuery: normalizedQuery,
          ).length;
          _category(category).hasMore = false;
          break;
      }
    } catch (error) {
      if (_isCategoryRequestCurrent(category, requestKey)) {
        _category(category).error = error;
      }
    } finally {
      if (_isCategoryRequestCurrent(category, requestKey)) {
        _commitPresentation(() {
          _category(category).isLoading = false;
          notifyListeners();
        }, isCurrent: () => _isCategoryRequestCurrent(category, requestKey));
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
    final decorated = immutableList(pageResult.works.map(_decorateWork));
    _commitPresentation(() {
      _category(category).works = decorated;
      _bumpCategoryRevision(category);
      _applyPageResult(category, query: searchQuery, pageResult: pageResult);
      notifyListeners();
    }, isCurrent: () => _isCategoryRequestCurrent(category, requestKey));
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
    final decorated = immutableList(ranked.map(_decorateWork));
    _commitPresentation(() {
      _category(category).works = decorated;
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
      _category(category).hasMore = false;
      notifyListeners();
    }, isCurrent: () => _isCategoryRequestCurrent(category, requestKey));
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
    _category(category).query = query;
    _category(category).page = pageResult.currentPage;
    _category(category).totalCount = pageResult.totalCount;
    final loadedCount = _category(category).works?.length ?? 0;
    _category(category).hasMore =
        pageResult.hasMore && loadedCount < pageResult.totalCount;
  }

  AsmrWork _decorateWork(AsmrWork work) {
    return work.copyWith(isFavorite: _favoriteIds.contains(work.id));
  }

  Future<AsmrWorkDetail> loadWorkDetail(AsmrWork work) {
    final cached = _workContent.cachedDetail(work.id);
    if (cached != null) return SynchronousFuture<AsmrWorkDetail>(cached);
    final key = _workRequestKey(work.id);
    return _workContent.requestDetail(
      key,
      () => _loadWorkDetailOnce(work, key),
    );
  }

  Future<AsmrWorkDetail> _loadWorkDetailOnce(
    AsmrWork work,
    AsmrWorkRequestKey key,
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
    _workContent.storeDetail(merged);
    return merged;
  }

  bool isTrackHidden(int workId, AsmrTrackFile node) =>
      _workContent.hiddenTracks.contains('$workId:${node.stableKey}');

  Future<void> setTrackHidden(int workId, AsmrTrackFile node, bool hidden) {
    return _runStateMutation(() async {
      await initializeForVisiblePage();
      final key = '$workId:${node.stableKey}';
      if (_workContent.hiddenTracks.contains(key) == hidden) return;
      final next = {..._workContent.hiddenTracks};
      if (hidden) {
        next.add(key);
      } else {
        next.remove(key);
      }
      await _preferencesStore.saveHiddenTracks(next);
      if (_disposed) return;
      _workContent.replaceHiddenTracks(next, changedWorkId: workId);
      notifyListeners();
    });
  }

  @override
  Future<List<MusicTrack>> loadPlayableTracks(AsmrWork work) async {
    await initializeForVisiblePage();
    final tree = await ensureTrackTree(work);
    final cached = _workContent.cachedPlayableTracks(work);
    if (cached != null) return cached;
    return _workContent.storePlayableTracks(
      work,
      flattenAsmrPlayableTracks(
        work,
        tree,
        hiddenTracks: _workContent.hiddenTracks,
      ),
    );
  }

  Future<List<WorkTextFile>> findWorkTextFiles(
    AsmrWork work, {
    AsmrDownloadManager? downloadManager,
  }) async {
    final tree = await ensureTrackTree(work);
    return collectAsmrWorkTextFiles(
      tree,
      downloadManager: downloadManager,
      workId: work.id,
    );
  }

  List<MusicTrack> buildPlayableTracksFromNode(
    AsmrWork work,
    AsmrTrackFile node,
  ) {
    if (node.isFolder) {
      return flattenAsmrPlayableTracks(work, <AsmrTrackFile>[
        node,
      ], hiddenTracks: _workContent.hiddenTracks);
    }
    return flattenAsmrPlayableTracks(
      work,
      _workContent.cachedTrackTree(work.id) ?? <AsmrTrackFile>[node],
      hiddenTracks: _workContent.hiddenTracks,
      includeAudioNode: (candidate) => candidate.stableKey == node.stableKey,
    );
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
      if (fallbackIndex < 0) return const <MusicTrack>[];
      if (fallbackIndex == 0) return tracks;
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

  Future<List<AsmrTrackFile>> ensureTrackTree(AsmrWork work) {
    final cached = _workContent.cachedTrackTree(work.id);
    if (cached != null) return SynchronousFuture<List<AsmrTrackFile>>(cached);
    final key = _workRequestKey(work.id);
    return _workContent.requestTrackTree(
      key,
      () => _loadTrackTreeOnce(work, key),
    );
  }

  Future<List<AsmrTrackFile>> _loadTrackTreeOnce(
    AsmrWork work,
    AsmrWorkRequestKey key,
  ) async {
    try {
      final tree = await _remoteCatalogService.loadTrackTree(
        work.id,
        token: _authSession?.token,
      );
      if (_isWorkRequestCurrent(key)) {
        _workContent.clearTrackTreeError(work.id);
        final sortedTree = _workContent.storeTrackTree(work.id, tree);
        _workContent.bumpTrackRevision(work.id);
        return sortedTree;
      }
      return ensureTrackTree(work);
    } catch (error) {
      if (_isWorkRequestCurrent(key)) {
        _workContent.setTrackTreeError(work.id, error);
        _workContent.bumpTrackRevision(work.id);
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
    final cachedDetail = _workContent.takeDetail(work.id);
    _workContent.storeDetail(
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
    for (final entry in _categories.entries) {
      final works = entry.value.works;
      if (works == null) continue;
      _category(entry.key).works = immutableList(
        works.map(
          (item) => item.id == work.id
              ? item.copyWith(isFavorite: shouldFavorite)
              : item,
        ),
      );
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
    return matchesSearchTerms(haystacks, query, normalizedTerms: terms);
  }

  void _updateLocalCategoryCounts() {
    for (final category in <AsmrCategoryType>[
      AsmrCategoryType.favorites,
      AsmrCategoryType.history,
    ]) {
      final query = _category(category).query ?? '';
      _category(category).totalCount = filteredWorksFor(
        category,
        searchQuery: query,
      ).length;
    }
  }

  int _categoryRevisionFor(AsmrCategoryType category) {
    return _category(category).revision;
  }

  void _bumpCategoryRevision(AsmrCategoryType category) {
    _category(category).revision = _categoryRevisionFor(category) + 1;
    _filteredWorksCache.removeWhere((key, _) => key.category == category);
  }

  void _bumpGlobalRevision() {
    _globalRevision++;
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
      if (result.length == 5) {
        break;
      }
    }
    return result.isEmpty
        ? kDefaultVisibleAsmrCategories
        : result.toList(growable: false);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _activeSyncCancellationToken?.cancel();
    _activeSyncCancellationToken = null;
    _authEpoch++;
    _contentEpoch++;
    super.dispose();
  }
}
