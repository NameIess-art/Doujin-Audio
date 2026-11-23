import 'dart:async';

import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/asmr/application/asmr_account_sync_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_auth_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_category_catalog.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/application/asmr_preferences.dart';
import 'package:doujin_audio/features/asmr/application/asmr_remote_catalog_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_persistence_repository.dart';
import 'package:flutter_test/flutter_test.dart';

AsmrWork _work(int id, {String? title}) => AsmrWork(
  id: id,
  title: title ?? 'Work $id',
  circleName: 'Circle',
  sourceId: 'RJ${id.toString().padLeft(6, '0')}',
  sourceType: 'asmr-one',
  sourceUrl: '',
  coverUrl: '',
  thumbnailUrl: '',
  mainCoverUrl: '',
  releaseDate: null,
  createDate: null,
  duration: Duration.zero,
  dlCount: 0,
  reviewCount: 0,
  rating: 0,
  voiceActors: const <String>[],
  tags: const <String>[],
);

class _MemoryAsmrTokenStore implements AsmrTokenStore {
  String? token;
  Map<String, String>? credentials;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String value) async {
    token = value;
  }

  @override
  Future<void> clearToken() async {
    token = null;
  }

  @override
  Future<Map<String, String>?> readCredentials() async => credentials;

  @override
  Future<void> writeCredentials(String name, String password) async {
    credentials = {'name': name, 'password': password};
  }

  @override
  Future<void> clearCredentials() async {
    credentials = null;
  }
}

class _InMemoryAsmrRepository implements AsmrPersistenceRepository {
  List<String> visibleCategories = const <String>[];
  final Map<String, String> settings = <String, String>{};
  final Map<String, List<AsmrWork>> workLists = <String, List<AsmrWork>>{
    'favorites': <AsmrWork>[],
    'history': <AsmrWork>[],
  };
  List<AsmrSyncOperation> operations = <AsmrSyncOperation>[];

  Completer<void>? loadVisibleGate;
  Completer<void>? saveFavoriteGate;
  Completer<void>? saveFavoriteEntered;

  @override
  Future<List<String>> loadVisibleCategoryNames() async {
    final gate = loadVisibleGate;
    if (gate != null && !gate.isCompleted) {
      await gate.future;
    }
    return List<String>.of(visibleCategories);
  }

  @override
  Future<void> saveVisibleCategoryNames(List<String> categories) async {
    visibleCategories = List<String>.of(categories);
  }

  @override
  Future<String?> loadSetting(String key) async => settings[key];

  @override
  Future<Map<String, String?>> loadSettings(List<String> keys) async => {
    for (final key in keys) key: settings[key],
  };

  @override
  Future<void> saveSetting(String key, String? value) async {
    if (value == null) {
      settings.remove(key);
    } else {
      settings[key] = value;
    }
  }

  @override
  Future<void> saveSettings(Map<String, String> values) async {
    settings.addAll(values);
  }

  @override
  Future<List<AsmrWork>> loadWorkList(String listType) async =>
      List<AsmrWork>.of(workLists[listType] ?? const <AsmrWork>[]);

  @override
  Future<void> saveWorkList(String listType, List<AsmrWork> works) async {
    workLists[listType] = List<AsmrWork>.of(works);
  }

  @override
  Future<List<AsmrSyncOperation>> loadSyncOperations() async =>
      List<AsmrSyncOperation>.of(operations);

  @override
  Future<void> saveSyncOperations(List<AsmrSyncOperation> value) async {
    operations = List<AsmrSyncOperation>.of(value);
  }

  @override
  Future<void> saveHistoryState({
    required AsmrWork work,
    required List<String> historyWorkKeys,
    AsmrSyncOperation? operation,
  }) async {
    final current = workLists['history'] ?? const <AsmrWork>[];
    final byKey = {for (final item in current) item.workKey: item};
    byKey[work.workKey] = work;
    workLists['history'] = [
      for (final key in historyWorkKeys) ?byKey[key],
    ];
    if (operation != null) {
      operations = [
        ...operations.where(
          (item) =>
              !(item.workId == operation.workId && item.type == operation.type),
        ),
        operation,
      ];
    }
  }

