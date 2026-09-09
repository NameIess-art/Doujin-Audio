import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'support/asmr_controller_test_fixture.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'support/test_persistence_repository.dart';
import 'package:doujin_audio/features/settings/application/app_preferences.dart';
import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_account_sync_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_auth_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/application/asmr_preferences.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

part 'asmr_account_sync_tests.part.dart';
part 'asmr_controller_state_tests.part.dart';
part 'asmr_remote_catalog_tests.part.dart';

void main() {
  late Database db;
  late AsmrPreferencesStore preferences;
  late TestPersistenceRepository persistenceRepository;

  Future<void> resetPrefs([Map<String, Object> values = const {}]) async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(values);
    await AppPreferences.init();
    await preferences.clearForTest();
  }

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchemaForTest(db);
    final appDatabase = AppDatabase.test(db);
    AppDatabase.setInstanceForTest(appDatabase);
    persistenceRepository = TestPersistenceRepository(database: appDatabase);
    preferences = AsmrPreferencesStore(repository: persistenceRepository);
  });

  tearDownAll(() async {
    AppDatabase.setInstanceForTest(null);
    await db.close();
  });

  registerAsmrControllerStateTests(
    resetPrefs: resetPrefs,
    preferencesStore: () => preferences,
    persistenceRepository: () => persistenceRepository,
  );
  registerAsmrRemoteCatalogTests(
    resetPrefs: resetPrefs,
    preferencesStore: () => preferences,
  );
  registerAsmrAccountSyncTests(
    resetPrefs: resetPrefs,
    preferencesStore: () => preferences,
  );

  test('ASMR test assembly shares one HTTP client between services', () {
    final overrides = _CountingHttpOverrides();
    HttpOverrides.global = overrides;
    try {
      final controller = createTestAsmrController(
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository,
      );
      expect(overrides.createdClients, 1);
      controller.dispose();
    } finally {
      HttpOverrides.global = null;
    }
  });

  test('controller does not close an injected API service', () {
    final apiService = AsmrApiService();
    final controller = createTestAsmrController(
      apiService: apiService,
      preferencesStore: preferences,
      persistenceRepository: persistenceRepository,
    );

    controller.dispose();
    expect(apiService.isClosed, isFalse);

    apiService.close();
    apiService.close();
    expect(apiService.isClosed, isTrue);
  });

  test(
    'disposing the owner stops initialization before closing the API',
    () async {
      await resetPrefs();
      final api = _CloseCountingAsmrApiService();
      final services = createTestAsmrServices(
        apiService: api,
        preferencesStore: preferences,
        persistenceRepository: persistenceRepository,
      );
      final account = _ControlledAccountInitialization(api, preferences);
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: account,
      );
      final container = ProviderContainer(
        overrides: [
          asmrLibraryControllerProvider.overrideWith((ref) {
            ref.onDispose(() {
              controller.dispose();
              api.close();
            });
            return controller;
          }),
        ],
      );
      expect(container.read(asmrLibraryControllerProvider), same(controller));
      final first = controller.initialize();
      expect(controller.initialize(), same(first));
      await account.started.future;
      container.dispose();
      controller.dispose();
      expect(api.closeCount, 1);
      account.pending.complete(AsmrAccountSnapshot());
      await first;
      expect(controller.initialized, isFalse);
      expect(account.restoreCalls, 0);
      await controller.initialize();
      expect(account.initializeCalls, 1);
    },
  );

  test('ASMR initialization can retry after a dependency failure', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService();
    final services = createTestAsmrServices(
      apiService: api,
      preferencesStore: preferences,
      persistenceRepository: persistenceRepository,
    );
    final account = _ControlledAccountInitialization(api, preferences);
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      remoteCatalogService: services.remoteCatalogService,
      accountSyncService: account,
    );
    addTearDown(controller.dispose);
    final first = controller.initializeForVisiblePage();
    final failure = expectLater(first, throwsStateError);
    await account.started.future;
    account.pending.completeError(StateError('initialization failed'));
    await failure;
    expect(controller.initialized, isFalse);
    account.pending = Completer<AsmrAccountSnapshot>()
      ..complete(AsmrAccountSnapshot());
    await controller.initializeForVisiblePage();
    expect(controller.initialized, isTrue);
    expect(account.initializeCalls, 2);
    expect(account.restoreCalls, 0);
  });
  test(
    'category provider families isolate queries and release their listeners',
    () async {
      await resetPrefs();
      final alpha = _work(id: 11, title: 'Alpha');
      final beta = _work(id: 12, title: 'Beta');
      await preferences.saveFavoriteWorks([alpha, beta]);
      final controller = _ListenerObservedAsmrController(
        createTestAsmrServices(
          preferencesStore: preferences,
          persistenceRepository: persistenceRepository,
          apiService: _FakeAsmrApiService(),
        ),
      );
      addTearDown(controller.dispose);
      await controller.initializeForVisiblePage();
      final container = ProviderContainer(
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      );
      addTearDown(container.dispose);
      final alphaProvider = asmrCategoryStateProvider((
        category: AsmrCategoryType.favorites,
        searchQuery: 'Alpha',
      ));
      final betaProvider = asmrCategoryStateProvider((
        category: AsmrCategoryType.favorites,
        searchQuery: 'Beta',
      ));
      expect(container.read(asmrLibraryControllerProvider), same(controller));
      final alphaSubscription = container.listen(alphaProvider, (_, _) {});
      final betaSubscription = container.listen(betaProvider, (_, _) {});
      await container.pump();
      expect(
        container.read(alphaProvider).value!.works.map((work) => work.id),
        [11],
      );
      expect(container.read(betaProvider).value!.works.map((work) => work.id), [
        12,
      ]);
      expect(controller.hasActiveListeners, isTrue);

      await controller.toggleFavorite(alpha);
      await container.pump();
      expect(container.read(alphaProvider).value!.works, isEmpty);
      expect(container.read(betaProvider).value!.works.map((work) => work.id), [
        12,
      ]);
      alphaSubscription.close();
      await container.pump();
      expect(controller.hasActiveListeners, isTrue);
      betaSubscription.close();
      await container.pump();
      expect(controller.hasActiveListeners, isFalse);

      final resumed = container.listen(alphaProvider, (_, _) {});
      await container.pump();
      expect(controller.hasActiveListeners, isTrue);
      expect(container.read(alphaProvider).value!.works, isEmpty);
      resumed.close();
      await container.pump();
      expect(controller.hasActiveListeners, isFalse);
    },
  );
}

