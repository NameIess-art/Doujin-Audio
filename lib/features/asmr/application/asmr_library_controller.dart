import '../domain/asmr_tag_interest.dart';
import 'dart:async';
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
import 'asmr_request_cancellation.dart';
import 'asmr_library_view_state.dart';
import 'asmr_work_content_mapping.dart';
import 'asmr_work_content_store.dart';
import '../../../core/app_language.dart';

export 'asmr_library_view_state.dart';
export '../domain/asmr_tag_interest.dart';
export 'asmr_work_content_mapping.dart' show collectAsmrWorkTextFiles;

typedef _AsmrSyncRequestKey = ({int authEpoch, String token});

List<MusicTrack> _buildPlayableTracks(
  ({AsmrWork work, List<AsmrTrackFile> tree}) input,
) => flattenAsmrPlayableTracks(input.work, input.tree);

AsmrTagPreferences _deriveTagInterests(
  ({
    AsmrTagPreferences state,
    List<MusicTrack> tracks,
    List<AsmrWork> favorites,
    List<AsmrWork> history,
  })
  input,
) {
  final state = AsmrTagPreferences.fromJson(input.state.toJson());
  final tagGroups = input.tracks
      .map((track) => track.tags)
      .followedBy(input.favorites.map((work) => work.tags))
      .followedBy(input.history.map((work) => work.tags));
  for (final tags in tagGroups) {
    for (final tag in tags) {
      if (tag.trim().isNotEmpty) state.resolve(tag);
    }
  }
  return state;
}

