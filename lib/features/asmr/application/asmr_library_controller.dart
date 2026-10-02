import 'dart:async';
import 'dart:convert';
import '../../../core/logging/app_log_service.dart';
import 'package:flutter/foundation.dart';

import '../../../core/persistence/persisted_state_reloader.dart';
import '../domain/asmr_models.dart';
import '../../../core/media/music_track.dart';
import '../../library/application/work_text_service.dart';
import 'asmr_account_sync_service.dart';
import 'asmr_category_catalog.dart';
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

typedef _AsmrSyncRequestKey = ({int authEpoch, String token});

class AsmrLibraryController extends ChangeNotifier
    implements AsmrPlaybackSource, PersistedStateReloader {
  AsmrLibraryController({
    required AsmrPreferencesStore preferencesStore,
    required AsmrRemoteCatalogService remoteCatalogService,
    required AsmrAccountSyncService accountSyncService,
  }) : _preferencesStore = preferencesStore,
       _remoteCatalogService = remoteCatalogService,
       _accountSyncService = accountSyncService;

  final AsmrPreferencesStore _preferencesStore;
  final AsmrRemoteCatalogService _remoteCatalogService;
  final AsmrAccountSyncService _accountSyncService;
  late final AsmrWorkContentStore _workContent = AsmrWorkContentStore(
    onChanged: notifyListeners,
  );
  late final AsmrCategoryCatalog _catalog = AsmrCategoryCatalog(
    remoteCatalogService: _remoteCatalogService,
    onChanged: notifyListeners,
    isContextCurrent: (context) =>
        !_disposed &&
        context.authEpoch == _authEpoch &&
        context.token == _authSession?.token &&
        context.contentEpoch == _contentEpoch,
    localWorks: (category) =>
        category == AsmrCategoryType.favorites ? _favoriteWorks : _historyWorks,
    decorateWork: _decorateWork,
    currentContext: () => _categoryRequestContext,
    persist: (scope, key, payload) =>
        _persistBrowse('asmr_category', scope, key, payload),
  );

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
  int _browseCacheEpoch = 0;
  Future<void> _browseWriteTail = Future<void>.value();
  Future<void>? _browseClearTask;
  final Map<String, Future<void>> _browseHydrations = {};
  final Set<String> _hydratedBrowseScopes = {};

  String get browseCacheScope =>
      jsonEncode([_authSession?.userName.trim() ?? '', _contentLanguage.name]);

  void _persistBrowse(
    String kind,
    String scope,
    String key,
    Map<String, Object?> payload,
  ) {
    final epoch = _browseCacheEpoch;
    _browseWriteTail = _browseWriteTail
        .then((_) async {
          if (epoch != _browseCacheEpoch) return;
          await _preferencesStore.saveBrowseSnapshot(kind, scope, key, payload);
        })
        .catchError((Object error, StackTrace stack) {
          AppLogService.warning(
            'asmr_browse_cache_write_failed',
            error: error,
            stackTrace: stack,
          );
        });
  }

  Future<void> flushBrowseCaches() async {
    while (true) {
      final pending = _browseWriteTail;
      await pending;
      if (identical(pending, _browseWriteTail)) return;
    }
  }

  Future<void> clearBrowseCaches() {
    final existing = _browseClearTask;
    if (existing != null) return existing;
    late final Future<void> task;
    task = _clearBrowseCaches().whenComplete(() {
      if (identical(_browseClearTask, task)) _browseClearTask = null;
    });
    _browseClearTask = task;
    return task;
  }

  Future<void> _clearBrowseCaches() async {
    _browseCacheEpoch++;
    _contentEpoch++;
    _catalog.clearWorks();
    _workContent.clearCaches(clearErrors: true);
    _hydratedBrowseScopes.clear();
    _browseHydrations.clear();
    await flushBrowseCaches();
    await _preferencesStore.clearBrowseSnapshots();
    notifyListeners();
  }

  Future<void> _hydrateBrowseScope() {
    final scope = browseCacheScope;
    if (_hydratedBrowseScopes.contains(scope)) return Future<void>.value();
    final existing = _browseHydrations[scope];
    if (existing != null) return existing;
    final context = _categoryRequestContext;
    final epoch = _browseCacheEpoch;
    late final Future<void> task;
    task =
        () async {
          for (final category in AsmrCategoryType.values.where(
            AsmrCategoryCatalog.isRemote,
          )) {
            final key = jsonEncode([category.name, '']);
            final payload = await _readBrowsePayload(
              'asmr_category',
              scope,
              key,
            );
            if (_disposed ||
                epoch != _browseCacheEpoch ||
                !_isContextCurrent(context)) {
              return;
            }
            if (payload != null) _restoreCategoryPayload(scope, key, payload);
          }
          _hydratedBrowseScopes.add(scope);
          notifyListeners();
        }().whenComplete(() {
          if (identical(_browseHydrations[scope], task)) {
            _browseHydrations.remove(scope);
          }
        });
    _browseHydrations[scope] = task;
    return task;
  }

  Future<Map<String, Object?>?> _readBrowsePayload(
    String kind,
    String scope,
    String key,
  ) async {
    await _browseClearTask;
    try {
      return await _preferencesStore.loadBrowseSnapshot(kind, scope, key);
    } catch (error, stack) {
      AppLogService.warning(
        'asmr_browse_cache_read_failed kind=$kind key=$key',
        error: error,
        stackTrace: stack,
      );
      return null;
    }
  }

  void _restoreCategoryPayload(
    String scope,
    String key,
    Map<String, Object?> payload,
  ) {
    try {
      _catalog.restore(scope, {key: payload});
    } catch (error, stack) {
      AppLogService.warning(
        'asmr_category_cache_decode_failed key=$key',
        error: error,
        stackTrace: stack,
      );
    }
  }

  bool _isContextCurrent(AsmrCategoryRequestContext context) =>
      !_disposed &&
      context.authEpoch == _authEpoch &&
      context.contentEpoch == _contentEpoch &&
      context.scope == browseCacheScope;

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

  AsmrWorkRequestKey _workRequestKey(int workId) => (
    workId: workId,
    contentEpoch: _contentEpoch,
    authEpoch: _authEpoch,
    cacheEpoch: _browseCacheEpoch,
  );

  bool _isWorkRequestCurrent(AsmrWorkRequestKey key) =>
      !_disposed &&
      key.contentEpoch == _contentEpoch &&
      key.authEpoch == _authEpoch &&
      key.cacheEpoch == _browseCacheEpoch;

  AsmrCategoryRequestContext get _categoryRequestContext => (
    authEpoch: _authEpoch,
    token: _authSession?.token,
    contentEpoch: _contentEpoch,
    language: _contentLanguage,
    scope: browseCacheScope,
  );

  void _refreshLoadedCategoriesForCurrentAuth() {
    final pending = _catalog.takePendingAuthRefreshes();
    unawaited(() async {
      await _hydrateBrowseScope();
      for (final entry in pending.entries) {
        await ensureCategoryLoaded(entry.key, searchQuery: entry.value);
      }
    }());
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
      _catalog.isLoading(category);
  bool hasLoadedCategory(AsmrCategoryType category) =>
      AsmrCategoryCatalog.isRemote(category)
      ? _catalog.hasLoaded(category)
      : _initialized;
  bool isLoadingMoreCategory(AsmrCategoryType category) =>
      _catalog.isLoadingMore(category);
  bool hasMoreCategory(AsmrCategoryType category) => _catalog.hasMore(category);
  bool needsLoadMoreRetryCategory(AsmrCategoryType category) =>
      _catalog.needsLoadMoreRetry(category);
  int totalCountFor(AsmrCategoryType category) => _catalog.totalCount(category);
  String activeQueryFor(AsmrCategoryType category) =>
      _catalog.activeQuery(category);
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
  }) => _catalog.viewState(category, searchQuery: searchQuery);

  AsmrTrackTreeViewState trackTreeViewState(int workId) =>
      _workContent.trackTreeViewState(workId);

  List<AsmrWork> worksFor(AsmrCategoryType category) =>
      _catalog.worksFor(category);

  List<AsmrWork> filteredWorksFor(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) => _catalog.filteredWorksFor(category, searchQuery: searchQuery);

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
    await _hydrateBrowseScope();
    if (_disposed) return;
    _catalog.updateLocalCounts();
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
      _catalog.invalidateForAuthChange();
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
    _browseCacheEpoch++;
    _contentEpoch++;
    _hydratedBrowseScopes.clear();
    _browseHydrations.clear();
    _catalog.clearWorks();
    _workContent.clearCaches(clearErrors: true);
    await initialize();
    await restoreAsmrAccountSession();
  }

  Future<void> loginAsmrAccount(String name, String password) async {
    var operationEpoch = ++_authEpoch;
    _cancelActiveSync();
    _catalog.invalidateForAuthChange();
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
      _catalog.invalidateForAuthChange();
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
    _catalog.invalidateForAuthChange();
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
        _catalog.invalidateForAuthChange();
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
        _catalog.updateLocalCounts();
        _catalog.bumpRevision(AsmrCategoryType.favorites);
        _catalog.bumpRevision(AsmrCategoryType.history);
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
    if (_catalog.errorFor(category) != null) {
      _catalog.setOperationError(category, null);
    }
    if (isAsmrAccountLoggedIn) {
      await syncAsmrAccount(force: true);
      if (_syncPhase == AsmrSyncPhase.failed) {
        _catalog.setOperationError(category, _lastSyncError);
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
    final refreshQueries = _catalog.loadedRemoteQueries;
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
        (entry) => ensureCategoryLoaded(entry.key, searchQuery: entry.value),
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
    _catalog.invalidateForContentChange();
    _workContent.clearCaches();
    _workContent.bumpAllTrackRevisions();
    _bumpGlobalRevision();
    notifyListeners();
  }

  Future<void> ensureCategoryLoaded(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool refreshInBackground = true,
  }) async {
    await initializeForVisiblePage();
    await _browseClearTask;
    if (_disposed) return;
    await _hydrateBrowseScope();
    final context = _categoryRequestContext;
    if (AsmrCategoryCatalog.isRemote(category) &&
        searchQuery.trim().isNotEmpty &&
        !_catalog.hasLoaded(category, searchQuery: searchQuery)) {
      final key = jsonEncode([
        category.name,
        normalizeSearchQuery(searchQuery),
      ]);
      final payload = await _readBrowsePayload(
        'asmr_category',
        context.scope,
        key,
      );
      if (!_isContextCurrent(context)) return;
      if (payload != null) _restoreCategoryPayload(context.scope, key, payload);
    }
    if (!_catalog.hasLoaded(category, searchQuery: searchQuery)) {
      await _catalog.refresh(
        category,
        searchQuery: searchQuery,
        context: context,
      );
    } else if (refreshInBackground) {
      unawaited(
        _catalog.refresh(
          category,
          searchQuery: searchQuery,
          context: context,
          background: true,
        ),
      );
    }
  }

  void acceptCategoryUpdates(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) => _catalog.acceptUpdates(category, searchQuery: searchQuery);

  Future<void> refreshCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) async {
    await initialize();
    await _browseClearTask;
    if (_disposed) return;
    await _catalog.refresh(
      category,
      searchQuery: searchQuery,
      context: _categoryRequestContext,
    );
  }

  Future<void> loadMoreCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) async {
    await initialize();
    await _browseClearTask;
    if (_disposed) return;
    await _catalog.loadMore(
      category,
      searchQuery: searchQuery,
      context: _categoryRequestContext,
    );
  }

  AsmrWork _decorateWork(AsmrWork work) {
    return work.copyWith(isFavorite: _favoriteIds.contains(work.id));
  }

  AsmrWorkDetail? cachedWorkDetail(int workId) =>
      _workContent.cachedDetail(workId);
  Future<void> refreshWorkInBackground(AsmrWork work) async {
    await _browseClearTask;
    if (_disposed) return;
    final key = _workRequestKey(work.id);
    await Future.wait<void>([
      _workContent
          .requestDetail(key, () => _loadWorkDetailOnce(work, key))
          .then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {
              AppLogService.warning(
                'asmr_detail_background_refresh_failed',
                error: error,
                stackTrace: stack,
              );
            },
          ),
      _workContent
          .requestTrackTree(key, () => _loadTrackTreeOnce(work, key))
          .then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {
              AppLogService.warning(
                'asmr_tree_background_refresh_failed',
                error: error,
                stackTrace: stack,
              );
            },
          ),
    ]);
  }

  Future<AsmrWorkDetail> loadWorkDetail(AsmrWork work) {
    final cached = _workContent.cachedDetail(work.id);
    if (cached != null) {
      return SynchronousFuture<AsmrWorkDetail>(cached);
    }
    final key = _workRequestKey(work.id);
    return _workContent.requestDetail(key, () async {
      final scope = browseCacheScope;
      final payload = await _readBrowsePayload(
        'asmr_detail',
        scope,
        work.id.toString(),
      );
      if (!_isWorkRequestCurrent(key)) {
        if (_disposed || key.cacheEpoch != _browseCacheEpoch) {
          throw StateError('browse_cache_invalidated');
        }
        return loadWorkDetail(work);
      }
      if (payload != null && payload['version'] == 1) {
        try {
          _workContent.restoreDetails({work.id.toString(): payload});
          return _workContent.cachedDetail(work.id)!;
        } catch (error, stack) {
          AppLogService.warning(
            'asmr_detail_cache_decode_failed',
            error: error,
            stackTrace: stack,
          );
        }
      }
      return _loadWorkDetailOnce(work, key);
    });
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
    if (!_isWorkRequestCurrent(key)) {
      if (_disposed || key.cacheEpoch != _browseCacheEpoch) {
        throw StateError('browse_cache_invalidated');
      }
      return loadWorkDetail(work);
    }
    final merged = AsmrWorkDetail(
      work: _decorateWork(detail.work),
      description: detail.description,
      ageCategory: detail.ageCategory,
      languageEditionLabels: detail.languageEditionLabels,
      userRating: detail.userRating,
    );
    _workContent.storeDetail(merged);
    notifyListeners();
    _persistBrowse(
      'asmr_detail',
      browseCacheScope,
      work.id.toString(),
      AsmrWorkContentStore.detailPayload(merged),
    );
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
    if (cached != null) {
      return SynchronousFuture<List<AsmrTrackFile>>(cached);
    }
    final key = _workRequestKey(work.id);
    return _workContent.requestTrackTree(key, () async {
      final scope = browseCacheScope;
      final payload = await _readBrowsePayload(
        'asmr_tree',
        scope,
        work.id.toString(),
      );
      if (!_isWorkRequestCurrent(key)) {
        if (_disposed || key.cacheEpoch != _browseCacheEpoch) {
          throw StateError('browse_cache_invalidated');
        }
        return ensureTrackTree(work);
      }
      if (payload != null && payload['version'] == 1) {
        try {
          _workContent.restoreTrees({work.id.toString(): payload});
          return _workContent.cachedTrackTree(work.id)!;
        } catch (error, stack) {
          AppLogService.warning(
            'asmr_tree_cache_decode_failed',
            error: error,
            stackTrace: stack,
          );
        }
      }
      return _loadTrackTreeOnce(work, key);
    });
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
        _persistBrowse(
          'asmr_tree',
          browseCacheScope,
          work.id.toString(),
          AsmrWorkContentStore.treePayload(sortedTree),
        );
        return sortedTree;
      }
      if (_disposed || key.cacheEpoch != _browseCacheEpoch) {
        throw StateError('browse_cache_invalidated');
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
    _catalog.updateFavorite(work.id, shouldFavorite);
    _bumpGlobalRevision();
    if (isAsmrAccountLoggedIn) {
      unawaited(syncAsmrAccount());
    }
    _catalog.updateLocalCounts();
    _catalog.bumpRevision(AsmrCategoryType.favorites);
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
    _catalog.updateLocalCounts();
    _catalog.bumpRevision(AsmrCategoryType.history);
    notifyListeners();
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