final class _ListenerObservedAsmrController extends AsmrLibraryController {
  _ListenerObservedAsmrController(TestAsmrServices services)
    : super(
        preferencesStore: services.preferencesStore,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: services.accountSyncService,
      );

  bool get hasActiveListeners => hasListeners;
}

final class _CountingHttpOverrides extends HttpOverrides {
  int createdClients = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    createdClients++;
    return super.createHttpClient(context);
  }
}

class _FakeAsmrApiService extends AsmrApiService {
  _FakeAsmrApiService({
    this.largeRecommendationPool = false,
    this.repeatPaginatedWorks = false,
    this.recommendationPageCount = 2,
    this.recommendationWorks,
    this.worksByToken = const <String, List<AsmrWork>>{},
    this.trackTree = const <AsmrTrackFile>[],
    List<AsmrReviewRecord> remoteReviewRecords = const <AsmrReviewRecord>[],
    this.failPutReviewCount = 0,
    this.failingFetchOrders = const <String>{},
    this.transientFetchFailuresRemaining = 0,
    this.emptyCheckSessionUserName = false,
    this.beforeFetchWorkResponse,
    this.beforeFetchWorkDetail,
    this.beforeFetchTrackTree,
  }) : remoteReviewRecords = List<AsmrReviewRecord>.of(remoteReviewRecords),
       super(baseUri: Uri.parse('https://example.test'));

  final List<String> fetchWorkOrders = <String>[];
  final List<String> fetchWorkRequests = <String>[];
  final List<String?> fetchWorkTokens = <String?>[];
  final List<String> searchKeywords = <String>[];
  final List<String> reviewPuts = <String>[];
  final List<int> deletedReviewWorkIds = <int>[];
  final List<String> calls = <String>[];
  final List<int> detailFetchWorkIds = <int>[];
  final List<int> trackFetchWorkIds = <int>[];
  final bool largeRecommendationPool;
  final bool repeatPaginatedWorks;
  final int recommendationPageCount;
  final List<AsmrWork>? recommendationWorks;
  final Map<String, List<AsmrWork>> worksByToken;
  final List<AsmrTrackFile> trackTree;
  final List<AsmrReviewRecord> remoteReviewRecords;
  final Set<String> failingFetchOrders;
  final bool emptyCheckSessionUserName;
  final Future<void> Function(String request)? beforeFetchWorkResponse;
  final Future<void> Function(int workId, AsmrContentLanguage language)?
  beforeFetchWorkDetail;
  final Future<void> Function(int workId)? beforeFetchTrackTree;
  int failPutReviewCount;
  int transientFetchFailuresRemaining;
  int checkSessionAuthFailuresRemaining = 0;
  int fetchReviewAuthFailuresRemaining = 0;
  int? loginFailureStatusCode;
  int loginCount = 0;
  String _lastLoginName = '';
  Future<void> Function(int workId, String progress)? onPutReview;
  Future<void> Function(int workId, String progress, String token)?
  onPutReviewWithToken;
  final List<String> reviewPutTokens = <String>[];