class AsmrLibraryController extends ChangeNotifier
    implements AsmrPlaybackSource, PersistedStateReloader {
  AsmrLibraryController({
    required AsmrPreferencesStore preferencesStore,
    required AsmrRemoteCatalogService remoteCatalogService,
    required AsmrAccountSyncService accountSyncService,
  }) : _preferencesStore = preferencesStore,
       _remoteCatalogService = remoteCatalogService,
       _accountSyncService = accountSyncService {
    _remoteCatalogService.isWorkAllowed = _isWorkAllowed;
    _remoteCatalogService.tagWeights = () =>
        _tagPreferences.recommendationWeights;
    _remoteCatalogService.prepareTagInterests = (tracks) =>
        ensureTagInterests(localTracks: tracks);
  }

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
    favoriteIds: () => _favoriteIds,
    isWorkAllowed: _isWorkAllowed,
    hasExclusions: () => _tagPreferences.excluded.isNotEmpty,
    currentContext: () => _categoryRequestContext,
  );

  AsmrTagPreferences _tagPreferences = AsmrTagPreferences();
  Future<void>? _tagInterestsTask;
  bool _tagInterestsReady = false;
  Future<void>? _tagCatalogTask;
  Object? _tagCatalogError;
  List<AsmrTagInterest> get interestTags => _tagPreferences.interests;
  List<AsmrTagInterest> get listenedTagInterests =>
      _tagPreferences.listenedInterests;
  Set<String> get manualInterestTagKeys =>
      Set.unmodifiable(_tagPreferences.manualInterests);
  List<AsmrTag> get allTags {
    final tags = _tagPreferences.tags.values.toList();
    tags.sort((a, b) => a.name.compareTo(b.name));
    return tags;
  }

  Set<String> get excludedTagKeys => Set.unmodifiable(_tagPreferences.excluded);
  bool get tagCatalogComplete => _tagPreferences.catalogComplete;
  bool get isLoadingTagCatalog => _tagCatalogTask != null;
  Object? get tagCatalogError => _tagCatalogError;
  List<AsmrWork> _dailyRecommendations = const [];
  String? _dailyRecommendationsDate;
  AsmrContentLanguage? _dailyRecommendationsLanguage;
  Future<void>? _dailyRecommendationsTask;
  String? _dailyRequestedDate;
  AsmrRequestCancellationToken? _dailyRecommendationsCancellation;
  Object? _dailyRecommendationsError;
  List<AsmrWork> get dailyRecommendations => _dailyRecommendations
      .where(_isWorkAllowed)
      .take(20)
      .toList(growable: false);
  String? get dailyRecommendationsDate => _dailyRecommendationsDate;
  bool get isLoadingDailyRecommendations => _dailyRecommendationsTask != null;
  Object? get dailyRecommendationsError => _dailyRecommendationsError;

  Future<void> ensureDailyRecommendations({DateTime? now}) {
    if (_disposed) return Future.value();
    final local = now ?? DateTime.now();
    final date =
        '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    final pending = _dailyRecommendationsTask;
    if (pending != null) {
      if (_dailyRequestedDate == date) return pending;
      _dailyRecommendationsCancellation?.cancel();
    }
    _dailyRequestedDate = date;
    final epoch = _runtimeCacheEpoch;
    final cancellation = AsmrRequestCancellationToken();
    _dailyRecommendationsCancellation = cancellation;
    late final Future<void> task;
    task = (() async {
      try {
        await initializeForVisiblePage();
        cancellation.throwIfCancelled();
        final language = _contentLanguage;
        if (_dailyRecommendationsLanguage == language &&
            _dailyRecommendationsDate == date) {
          return;
        }
        final cached = await _preferencesStore.loadDailyRecommendations(
          language,
        );
        cancellation.throwIfCancelled();
        if (_disposed ||
            epoch != _runtimeCacheEpoch ||
            language != _contentLanguage) {
          return;
        }
        _dailyRecommendationsLanguage = language;
        _dailyRecommendations = cached?.works ?? const [];
        _dailyRecommendationsDate = cached?.date;
        _dailyRecommendationsError = null;
        notifyListeners();
        if (cached?.date == date) return;
        final works = await _remoteCatalogService.loadDailyRecommendations(
          language: language,
          daySeed: local.year * 10000 + local.month * 100 + local.day,
          previousWorkKeys: _dailyRecommendations
              .take(20)
              .map((work) => work.workKey)
              .toSet(),
          cancellationToken: cancellation,
        );
        cancellation.throwIfCancelled();
        await _runStateMutation(() async {
          cancellation.throwIfCancelled();
          if (_disposed ||
              epoch != _runtimeCacheEpoch ||
              language != _contentLanguage) {
            return;
          }
          await _preferencesStore.saveDailyRecommendations(
            language: language,
            date: date,
            works: works,
          );
          if (_disposed ||
              cancellation.isCancelled ||
              epoch != _runtimeCacheEpoch ||
              language != _contentLanguage) {
            return;
          }
          _dailyRecommendations = List.unmodifiable(works);
          _dailyRecommendationsDate = date;
        });
      } on AsmrRequestCancelled {
        // A restore or language change owns the new cache boundary.
      } catch (error) {
        if (!_disposed &&
            !cancellation.isCancelled &&
            epoch == _runtimeCacheEpoch) {
          _dailyRecommendationsError = error;
        }
      } finally {
        if (identical(_dailyRecommendationsTask, task)) {
          _dailyRecommendationsTask = null;
          _dailyRecommendationsCancellation = null;
        }
        if (!_disposed) notifyListeners();
      }
    })();
    _dailyRecommendationsTask = task;
    _dailyRecommendationsError = null;
    notifyListeners();
    return task;
  }

  void _invalidateDailyRecommendations() {
    _dailyRecommendationsCancellation?.cancel();
    _dailyRecommendationsTask = null;
    _dailyRecommendations = const [];
    _dailyRecommendationsDate = null;
    _dailyRecommendationsLanguage = null;
    _dailyRecommendationsError = null;
  }

  bool _isWorkAllowed(AsmrWork work) =>
      !_tagPreferences.excludes(names: work.tags, ids: work.tagIds);

  Future<void> _mutateTagPreferences(
    void Function(AsmrTagPreferences) mutate, {
    bool interruptRecommendations = false,
  }) => _runStateMutation(() async {
    final next = AsmrTagPreferences.fromJson(_tagPreferences.toJson());
    mutate(next);
    await _preferencesStore.saveTagPreferences(next);
    if (_disposed) return;
    _tagPreferences = next;
    _catalog.preferencesChanged(
      interruptRecommendations: interruptRecommendations,
    );
    _bumpGlobalRevision();
    notifyListeners();
  });

  Future<void> setTagInterested(String key, bool interested) =>
      applyTagSelections(excluded: false, changes: {key: interested});

  /// Commits one editor's changes together so a failed save leaves no partial selection.
  Future<void> applyTagSelections({
    required bool excluded,
    required Map<String, bool> changes,
  }) async {
    if (changes.isEmpty) return;
    final selections = Map<String, bool>.of(changes);
    await ensureTagInterests();
    await _mutateTagPreferences((state) {
      for (final entry in selections.entries) {
        if (!excluded) {
          state.setInterested(entry.key, entry.value);
        } else {
          if (!state.tags.containsKey(entry.key)) {
            throw ArgumentError.value(entry.key, 'key');
          }
          if (entry.value) {
            state.excluded.add(entry.key);
          } else {
            state.excluded.remove(entry.key);
          }
        }
      }
    }, interruptRecommendations: true);
    await _refreshRecommendationsAfterPreferenceChange();
  }

  Future<void> _refreshRecommendationsAfterPreferenceChange() async {
    if (!_catalog.hasLoaded(AsmrCategoryType.recommendation)) return;
    await refreshCategory(
      AsmrCategoryType.recommendation,
      searchQuery: _catalog.activeQuery(AsmrCategoryType.recommendation),
    );
  }

  Future<void> setTagExcluded(String key, bool excluded) =>
      applyTagSelections(excluded: true, changes: {key: excluded});

  Future<void> recordTagListeningBatch({
    required String batchId,
    required List<({List<String> tags, Duration duration})> contributions,
  }) async {
    await ensureTagInterests();
    await _mutateTagPreferences(
      (state) => state.recordListeningBatch(batchId, contributions),
    );
  }

  Future<void> recordTagListening({
    required String batchId,
    required List<String> tags,
    required Duration duration,
  }) => recordTagListeningBatch(
    batchId: batchId,
    contributions: [(tags: tags, duration: duration)],
  );

  Future<void> ensureTagCatalog({bool force = false}) {
    final pending = _tagCatalogTask;
    if (pending != null) return pending;
    if (!force && tagCatalogComplete) return ensureTagInterests();
    late final Future<void> task;
    task = _loadTagCatalog().whenComplete(() {
      if (identical(task, _tagCatalogTask)) _tagCatalogTask = null;
      notifyListeners();
    });
    _tagCatalogTask = task;
    notifyListeners();
    return task;
  }

  Future<void> _loadTagCatalog() async {
    await initializeForVisiblePage();
    final epoch = _runtimeCacheEpoch;
    _tagCatalogError = null;
    try {
      await ensureTagInterests();
      final tags = await _remoteCatalogService.loadTagCatalog();
      if (_disposed || epoch != _runtimeCacheEpoch) return;
      await _mutateTagPreferences((state) {
        for (final tag in tags) {
          state.mergeTag(tag);
        }
        state.catalogComplete = true;
      });
    } catch (error) {
      _tagCatalogError = error;
    }
  }

  Future<void> ensureTagInterests({List<MusicTrack>? localTracks}) async {
    await initializeForVisiblePage();
    if (_disposed || _tagInterestsReady) return;
    final pending = _tagInterestsTask;
    if (pending != null) return pending;
    final epoch = _runtimeCacheEpoch;
    late final Future<void> task;
    task =
        (() async {
          final tracks =
              localTracks ??
              await _remoteCatalogService.loadLocalTracksForInterests();
          await _runStateMutation(() async {
            if (_disposed || epoch != _runtimeCacheEpoch) return;
            // Serialize against preference edits, but derive the full library's
            // tags away from the UI isolate and reuse recommendation inputs.
            final state = await compute(_deriveTagInterests, (
              state: _tagPreferences,
              tracks: tracks,
              favorites: _favoriteWorks,
              history: _historyWorks,
            ));
            if (_disposed || epoch != _runtimeCacheEpoch) return;
            await _preferencesStore.saveTagPreferences(state);
            if (_disposed || epoch != _runtimeCacheEpoch) return;
            _tagPreferences = state;
            _tagInterestsReady = true;
            _bumpGlobalRevision();
            notifyListeners();
          });
        })().whenComplete(() {
          if (identical(_tagInterestsTask, task)) _tagInterestsTask = null;
        });
    _tagInterestsTask = task;
    return task;
  }

  List<AsmrCategoryType> _visibleCategories = kDefaultVisibleAsmrCategories;
  ContentLanguagePreference _contentLanguagePreference =
      ContentLanguagePreference.followPage;
  AppLanguage _pageLanguage = AppLanguage.zh;
  AsmrContentLanguage _contentLanguage = AsmrContentLanguage.zh;
  List<AsmrWork> _favoriteWorks = const <AsmrWork>[];
  Set<String> _favoriteIds = const <String>{};
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
  AsmrRequestCancellationToken? _activeSyncCancellationToken;
  Future<void> _stateMutationTail = Future<void>.value();
  bool _initialized = false;
  int _globalRevision = 0;
  int _authEpoch = 0;
  int _contentEpoch = 0;
  int _runtimeCacheEpoch = 0;
  int _resourceSourceEpoch = 0;
  bool _disposed = false;
  String get browseCacheScope =>
      '${_authSession?.userName.trim() ?? ''}:${_contentLanguage.name}';

  void beginSearchSession() => _catalog.clearSearchQueries();
  void endSearchSession() => _catalog.clearSearchQueries();
  void setSearchQuery(String query, AsmrCategoryType category) =>
      _catalog.setSearchQuery(query, category);

  void clearRuntimeCaches() {
    _invalidateDailyRecommendations();
    _runtimeCacheEpoch++;
    _contentEpoch++;
    _catalog.clearWorks();
    _workContent.clearCaches(clearErrors: true);
    _workContent.bumpAllTrackRevisions();
    notifyListeners();
  }

  /// Refresh future resource selection without touching catalog pages or sessions.
  void invalidateResourceSource() {
    _resourceSourceEpoch++;
    _workContent.clearCaches(clearErrors: true);
    _workContent.bumpAllTrackRevisions();
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  Future<T> _runStateMutation<T>(Future<T> Function() mutation) {
    final result = _stateMutationTail.then((_) => mutation());
    _stateMutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  AsmrWorkRequestKey _workRequestKey(String workKey) => (
    workKey: workKey,
    contentEpoch: _contentEpoch + _resourceSourceEpoch,
    authEpoch: _authEpoch,
    runtimeCacheEpoch: _runtimeCacheEpoch,
  );

  bool _isWorkRequestCurrent(AsmrWorkRequestKey key) =>
      !_disposed &&
      key.contentEpoch == _contentEpoch + _resourceSourceEpoch &&
      key.authEpoch == _authEpoch &&
      key.runtimeCacheEpoch == _runtimeCacheEpoch;

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
    _catalog.refreshLocalSearch();
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
  bool isFavorite(String workKey) => _favoriteIds.contains(workKey);
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
  bool isTrackTreeLoading(String workKey) => _workContent.isLoading(workKey);
  List<AsmrTrackFile>? trackTreeFor(String workKey) =>
      _workContent.cachedTrackTree(workKey);

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
    bool searchSession = false,
  }) => _catalog.viewState(
    category,
    searchQuery: searchQuery,
    searchSession: searchSession,
  );

  AsmrTrackTreeViewState trackTreeViewState(String workKey) =>
      _workContent.trackTreeViewState(workKey);

  List<AsmrWork> worksFor(AsmrCategoryType category) =>
      _catalog.worksFor(category);

  List<AsmrWork> filteredWorksFor(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) => _catalog.filteredWorksFor(
    category,
    searchQuery: searchQuery,
    searchSession: searchSession,
  );

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
    final tagPreferences = await _preferencesStore.loadTagPreferences();
    if (_disposed) return;
    _tagPreferences = tagPreferences;
    _catalog.updateLocalCounts();
    _initialized = true;
    _bumpGlobalRevision();
    notifyListeners();
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
        notifyListeners();
      }
    });
    _authRestoreTask = task;
    _bumpGlobalRevision();
    notifyListeners();
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
      notifyListeners();
      _refreshLoadedCategoriesForCurrentAuth();
    } catch (error) {
      if (requestEpoch != _authEpoch) return;
      _lastSyncError = error;
      _bumpGlobalRevision();
      notifyListeners();
    }
  }

  @override
  Future<void> reloadPersistedState() async {
    _invalidateDailyRecommendations();
    _initialized = false;
    _tagInterestsReady = false;
    _tagInterestsTask = null;
    _runtimeCacheEpoch++;
    _contentEpoch++;
    _catalog.clearWorks();
    _workContent.clearCaches(clearErrors: true);
    // Let an already-started preference write finish before reloading it.
    await _stateMutationTail;
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
      _invalidateRemoteWorkCaches();
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
    final previousSession = _authSession;
    final logoutEpoch = ++_authEpoch;
    _authSession = null;
    _cancelActiveSync();
    _catalog.invalidateForAuthChange();
    _invalidateRemoteWorkCaches();
    final AsmrAccountSnapshot snapshot;
    try {
      snapshot = await _accountSyncService.logout();
    } catch (_) {
      if (logoutEpoch == _authEpoch) {
        _authSession = previousSession;
        _authEpoch++;
        _catalog.invalidateForAuthChange();
        _invalidateRemoteWorkCaches();
      }
      rethrow;
    }
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
    task = _syncAsmrAccountInternal(key)
        .then<void>((completedKey) async {
          if (!identical(_syncTasks[key], task)) return;
          unawaited(_syncTasks.remove(key));
          // Mutations can arrive after the batch drained, during the last sync
          // timestamp write. Token recovery can also change the completed key.
          if (!_disposed &&
              completedKey != null &&
              completedKey.authEpoch == _authEpoch &&
              completedKey.token == _authSession?.token &&
              _accountSyncService.snapshot.pendingOperations.isNotEmpty) {
            await syncAsmrAccount();
          }
        })
        .whenComplete(() {
          if (identical(_syncTasks[key], task)) {
            unawaited(_syncTasks.remove(key));
          }
        });
    _syncTasks[key] = task;
    return task;
  }

  Future<_AsmrSyncRequestKey?> _syncAsmrAccountInternal(
    _AsmrSyncRequestKey key,
  ) async {
    if (key.authEpoch != _authEpoch || key.token != _authSession?.token) {
      return null;
    }
    final cancellationToken = AsmrRequestCancellationToken();
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
      if (cancellationToken.isCancelled || key.authEpoch != _authEpoch) {
        return null;
      }
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
      final session = _authSession;
      return result.succeeded && session != null
          ? (authEpoch: _authEpoch, token: session.token)
          : null;
    } on AsmrRequestCancelled {
      return null;
    } catch (error) {
      if (_disposed ||
          cancellationToken.isCancelled ||
          key.authEpoch != _authEpoch ||
          !identical(_activeSyncCancellationToken, cancellationToken)) {
        return null;
      }
      _syncPhase = AsmrSyncPhase.failed;
      _lastSyncError = error;
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
    return null;
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
    _invalidateDailyRecommendations();
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
    bool searchSession = false,
  }) async {
    if (searchSession) setSearchQuery(searchQuery, category);
    final searchEpoch = _catalog.searchEpoch;
    final authEpoch = _authEpoch;
    final contentEpoch = _contentEpoch;
    await initializeForVisiblePage();
    if (_disposed ||
        authEpoch != _authEpoch ||
        contentEpoch != _contentEpoch ||
        (searchSession &&
            (searchEpoch != _catalog.searchEpoch ||
                !_catalog.isSearchRequestCurrent(searchQuery, category)))) {
      return;
    }
    final pending = _catalog.pendingRefresh(
      category,
      searchQuery: searchQuery,
      searchSession: searchSession,
    );
    if (pending != null) {
      await pending;
      return;
    }
    if (_catalog.hasAttemptedLoad(
      category,
      searchQuery: searchQuery,
      searchSession: searchSession,
    )) {
      return;
    }
    await _catalog.refresh(
      category,
      searchQuery: searchQuery,
      searchSession: searchSession,
      context: _categoryRequestContext,
    );
  }

  Future<void> refreshCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {
    if (searchSession) setSearchQuery(searchQuery, category);
    final searchEpoch = _catalog.searchEpoch;
    final authEpoch = _authEpoch;
    final contentEpoch = _contentEpoch;
    await initialize();
    if (_disposed ||
        authEpoch != _authEpoch ||
        contentEpoch != _contentEpoch ||
        (searchSession &&
            (searchEpoch != _catalog.searchEpoch ||
                !_catalog.isSearchRequestCurrent(searchQuery, category)))) {
      return;
    }
    await _catalog.refresh(
      category,
      searchQuery: searchQuery,
      searchSession: searchSession,
      context: _categoryRequestContext,
    );
  }

  Future<void> loadMoreCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {
    if (searchSession) setSearchQuery(searchQuery, category);
    final searchEpoch = _catalog.searchEpoch;
    final authEpoch = _authEpoch;
    final contentEpoch = _contentEpoch;
    await initialize();
    if (_disposed ||
        authEpoch != _authEpoch ||
        contentEpoch != _contentEpoch ||
        (searchSession &&
            (searchEpoch != _catalog.searchEpoch ||
                !_catalog.isSearchRequestCurrent(searchQuery, category)))) {
      return;
    }
    await _catalog.loadMore(
      category,
      searchQuery: searchQuery,
      searchSession: searchSession,
      context: _categoryRequestContext,
    );
  }

  @override
  Future<List<MusicTrack>> loadPlayableTracks(AsmrWork work) async {
    await initializeForVisiblePage();
    final key = _workRequestKey(work.workKey);
    if (_disposed) throw StateError('asmr_content_invalidated');
    final tree = await ensureTrackTree(work);
    if (_disposed || key.runtimeCacheEpoch != _runtimeCacheEpoch) {
      throw StateError('asmr_content_invalidated');
    }
    if (!_isWorkRequestCurrent(key) ||
        !identical(tree, _workContent.cachedTrackTree(work.workKey))) {
      return loadPlayableTracks(work);
    }
    final cached = _workContent.cachedPlayableTracks(work);
    if (cached != null) return cached;
    return _workContent.requestPlayableTracks(
      key,
      work,
      tree,
      () => _loadPlayableTracksOnce(work, tree, key),
    );
  }

  Future<List<MusicTrack>> _loadPlayableTracksOnce(
    AsmrWork work,
    List<AsmrTrackFile> tree,
    AsmrWorkRequestKey key,
  ) async {
    final tracks = await compute(_buildPlayableTracks, (
      work: work,
      tree: tree,
    ), debugLabel: 'asmr_playable_tracks');
    if (_disposed || key.runtimeCacheEpoch != _runtimeCacheEpoch) {
      throw StateError('asmr_content_invalidated');
    }
    // Conversion can outlive an account/language change or a tree refresh.
    if (!_isWorkRequestCurrent(key) ||
        !identical(tree, _workContent.cachedTrackTree(work.workKey))) {
      return loadPlayableTracks(work);
    }
    return _workContent.storePlayableTracks(work, tracks);
  }

  Future<List<WorkTextFile>> findWorkTextFiles(
    AsmrWork work, {
    AsmrDownloadManager? downloadManager,
  }) async {
    final tree = await ensureTrackTree(work);
    return collectAsmrWorkTextFiles(
      tree,
      downloadManager: downloadManager,
      workKey: work.workKey,
    );
  }

  List<MusicTrack> buildPlayableTracksFromNode(
    AsmrWork work,
    AsmrTrackFile node,
  ) {
    if (node.isFolder) {
      return flattenAsmrPlayableTracks(work, <AsmrTrackFile>[node]);
    }
    return flattenAsmrPlayableTracks(
      work,
      _workContent.cachedTrackTree(work.workKey) ?? <AsmrTrackFile>[node],
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

  Future<List<AsmrTrackFile>> ensureTrackTree(
    AsmrWork work, {
    bool forceRefresh = false,
  }) {
    final cached = _workContent.cachedTrackTree(work.workKey);
    if (!forceRefresh && cached != null) {
      return SynchronousFuture<List<AsmrTrackFile>>(cached);
    }
    final key = _workRequestKey(work.workKey);
    return _workContent.requestTrackTree(
      key,
      (cancellationToken) => _loadTrackTreeOnce(work, key, cancellationToken),
    );
  }

  Future<List<AsmrTrackFile>> _loadTrackTreeOnce(
    AsmrWork work,
    AsmrWorkRequestKey key,
    AsmrRequestCancellationToken cancellationToken,
  ) async {
    try {
      final tree = await cancellationToken.waitFor(
        _remoteCatalogService.loadTrackTree(
          work,
          token: _authSession?.token,
          cancellationToken: cancellationToken,
        ),
      );
      if (_isWorkRequestCurrent(key)) {
        final sortedTree = await compute(sortAsmrTrackTreeNaturally, tree);
        // Account, language or cache invalidation can occur during sorting.
        if (_isWorkRequestCurrent(key)) {
          _workContent.clearTrackTreeError(work.workKey);
          final storedTree = _workContent.storeTrackTree(
            work.workKey,
            sortedTree,
          );
          _workContent.bumpTrackRevision(work.workKey);
          return storedTree;
        }
      }
      if (_disposed || key.runtimeCacheEpoch != _runtimeCacheEpoch) {
        throw StateError('asmr_content_invalidated');
      }
      return ensureTrackTree(work);
    } on AsmrRequestCancelled {
      if (_disposed || key.runtimeCacheEpoch != _runtimeCacheEpoch) {
        throw StateError('asmr_content_invalidated');
      }
      if (_isWorkRequestCurrent(key)) rethrow;
      return ensureTrackTree(work);
    } catch (error) {
      if (_isWorkRequestCurrent(key)) {
        _workContent.setTrackTreeError(work.workKey, error);
        _workContent.bumpTrackRevision(work.workKey);
      }
      rethrow;
    }
  }

  Future<void> toggleFavorite(AsmrWork work) {
    return _runStateMutation(() => _mutateFavoritesNow([work]));
  }

  Future<void> setFavorites(List<AsmrWork> works, {required bool favorite}) =>
      _runStateMutation(() => _mutateFavoritesNow(works, favorite: favorite));

  Future<void> _mutateFavoritesNow(
    List<AsmrWork> works, {
    bool? favorite,
  }) async {
    final mutationAuthEpoch = _authEpoch;
    final previous = _accountSyncService.snapshot;
    final snapshot = favorite == null
        ? await _accountSyncService.toggleFavorite(works.single)
        : await _accountSyncService.setFavorites(works, favorite: favorite);
    if (mutationAuthEpoch != _authEpoch) return;
    if (identical(previous, snapshot)) return;
    final previousIds = _favoriteIds;
    _applyAccountSnapshot(snapshot);
    final changedIds = {
      for (final work in works)
        if (previousIds.contains(work.workKey) !=
            _favoriteIds.contains(work.workKey))
          work.workKey: _favoriteIds.contains(work.workKey),
    };
    _catalog.updateFavorites(changedIds);
    _bumpGlobalRevision();
    if (isAsmrAccountLoggedIn) {
      unawaited(syncAsmrAccount());
    }
    _catalog.updateLocalCounts();
    _catalog.bumpRevision(AsmrCategoryType.favorites);
    _catalog.bumpRevision(AsmrCategoryType.history);
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
    _dailyRecommendationsCancellation?.cancel();
    _disposed = true;
    _activeSyncCancellationToken?.cancel();
    _activeSyncCancellationToken = null;
    _authEpoch++;
    _contentEpoch++;
    _catalog.cancelRequests();
    _workContent.cancelRequests();
    super.dispose();
  }
}