  @override
  Future<void> saveFavoriteState({
    required List<AsmrWork> works,
    required bool favorite,
    required List<AsmrSyncOperation> operations,
  }) async {
    if (saveFavoriteEntered != null && !saveFavoriteEntered!.isCompleted) {
      saveFavoriteEntered!.complete();
    }
    final gate = saveFavoriteGate;
    if (gate != null && !gate.isCompleted) {
      await gate.future;
    }
    final changedKeys = {for (final w in works) w.workKey};
    final current = workLists['favorites'] ?? const <AsmrWork>[];
    workLists['favorites'] = [
      if (favorite) ...works.reversed,
      ...current.where((w) => !changedKeys.contains(w.workKey)),
    ];
    final changedIds = {for (final op in operations) op.workId};
    this.operations = [
      ...this.operations.where(
        (op) =>
            !changedIds.contains(op.workId) ||
            (op.type != AsmrSyncOperationType.favoriteAdd &&
                op.type != AsmrSyncOperationType.favoriteRemove),
      ),
      ...operations,
    ];
  }

  @override
  Future<void> saveAccountSyncState({
    required List<AsmrWork> favoriteWorks,
    required List<AsmrWork> historyWorks,
    required List<AsmrSyncOperation> operations,
  }) async {
    workLists['favorites'] = List<AsmrWork>.of(favoriteWorks);
    workLists['history'] = List<AsmrWork>.of(historyWorks);
    this.operations = List<AsmrSyncOperation>.of(operations);
  }

  @override
  Future<List<MusicTrack>> loadTracksForRecommendations() async =>
      const <MusicTrack>[];

  @override
  Future<void> clearForTest() async {
    visibleCategories = const <String>[];
    settings.clear();
    workLists['favorites'] = <AsmrWork>[];
    workLists['history'] = <AsmrWork>[];
    operations = <AsmrSyncOperation>[];
  }
}

class _FakeAsmrApiService extends AsmrApiService {
  _FakeAsmrApiService();

  final Map<String, List<AsmrReviewRecord>> reviewsByFilter = {};
  final List<(int workId, String progress, String token)> putCalls = [];
  Completer<void>? fetchReviewsEntered;
  Completer<void>? fetchReviewsGate;
  Completer<void>? verifyTokenGate;
  Completer<void>? verifyTokenEntered;
  String? authFailureToken;
  int verifyCalls = 0;