  @override
  Future<AsmrAuthSession> login({
    required String name,
    required String password,
  }) async {
    loginCount++;
    final failureStatusCode = loginFailureStatusCode;
    if (failureStatusCode != null) {
      throw AsmrApiException(
        'Simulated ASMR login auth failure',
        statusCode: failureStatusCode,
        uri: Uri.parse('https://example.test/api/auth/me'),
      );
    }
    _lastLoginName = name;
    return AsmrAuthSession(token: 'token-$name', userName: name);
  }

  @override
  Future<AsmrAuthSession?> checkSession(String token) async {
    if (checkSessionAuthFailuresRemaining > 0) {
      checkSessionAuthFailuresRemaining--;
      throw AsmrApiException(
        'Simulated ASMR session auth failure',
        statusCode: HttpStatus.unauthorized,
        uri: Uri.parse('https://example.test/api/auth/me'),
      );
    }
    if (token.isEmpty) {
      return null;
    }
    final name = _lastLoginName.isEmpty ? 'restored' : _lastLoginName;
    return AsmrAuthSession(
      token: token,
      userName: emptyCheckSessionUserName ? '' : name,
    );
  }

  @override
  Future<AsmrWorkPage> fetchWorks({
    required String order,
    required String sort,
    int page = 1,
    int pageSize = 40,
    String? token,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
  }) {
    final request = '$order:$sort:$page';
    calls.add('works:$order:$sort:$page');
    fetchWorkOrders.add('$order:$sort');
    fetchWorkRequests.add(request);
    fetchWorkTokens.add(token);
    if (transientFetchFailuresRemaining > 0) {
      transientFetchFailuresRemaining--;
      return Future<AsmrWorkPage>.error(
        const HandshakeException('Connection terminated during handshake'),
      );
    }
    if (failingFetchOrders.contains(order)) {
      return Future<AsmrWorkPage>.error(
        HttpException('Simulated ASMR work fetch failure for $order'),
      );
    }
    final beforeResponse = beforeFetchWorkResponse;
    if (beforeResponse != null) {
      return () async {
        await beforeResponse(request);
        return _buildFetchWorksPage(
          order: order,
          page: page,
          pageSize: pageSize,
          token: token,
        );
      }();
    }
    return SynchronousFuture<AsmrWorkPage>(
      _buildFetchWorksPage(
        order: order,
        page: page,
        pageSize: pageSize,
        token: token,
      ),
    );
  }

  AsmrWorkPage _buildFetchWorksPage({
    required String order,
    required int page,
    required int pageSize,
    required String? token,
  }) {
    final tokenWorks = worksByToken[token ?? ''];
    if (tokenWorks != null) {
      return AsmrWorkPage(
        works: tokenWorks,
        currentPage: page,
        pageSize: pageSize,
        totalCount: tokenWorks.length,
      );
    }
    final explicitWorks = recommendationWorks;
    if (explicitWorks != null) {
      return AsmrWorkPage(
        works: explicitWorks,
        currentPage: page,
        pageSize: pageSize,
        totalCount: explicitWorks.length,
      );
    }
    if (largeRecommendationPool) {
      final offset = switch (order) {
        'create_date' => 0,
        'dl_count' => 1000,
        'rate_average_2dp' => 2000,
        'release' => 3000,
        _ => 4000,
      };
      final pageOffset = repeatPaginatedWorks ? 0 : (page - 1) * pageSize;
      return AsmrWorkPage(
        works: <AsmrWork>[
          for (var index = 1; index <= pageSize; index++)
            _work(
              id: offset + pageOffset + index,
              title: 'Candidate ${offset + pageOffset + index}',
            ),
        ],
        currentPage: page,
        pageSize: pageSize,
        totalCount: pageSize * recommendationPageCount,
      );
    }
    return AsmrWorkPage(
      works: <AsmrWork>[
        if (order == 'create_date')
          _work(id: 9, title: 'General New', tags: <String>['rain']),
        if (order == 'dl_count')
          _work(
            id: 10,
            title: 'Sleep Match',
            circleName: 'Dream Circle',
            tags: <String>['sleep'],
            rating: 4.7,
            dlCount: 9000,
            reviewCount: 300,
          ),
        if (order == 'rate_average_2dp')
          _work(id: 11, title: 'Highly Rated', rating: 4.9),
        if (order == 'review_count')
          _work(id: 13, title: 'Most Reviewed', reviewCount: 1200),
        if (order == 'release')
          _work(id: 12, title: 'Latest', releaseDate: DateTime(2026, 5)),
      ],
      currentPage: page,
      pageSize: pageSize,
      totalCount: pageSize,
    );
  }

  @override
  Future<AsmrWorkPage> searchWorks({
    required String keyword,
    required String order,
    required String sort,
    int page = 1,
    int pageSize = 40,
    String? token,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
  }) {
    searchKeywords.add(keyword);
    return SynchronousFuture<AsmrWorkPage>(
      AsmrWorkPage(
        works: <AsmrWork>[
          _work(id: 21, title: 'Search Sleep', tags: <String>['sleep']),
        ],
        currentPage: page,
        pageSize: pageSize,
        totalCount: 1,
      ),
    );
  }

  @override
  Future<AsmrWorkDetail> fetchWorkDetail(
    int workId, {
    String? token,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
  }) async {
    detailFetchWorkIds.add(workId);
    await beforeFetchWorkDetail?.call(workId, language);
    return AsmrWorkDetail(
      work: _work(id: workId, title: '${language.name}:Work $workId'),
      description: '',
      ageCategory: '',
      languageEditionLabels: const <String>[],
      userRating: null,
    );
  }

  @override
  Future<List<AsmrTrackFile>> fetchTrackTree(
    int workId, {
    String? token,
  }) async {
    trackFetchWorkIds.add(workId);
    await beforeFetchTrackTree?.call(workId);
    return trackTree;
  }

  @override
  Future<List<AsmrReviewRecord>> fetchReviews({
    required String token,
    String? filter,
    int page = 1,
    String order = 'updated_at',
    String sort = 'desc',
    AsmrContentLanguage language = AsmrContentLanguage.zh,
  }) async {
    calls.add('fetch:${filter ?? 'all'}:$page');
    if (fetchReviewAuthFailuresRemaining > 0) {
      fetchReviewAuthFailuresRemaining--;
      throw AsmrApiException(
        'Simulated ASMR review auth failure',
        statusCode: HttpStatus.unauthorized,
        uri: Uri.parse('https://example.test/api/review'),
      );
    }
    if (page > 1) {
      return const <AsmrReviewRecord>[];
    }
    return remoteReviewRecords
        .where((record) => filter == null || record.progress == filter)
        .toList(growable: false);
  }

  @override
  Future<void> putReviewProgress({
    required int workId,
    required String progress,
    required String token,
  }) async {
    calls.add('put:$workId:$progress');
    reviewPutTokens.add(token);
    await onPutReviewWithToken?.call(workId, progress, token);
    final callback = onPutReview;
    onPutReview = null;
    if (callback != null) {
      await callback(workId, progress);
    }
    if (failPutReviewCount > 0) {
      failPutReviewCount--;
      throw const HttpException('put review failed');
    }
    reviewPuts.add('$workId:$progress');
  }

  @override
  Future<void> deleteReview({
    required int workId,
    required String token,
  }) async {
    calls.add('delete:$workId');
    deletedReviewWorkIds.add(workId);
  }
}

class _MemoryAsmrTokenStore implements AsmrTokenStore {
  String? token;
  Map<String, String>? credentials;

  @override
  Future<void> clearToken() async {
    token = null;
  }

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String token) async {
    this.token = token;
  }

  @override
  Future<void> clearCredentials() async {
    credentials = null;
  }

  @override
  Future<Map<String, String>?> readCredentials() async => credentials;

  @override
  Future<void> writeCredentials(String username, String password) async {
    credentials = <String, String>{'name': username, 'password': password};
  }
}

class _BlockingAsmrPreferencesStore extends AsmrPreferencesStore {
  _BlockingAsmrPreferencesStore({required super.repository});

  final Completer<void> saveStarted = Completer<void>();
  final Completer<void> releaseSave = Completer<void>();

  @override
  Future<void> saveAccountSyncState({
    required List<AsmrWork> favoriteWorks,
    required List<AsmrWork> historyWorks,
    required List<AsmrSyncOperation> operations,
  }) async {
    if (favoriteWorks.isNotEmpty && !saveStarted.isCompleted) {
      saveStarted.complete();
      await releaseSave.future;
    }
    await super.saveAccountSyncState(
      favoriteWorks: favoriteWorks,
      historyWorks: historyWorks,
      operations: operations,
    );
  }
}

class _FailingAsmrPreferencesStore extends AsmrPreferencesStore {
  _FailingAsmrPreferencesStore({required super.repository});