  @override
  Future<AsmrAuthSession> login({
    required String name,
    required String password,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    return AsmrAuthSession(token: 'token-$name', userName: name);
  }

  @override
  Future<AsmrAuthSession?> checkSession(String token) async {
    verifyCalls++;
    if (verifyTokenEntered != null && !verifyTokenEntered!.isCompleted) {
      verifyTokenEntered!.complete();
    }
    final gate = verifyTokenGate;
    if (gate != null && !gate.isCompleted) {
      await gate.future;
    }
    if (token == authFailureToken) {
      throw const AsmrApiException('Unauthorized', statusCode: 401);
    }
    final user = token.startsWith('token-') ? token.substring(6) : 'user';
    return AsmrAuthSession(token: token, userName: user);
  }

  @override
  Future<List<AsmrReviewRecord>> fetchReviews({
    required String token,
    String? filter,
    int page = 1,
    String order = 'updated_at',
    String sort = 'desc',
    AsmrContentLanguage language = AsmrContentLanguage.zh,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    if (fetchReviewsEntered != null && !fetchReviewsEntered!.isCompleted) {
      fetchReviewsEntered!.complete();
    }
    final gate = fetchReviewsGate;
    if (gate != null && !gate.isCompleted) {
      await cancellationToken?.waitFor(gate.future);
    }
    cancellationToken?.throwIfCancelled();
    if (token == authFailureToken) {
      throw const AsmrApiException('Unauthorized', statusCode: 401);
    }
    if (page > 1) return const <AsmrReviewRecord>[];
    return reviewsByFilter[filter] ?? const <AsmrReviewRecord>[];
  }

  @override
  Future<void> putReviewProgress({
    required int workId,
    required String progress,
    required String token,
  }) async {
    if (token == authFailureToken) {
      throw const AsmrApiException('Unauthorized', statusCode: 401);
    }
    putCalls.add((workId, progress, token));
  }

  @override
  Future<void> deleteReview({required int workId, required String token}) async {}
}

void main() {
  test(
    '#29 concurrent favorite write does not clobber remoteProgressByWorkId from synchronize preflight',
    () async {
      final repo = _InMemoryAsmrRepository();
      final prefs = AsmrPreferencesStore(repository: repo);
      final api = _FakeAsmrApiService();
      addTearDown(api.close);
      final tokenStore = _MemoryAsmrTokenStore();
      final auth = AsmrAuthService(apiService: api, tokenStore: tokenStore);
      final sync = AsmrAccountSyncService(
        authService: auth,
        apiService: api,
        preferencesStore: prefs,
      );

      await sync.initialize();
      await sync.login('alice', 'secret');
      final protectedWork = _work(10);
      final otherWork = _work(20);
      await sync.recordHistory(protectedWork);

      // Server reports work 10 is already 'listened' (protected).
      api.reviewsByFilter['listened'] = [
        AsmrReviewRecord(
          work: protectedWork,
          progress: 'listened',
          updatedAt: DateTime(2026),
        ),
      ];

      // Block saveFavoriteState while synchronize() runs _preflightProtectedProgress().
      repo.saveFavoriteEntered = Completer<void>();
      repo.saveFavoriteGate = Completer<void>();
      final favFuture = sync.toggleFavorite(otherWork);
      await repo.saveFavoriteEntered!.future;

      final syncFuture = sync.synchronize(
        language: AsmrContentLanguage.zh,
        cancellationToken: AsmrRequestCancellationToken(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      repo.saveFavoriteGate!.complete();

      await favFuture;
      final result = await syncFuture;
      expect(result.succeeded, isTrue);
      // Protected work 10 must NOT have been downgraded to 'listening'.
      expect(
        api.putCalls.where((call) => call.$1 == 10 && call.$2 == 'listening'),
        isEmpty,
      );
      expect(result.snapshot.favoriteIds, contains(otherWork.workKey));
      expect(result.snapshot.remoteProgressByWorkId[10], 'listened');
    },
  );

  test(
    '#29 auth-failure logout in synchronize does not race with concurrent favorite write',
    () async {
      final repo = _InMemoryAsmrRepository();
      final prefs = AsmrPreferencesStore(repository: repo);
      final api = _FakeAsmrApiService();
      addTearDown(api.close);
      final tokenStore = _MemoryAsmrTokenStore();
      final auth = AsmrAuthService(apiService: api, tokenStore: tokenStore);
      final sync = AsmrAccountSyncService(
        authService: auth,
        apiService: api,
        preferencesStore: prefs,
      );

      await sync.initialize();
      await sync.login('alice', 'secret');
      // Force token to fail auth on both review fetch and refresh.
      api.authFailureToken = 'token-alice';
      await tokenStore.clearCredentials();

      repo.saveFavoriteEntered = Completer<void>();
      repo.saveFavoriteGate = Completer<void>();
      final favFuture = sync.toggleFavorite(_work(30));
      await repo.saveFavoriteEntered!.future;

      final syncFuture = sync.synchronize(
        language: AsmrContentLanguage.zh,
        cancellationToken: AsmrRequestCancellationToken(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      repo.saveFavoriteGate!.complete();

      await favFuture;
      final result = await syncFuture;
      expect(result.succeeded, isFalse);
      // Session must remain cleared (not resurrected by concurrent favorite write)
      // and the favorite must remain committed.
      expect(sync.snapshot.session, isNull);
      expect(sync.snapshot.favoriteIds, contains(_work(30).workKey));
    },
  );

  test(
    '#30 favorite and history mutations remain visible when auth restore advances _authEpoch',
    () async {
      final repo = _InMemoryAsmrRepository();
      final prefs = AsmrPreferencesStore(repository: repo);
      final api = _FakeAsmrApiService();
      addTearDown(api.close);
      final tokenStore = _MemoryAsmrTokenStore()..token = 'token-alice';
      final auth = AsmrAuthService(apiService: api, tokenStore: tokenStore);
      final sync = AsmrAccountSyncService(
        authService: auth,
        apiService: api,
        preferencesStore: prefs,
      );
      final controller = AsmrLibraryController(
        preferencesStore: prefs,
        remoteCatalogService: AsmrRemoteCatalogService(
          apiService: api,
          persistenceRepository: repo,
        ),
        accountSyncService: sync,
        backgroundSyncDebounce: Duration.zero,
      );
      addTearDown(controller.dispose);

      api.verifyTokenEntered = Completer<void>();
      api.verifyTokenGate = Completer<void>();
      await controller.initialize();
      await api.verifyTokenEntered!.future;

      // Queue favorite + history while restoreSession() holds _mutationTail.
      final work1 = _work(101);
      final work2 = _work(102);
      final favFuture = controller.toggleFavorite(work1);
      final historyFuture = controller.recordHistory(work2);

      // Complete restoreSession(), which advances _authEpoch before fav/history finish.
      api.verifyTokenGate!.complete();
      await Future.wait([favFuture, historyFuture]);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(controller.isAsmrAccountLoggedIn, isTrue);
      expect(controller.isFavorite(work1.workKey), isTrue);
      expect(
        controller
            .categoryViewState(AsmrCategoryType.history)
            .works
            .map((work) => work.workKey),
        contains(work2.workKey),
      );
    },
  );

  test(
    '#30 concurrent logout during favorite write does not resurrect session',
    () async {
      final repo = _InMemoryAsmrRepository();
      final prefs = AsmrPreferencesStore(repository: repo);
      final api = _FakeAsmrApiService();
      addTearDown(api.close);
      final tokenStore = _MemoryAsmrTokenStore();
      final auth = AsmrAuthService(apiService: api, tokenStore: tokenStore);
      final sync = AsmrAccountSyncService(
        authService: auth,
        apiService: api,
        preferencesStore: prefs,
      );
      final controller = AsmrLibraryController(
        preferencesStore: prefs,
        remoteCatalogService: AsmrRemoteCatalogService(
          apiService: api,
          persistenceRepository: repo,
        ),
        accountSyncService: sync,
        backgroundSyncDebounce: Duration.zero,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.loginAsmrAccount('alice', 'secret');

      repo.saveFavoriteEntered = Completer<void>();
      repo.saveFavoriteGate = Completer<void>();
      final work = _work(201);
      final favFuture = controller.toggleFavorite(work);
      await repo.saveFavoriteEntered!.future;

      final logoutFuture = controller.logoutAsmrAccount();
      repo.saveFavoriteGate!.complete();
      await Future.wait([favFuture, logoutFuture]);

      expect(controller.isAsmrAccountLoggedIn, isFalse);
      expect(controller.isFavorite(work.workKey), isTrue);
    },
  );

  test(
    '#56 reloadPersistedState cancels active sync, supersedes in-flight initialize, and forces session restore',
    () async {
      final repo = _InMemoryAsmrRepository();
      final prefs = AsmrPreferencesStore(repository: repo);
      final api = _FakeAsmrApiService();
      addTearDown(api.close);
      final tokenStore = _MemoryAsmrTokenStore();
      final auth = AsmrAuthService(apiService: api, tokenStore: tokenStore);
      final sync = AsmrAccountSyncService(
        authService: auth,
        apiService: api,
        preferencesStore: prefs,
      );
      final controller = AsmrLibraryController(
        preferencesStore: prefs,
        remoteCatalogService: AsmrRemoteCatalogService(
          apiService: api,
          persistenceRepository: repo,
        ),
        accountSyncService: sync,
        backgroundSyncDebounce: Duration.zero,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.loginAsmrAccount('alice', 'secret');
      expect(controller.asmrAccountName, 'alice');

      // Start an in-flight sync that hangs on fetchReviews.
      api.fetchReviewsEntered = Completer<void>();
      api.fetchReviewsGate = Completer<void>();
      final staleSync = controller.syncAsmrAccount(force: true);
      await api.fetchReviewsEntered!.future;

      // Simulate restored backup replacing stored token and favorites.
      tokenStore.token = 'token-bob';
      repo.workLists['favorites'] = [_work(5601, title: 'Restored Favorite')];

      await controller.reloadPersistedState();
      await staleSync;

      expect(controller.isAsmrAccountLoggedIn, isTrue);
      expect(controller.asmrAccountName, 'bob');
      expect(controller.isFavorite(_work(5601).workKey), isTrue);
    },
  );

  test(
    '#56 reloadPersistedState supersedes an already in-flight initialize',
    () async {
      final repo = _InMemoryAsmrRepository();
      repo.workLists['favorites'] = [_work(1, title: 'Old Favorite')];
      repo.loadVisibleGate = Completer<void>();

      final prefs = AsmrPreferencesStore(repository: repo);
      final api = _FakeAsmrApiService();
      addTearDown(api.close);
      final tokenStore = _MemoryAsmrTokenStore()..token = 'token-restored';
      final auth = AsmrAuthService(apiService: api, tokenStore: tokenStore);
      final sync = AsmrAccountSyncService(
        authService: auth,
        apiService: api,
        preferencesStore: prefs,
      );
      final controller = AsmrLibraryController(
        preferencesStore: prefs,
        remoteCatalogService: AsmrRemoteCatalogService(
          apiService: api,
          persistenceRepository: repo,
        ),
        accountSyncService: sync,
        backgroundSyncDebounce: Duration.zero,
      );
      addTearDown(controller.dispose);

      // Begin initial load that blocks on loadVisibleCategoryNames.
      final initialInit = controller.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Update backing store as if a backup restore replaced disk state, then reload.
      repo.workLists['favorites'] = [_work(2, title: 'New Favorite')];
      final reloadFuture = controller.reloadPersistedState();
      repo.loadVisibleGate!.complete();

      await Future.wait([initialInit, reloadFuture]);

      expect(controller.isFavorite(_work(1).workKey), isFalse);
      expect(controller.isFavorite(_work(2).workKey), isTrue);
      expect(controller.asmrAccountName, 'restored');
    },
  );

  test(
    'H22 AsmrCategoryCatalog.loadMore does not self-deadlock with refresh when works is null',
    () async {
      final repo = _InMemoryAsmrRepository();
      final api = _FakeAsmrApiService();
      addTearDown(api.close);

      const context = (
        authEpoch: 0,
        token: null,
        contentEpoch: 0,
        language: AsmrContentLanguage.zh,
        scope: 'h22',
      );
      var callCount = 0;
      final firstGate = Completer<void>();
      final secondEntered = Completer<void>();
      final secondGate = Completer<void>();

      final remote = _FakeRemoteCatalogService(
        apiService: api,
        persistenceRepository: repo,
        onLoadPage: (page) async {
          callCount++;
          if (callCount == 1) {
            await firstGate.future;
            throw StateError('transient failure 1');
          }
          if (!secondEntered.isCompleted) secondEntered.complete();
          await secondGate.future;
          return AsmrWorkPage(
            works: [_work(2201, title: 'Loaded Work')],
            currentPage: page,
            pageSize: 20,
            totalCount: 1,
          );
        },
      );

      final catalog = AsmrCategoryCatalog(
        remoteCatalogService: remote,
        onChanged: () {},
        isContextCurrent: (_) => true,
        currentContext: () => context,
        localWorks: (_) => const <AsmrWork>[],
        favoriteIds: () => const <String>{},
      );

      final initialRefresh = catalog.refresh(
        AsmrCategoryType.release,
        searchQuery: '',
        context: context,
      );
      final pendingLoadMore = catalog.loadMore(
        AsmrCategoryType.release,
        searchQuery: '',
        context: context,
      );

      firstGate.complete();
      await initialRefresh.timeout(const Duration(seconds: 3));
      await secondEntered.future.timeout(const Duration(seconds: 3));

      final concurrentRefresh = catalog.refresh(
        AsmrCategoryType.release,
        searchQuery: '',
        context: context,
      );

      secondGate.complete();
      await Future.wait([
        pendingLoadMore,
        concurrentRefresh,
      ]).timeout(const Duration(seconds: 3));

      expect(callCount, 2);
      expect(
        catalog.worksFor(AsmrCategoryType.release).map((w) => w.id),
        [2201],
      );
    },
  );
}

class _FakeRemoteCatalogService extends AsmrRemoteCatalogService {
  _FakeRemoteCatalogService({
    required super.apiService,
    required super.persistenceRepository,
    required this.onLoadPage,
  });

  final Future<AsmrWorkPage> Function(int page) onLoadPage;

  @override
  Future<AsmrWorkPage> loadPage(
    AsmrCategoryType category, {
    required String searchQuery,
    required int page,
    required AsmrContentLanguage language,
    required String? token,
    AsmrRequestCancellationToken? cancellationToken,
    AsmrCatalogCursor? cursor,
    bool includeJapanese = true,
  }) => onLoadPage(page);
}