  @override
  Future<void> saveAccountSyncState({
    required List<AsmrWork> favoriteWorks,
    required List<AsmrWork> historyWorks,
    required List<AsmrSyncOperation> operations,
  }) {
    throw const FileSystemException('forced account state failure');
  }
}

class _BlockingAsmrAuthService extends AsmrAuthService {
  _BlockingAsmrAuthService() : super(apiService: _FakeAsmrApiService());

  final Completer<AsmrAuthSession?> _restoreCompleter =
      Completer<AsmrAuthSession?>();
  int restoreCount = 0;

  @override
  Future<AsmrAuthSession?> restoreSession() {
    restoreCount++;
    return _restoreCompleter.future;
  }

  void complete(AsmrAuthSession? session) {
    if (!_restoreCompleter.isCompleted) {
      _restoreCompleter.complete(session);
    }
  }
}

class _FakeTestPersistenceRepository extends TestPersistenceRepository {
  _FakeTestPersistenceRepository(this.tracks);

  final List<MusicTrack> tracks;

  @override
  Future<List<MusicTrack>> loadAllTracks() async => tracks;
}

AsmrWork _work({
  required int id,
  required String title,
  String circleName = 'Circle',
  DateTime? releaseDate,
  int dlCount = 0,
  int reviewCount = 0,
  double rating = 0,
  List<String> tags = const <String>[],
}) {
  return AsmrWork(
    id: id,
    title: title,
    circleName: circleName,
    sourceId: 'RJ${id.toString().padLeft(6, '0')}',
    sourceType: 'DLSITE',
    sourceUrl: 'https://example.test/$id',
    coverUrl: '',
    thumbnailUrl: '',
    mainCoverUrl: '',
    releaseDate: releaseDate,
    createDate: null,
    duration: Duration.zero,
    dlCount: dlCount,
    reviewCount: reviewCount,
    rating: rating,
    voiceActors: const <String>[],
    tags: tags,
  );
}

MusicTrack _track({
  required String groupTitle,
  String groupSubtitle = 'RJ999999',
  required List<String> tags,
}) {
  return MusicTrack(
    path: '/library/$groupSubtitle/track.mp3',
    displayName: 'track.mp3',
    groupKey: groupSubtitle,
    groupTitle: groupTitle,
    groupSubtitle: groupSubtitle,
    isSingle: false,
    tags: tags,
  );
}

AsmrTrackFile _trackFolder(
  String title,
  String relativePath, {
  List<AsmrTrackFile> children = const <AsmrTrackFile>[],
}) {
  return AsmrTrackFile(
    hash: relativePath,
    title: title,
    type: 'folder',
    streamUrl: null,
    downloadUrl: null,
    lowQualityUrl: null,
    duration: Duration.zero,
    size: 0,
    children: children,
    workId: 1,
    workTitle: 'Work',
    sourceId: 'RJ000001',
    relativePath: relativePath,
  );
}

AsmrTrackFile _trackFile(
  String title,
  String relativePath, {
  String type = 'audio',
  bool officialMedia = false,
}) {
  final mediaHost = officialMedia ? 'api.asmr.one' : 'example.test';
  return AsmrTrackFile(
    hash: relativePath,
    title: title,
    type: type,
    streamUrl: 'https://$mediaHost/$relativePath',
    downloadUrl: 'https://$mediaHost/$relativePath',
    lowQualityUrl: null,
    duration: const Duration(minutes: 1),
    size: 1024,
    children: const <AsmrTrackFile>[],
    workId: 1,
    workTitle: 'Work',
    sourceId: 'RJ000001',
    relativePath: relativePath,
  );
}

final class _CloseCountingAsmrApiService extends AsmrApiService {
  int closeCount = 0;

  @override
  void close({bool force = true}) {
    if (!isClosed) closeCount++;
    super.close(force: force);
  }
}

final class _ControlledAccountInitialization extends AsmrAccountSyncService {
  _ControlledAccountInitialization(
    AsmrApiService api,
    AsmrPreferencesStore preferences,
  ) : super(
        apiService: api,
        authService: AsmrAuthService(apiService: api),
        preferencesStore: preferences,
      );

  final started = Completer<void>();
  var pending = Completer<AsmrAccountSnapshot>();
  int initializeCalls = 0;
  int restoreCalls = 0;

  @override
  Future<AsmrAccountSnapshot> initialize() {
    initializeCalls++;
    if (!started.isCompleted) started.complete();
    return pending.future;
  }

  @override
  Future<AsmrAccountSnapshot> restoreSession() async {
    restoreCalls++;
    return AsmrAccountSnapshot();
  }
}
