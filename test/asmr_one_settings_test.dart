import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/asmr_models.dart';
import 'package:nameless_audio/models/music_track.dart';
import 'package:nameless_audio/services/audio_database_repository.dart';
import 'package:nameless_audio/services/app_preferences.dart';
import 'package:nameless_audio/services/asmr_api_service.dart';
import 'package:nameless_audio/services/asmr_auth_service.dart';
import 'package:nameless_audio/services/asmr_library_controller.dart';
import 'package:nameless_audio/services/asmr_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> resetPrefs([Map<String, Object> values = const {}]) async {
    SharedPreferences.setMockInitialValues(values);
    await AppPreferences.init();
  }

  test(
    'ASMR visible categories default to requested five categories',
    () async {
      await resetPrefs();

      expect(
        await AsmrPreferences.loadVisibleCategories(),
        kDefaultVisibleAsmrCategories,
      );
    },
  );

  test('ASMR visible categories are sanitized and capped at five', () async {
    await resetPrefs(<String, Object>{
      'asmr_visible_categories_v1': <String>[
        'sales',
        'rating',
        'release',
        'favorites',
        'history',
        'collected',
      ],
    });

    if (Platform.isWindows) {
      expect(await AsmrPreferences.loadVisibleCategories(), <AsmrCategoryType>[
        AsmrCategoryType.sales,
        AsmrCategoryType.rating,
        AsmrCategoryType.release,
        AsmrCategoryType.favorites,
        AsmrCategoryType.history,
        AsmrCategoryType.collected,
      ]);
    } else {
      expect(await AsmrPreferences.loadVisibleCategories(), <AsmrCategoryType>[
        AsmrCategoryType.sales,
        AsmrCategoryType.rating,
        AsmrCategoryType.release,
        AsmrCategoryType.favorites,
        AsmrCategoryType.history,
      ]);
    }
  });

  test(
    'ASMR content language defaults from app language and persists',
    () async {
      await resetPrefs();

      expect(
        await AsmrPreferences.loadContentLanguage(AsmrContentLanguage.en),
        AsmrContentLanguage.en,
      );

      await AsmrPreferences.saveContentLanguage(AsmrContentLanguage.ja);

      expect(
        await AsmrPreferences.loadContentLanguage(AsmrContentLanguage.en),
        AsmrContentLanguage.ja,
      );
    },
  );

  test('ASMR work parser uses selected locale for localizable tag names', () {
    final work = AsmrWork.fromJson(const <String, dynamic>{
      'id': 1,
      'title': 'Original',
      'tags': <Map<String, Object>>[
        <String, Object>{
          'name': '默认',
          'i18n': <String, Object>{
            'en-us': <String, Object>{'name': 'English tag'},
            'ja-jp': <String, Object>{'name': '日本語タグ'},
          },
        },
      ],
    }, language: AsmrContentLanguage.en);

    expect(work.tags, <String>['English tag']);
  });

  test('ASMR single-track playback keeps the complete work tree', () async {
    await resetPrefs();
    final first = _trackFile('first.mp3', 'root/part-a/first.mp3');
    final target = _trackFile('target.mp3', 'root/part-b/target.mp3');
    final last = _trackFile('last.mp3', 'root/part-c/last.mp3');
    final api = _FakeAsmrApiService(
      trackTree: <AsmrTrackFile>[
        _trackFolder(
          'root',
          'root',
          children: <AsmrTrackFile>[
            _trackFolder(
              'part-a',
              'root/part-a',
              children: <AsmrTrackFile>[first],
            ),
            _trackFolder(
              'part-b',
              'root/part-b',
              children: <AsmrTrackFile>[target],
            ),
            _trackFolder(
              'part-c',
              'root/part-c',
              children: <AsmrTrackFile>[last],
            ),
          ],
        ),
      ],
    );
    final controller = AsmrLibraryController(apiService: api);

    final tracks = await controller.loadPlayableTracksStartingAt(
      _work(id: 1, title: 'Work'),
      target,
    );

    expect(tracks, hasLength(3));
    expect(tracks.map((track) => track.displayName), <String>[
      'target',
      'last',
      'first',
    ]);
    expect(
      tracks.map((track) => track.remoteMetadata?['trackRelativePath']),
      <String>[
        'root/part-b/target.mp3',
        'root/part-c/last.mp3',
        'root/part-a/first.mp3',
      ],
    );
  });

  test(
    'ASMR controller ranks recommendations from ordinary work lists',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService();
      final controller = AsmrLibraryController(
        apiService: api,
        audioDatabaseRepository: _FakeAudioDatabaseRepository(<MusicTrack>[
          _track(groupTitle: 'Dream Circle', tags: <String>['sleep']),
        ]),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      await controller.refreshCategory(AsmrCategoryType.recommendation);
      expect(api.fetchWorkOrders, contains('create_date:desc'));
      expect(api.fetchWorkOrders, contains('dl_count:desc'));
      expect(api.fetchWorkOrders, contains('rate_average_2dp:desc'));
      expect(api.fetchWorkOrders, contains('release:desc'));
      expect(
        controller.hasMoreCategory(AsmrCategoryType.recommendation),
        isFalse,
      );
      expect(
        controller.worksFor(AsmrCategoryType.recommendation).first.title,
        'Sleep Match',
      );
    },
  );

  test('ASMR recommendation tolerates one failed candidate source', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService(
      failingFetchOrders: const <String>{'release'},
    );
    final controller = AsmrLibraryController(
      apiService: api,
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

    await controller.refreshCategory(AsmrCategoryType.recommendation);

    expect(controller.lastError, isNull);
    expect(
      controller
          .worksFor(AsmrCategoryType.recommendation)
          .map((work) => work.id),
      containsAll(<int>[9, 10, 11]),
    );
    expect(
      controller
          .worksFor(AsmrCategoryType.recommendation)
          .map((work) => work.id),
      isNot(contains(12)),
    );
  });

  test('ASMR review count category uses review count ordering', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService();
    final controller = AsmrLibraryController(
      apiService: api,
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

    await controller.refreshCategory(AsmrCategoryType.reviews);

    expect(api.fetchWorkOrders, contains('review_count:desc'));
    expect(
      controller.worksFor(AsmrCategoryType.reviews).map((work) => work.id),
      <int>[13],
    );
  });

  test('ASMR recommendation search uses ordinary search candidates', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService();
    final controller = AsmrLibraryController(
      apiService: api,
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

    await controller.refreshCategory(
      AsmrCategoryType.recommendation,
      searchQuery: 'sleep',
    );

    expect(api.searchKeywords, everyElement('sleep'));
    expect(controller.activeQueryFor(AsmrCategoryType.recommendation), 'sleep');
    expect(
      controller
          .worksFor(AsmrCategoryType.recommendation)
          .map((work) => work.id),
      contains(21),
    );
  });

  test('ASMR recommendation refresh changes full result order', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService(largeRecommendationPool: true);
    final controller = AsmrLibraryController(
      apiService: api,
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

    await controller.refreshCategory(AsmrCategoryType.recommendation);
    final firstIds = controller
        .worksFor(AsmrCategoryType.recommendation)
        .map((work) => work.id)
        .toList(growable: false);
    expect(firstIds, hasLength(320));

    await controller.refreshCategory(AsmrCategoryType.recommendation);
    final secondIds = controller
        .worksFor(AsmrCategoryType.recommendation)
        .map((work) => work.id)
        .toList(growable: false);

    expect(secondIds, hasLength(firstIds.length));
    expect(firstIds.toSet(), secondIds.toSet());
    expect(firstIds, isNot(secondIds));
  });

  test('ASMR recommendation loads extra candidate pages', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService(largeRecommendationPool: true);
    final controller = AsmrLibraryController(
      apiService: api,
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

    await controller.refreshCategory(AsmrCategoryType.recommendation);

    expect(api.fetchWorkRequests, contains('create_date:desc:2'));
    expect(api.fetchWorkRequests, contains('dl_count:desc:2'));
    expect(api.fetchWorkRequests, contains('rate_average_2dp:desc:2'));
    expect(api.fetchWorkRequests, contains('release:desc:2'));
  });

  test(
    'ASMR recommendation stops candidate paging after refresh window',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService(
        largeRecommendationPool: true,
        recommendationPageCount: 20,
      );
      final controller = AsmrLibraryController(
        apiService: api,
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      await controller.refreshCategory(AsmrCategoryType.recommendation);

      expect(api.fetchWorkRequests, contains('create_date:desc:2'));
      expect(api.fetchWorkRequests, isNot(contains('create_date:desc:3')));
      expect(api.fetchWorkRequests, isNot(contains('dl_count:desc:3')));
      expect(api.fetchWorkRequests, isNot(contains('rate_average_2dp:desc:3')));
      expect(api.fetchWorkRequests, isNot(contains('release:desc:3')));
    },
  );

  test(
    'ASMR recommendation hides favorite history and local-owned works',
    () async {
      await resetPrefs();
      final favorite = _work(
        id: 31,
        title: 'Favorite Sleep',
        tags: <String>['sleep'],
      );
      final history = _work(
        id: 32,
        title: 'History Sleep',
        tags: <String>['sleep'],
      );
      await AsmrPreferences.saveFavoriteWorks(<AsmrWork>[favorite]);
      await AsmrPreferences.saveHistoryWorks(<AsmrWork>[history]);
      final api = _FakeAsmrApiService(
        recommendationWorks: <AsmrWork>[
          favorite,
          history,
          _work(id: 33, title: 'Local Sleep', tags: <String>['sleep']),
          _work(id: 34, title: 'Visible Sleep', tags: <String>['sleep']),
        ],
      );
      final controller = AsmrLibraryController(
        apiService: api,
        audioDatabaseRepository: _FakeAudioDatabaseRepository(<MusicTrack>[
          _track(
            groupTitle: 'Local Circle',
            groupSubtitle: 'RJ000033',
            tags: <String>['sleep'],
          ),
        ]),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      await controller.refreshCategory(AsmrCategoryType.recommendation);

      expect(
        controller
            .worksFor(AsmrCategoryType.recommendation)
            .map((work) => work.id),
        <int>[34],
      );
    },
  );

  test(
    'ASMR category view state caches local filtered works until revision changes',
    () async {
      final favorite = _work(
        id: 41,
        title: 'Sleep Favorite',
        tags: <String>['sleep'],
      );
      await resetPrefs();
      await AsmrPreferences.saveFavoriteWorks(<AsmrWork>[favorite]);
      final controller = AsmrLibraryController(
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      final first = controller.categoryViewState(
        AsmrCategoryType.favorites,
        searchQuery: 'sleep',
      );
      final second = controller.categoryViewState(
        AsmrCategoryType.favorites,
        searchQuery: 'sleep',
      );

      expect(first, second);
      expect(identical(first.works, second.works), isTrue);
      expect(first.works.map((work) => work.id), <int>[41]);

      await controller.toggleFavorite(
        _work(id: 42, title: 'Sleep New', tags: <String>['sleep']),
      );
      final third = controller.categoryViewState(
        AsmrCategoryType.favorites,
        searchQuery: 'sleep',
      );

      expect(third.revision, greaterThan(first.revision));
      expect(identical(first.works, third.works), isFalse);
      expect(third.works.map((work) => work.id), <int>[42, 41]);
    },
  );

  test('ASMR track tree view state caches visible browsable nodes', () async {
    await resetPrefs();
    final work = _work(id: 51, title: 'Tree Work');
    final api = _FakeAsmrApiService(
      trackTree: <AsmrTrackFile>[
        _trackFolder(
          'Disc',
          'Disc',
          children: <AsmrTrackFile>[_trackFile('Track.mp3', 'Disc/Track.mp3')],
        ),
        _trackFile('notes.txt', 'notes.txt', type: 'text'),
      ],
    );
    final controller = AsmrLibraryController(
      apiService: api,
      audioDatabaseRepository: _FakeAudioDatabaseRepository(
        const <MusicTrack>[],
      ),
    );
    await controller.initialize(defaultLanguage: AsmrContentLanguage.en);
    await controller.ensureTrackTree(work);

    final first = controller.trackTreeViewState(work.id);
    final second = controller.trackTreeViewState(work.id);

    expect(first, second);
    expect(identical(first.visibleTree, second.visibleTree), isTrue);
    expect(first.visibleTree?.map((node) => node.title), <String>['Disc']);
  });

  test('ASMR auth service stores restores and clears token', () async {
    await resetPrefs();
    final api = _FakeAsmrApiService();
    final tokenStore = _MemoryAsmrTokenStore();
    final auth = AsmrAuthService(apiService: api, tokenStore: tokenStore);

    final session = await auth.login('alice', 'password');

    expect(session.token, 'token-alice');
    expect(tokenStore.token, 'token-alice');
    expect((await auth.restoreSession())?.userName, 'alice');

    await auth.logout();

    expect(tokenStore.token, isNull);
    expect(await auth.restoreSession(), isNull);
  });

  test(
    'ASMR account sync maps favorites to marked review progress and retries',
    () async {
      await resetPrefs();
      final local = _work(id: 71, title: 'Local Favorite');
      final remote = _work(id: 72, title: 'Remote Favorite');
      await AsmrPreferences.saveFavoriteWorks(<AsmrWork>[local]);
      final api = _FakeAsmrApiService(
        remoteReviewRecords: <AsmrReviewRecord>[
          AsmrReviewRecord(
            work: remote,
            progress: 'marked',
            updatedAt: DateTime(2026, 5),
          ),
        ],
        failPutReviewCount: 1,
      );
      final controller = AsmrLibraryController(
        apiService: api,
        authService: AsmrAuthService(
          apiService: api,
          tokenStore: _MemoryAsmrTokenStore(),
        ),
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      await controller.loginAsmrAccount('alice', 'password');

      expect(controller.isAsmrAccountLoggedIn, isTrue);
      expect(controller.syncViewState.phase, AsmrSyncPhase.failed);
      expect(controller.syncViewState.pendingCount, 1);
      expect(
        controller.worksFor(AsmrCategoryType.favorites).map((work) => work.id),
        containsAll(<int>[71, 72]),
      );

      await controller.syncAsmrAccount(force: true);

      expect(controller.syncViewState.phase, AsmrSyncPhase.succeeded);
      expect(controller.syncViewState.pendingCount, 0);
      expect(api.reviewPuts, <String>['71:marked']);
    },
  );

  test(
    'ASMR account sync removes remote marked progress when unfavorited',
    () async {
      await resetPrefs();
      final work = _work(id: 82, title: 'Marked Favorite');
      await AsmrPreferences.saveFavoriteWorks(<AsmrWork>[work]);
      final api = _FakeAsmrApiService(
        remoteReviewRecords: <AsmrReviewRecord>[
          AsmrReviewRecord(
            work: work,
            progress: 'marked',
            updatedAt: DateTime(2026, 5),
          ),
        ],
      );
      final controller = AsmrLibraryController(
        apiService: api,
        authService: AsmrAuthService(
          apiService: api,
          tokenStore: _MemoryAsmrTokenStore(),
        ),
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      await controller.loginAsmrAccount('alice', 'password');
      await controller.toggleFavorite(work.copyWith(isFavorite: true));
      await controller.syncAsmrAccount();

      expect(controller.syncViewState.phase, AsmrSyncPhase.succeeded);
      expect(controller.syncViewState.pendingCount, 0);
      expect(api.deletedReviewWorkIds, <int>[82]);
    },
  );

  test(
    'ASMR account sync keeps marked favorites from history downgrade',
    () async {
      await resetPrefs();
      final work = _work(id: 83, title: 'Marked Favorite');
      final api = _FakeAsmrApiService(
        remoteReviewRecords: <AsmrReviewRecord>[
          AsmrReviewRecord(
            work: work,
            progress: 'marked',
            updatedAt: DateTime(2026, 5),
          ),
        ],
      );
      final controller = AsmrLibraryController(
        apiService: api,
        authService: AsmrAuthService(
          apiService: api,
          tokenStore: _MemoryAsmrTokenStore(),
        ),
        audioDatabaseRepository: _FakeAudioDatabaseRepository(
          const <MusicTrack>[],
        ),
      );
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      await controller.loginAsmrAccount('alice', 'password');
      await controller.recordHistory(work);
      await controller.syncAsmrAccount(force: true);

      expect(controller.syncViewState.phase, AsmrSyncPhase.succeeded);
      expect(controller.syncViewState.pendingCount, 0);
      expect(api.reviewPuts.where((call) => call == '83:listening'), isEmpty);
    },
  );
}

class _FakeAsmrApiService extends AsmrApiService {
  _FakeAsmrApiService({
    this.largeRecommendationPool = false,
    this.recommendationPageCount = 2,
    this.recommendationWorks,
    this.trackTree = const <AsmrTrackFile>[],
    this.remoteReviewRecords = const <AsmrReviewRecord>[],
    this.failPutReviewCount = 0,
    this.failingFetchOrders = const <String>{},
  }) : super(baseUri: Uri.parse('https://example.test'));

  final List<String> fetchWorkOrders = <String>[];
  final List<String> fetchWorkRequests = <String>[];
  final List<String> searchKeywords = <String>[];
  final List<String> reviewPuts = <String>[];
  final List<int> deletedReviewWorkIds = <int>[];
  final bool largeRecommendationPool;
  final int recommendationPageCount;
  final List<AsmrWork>? recommendationWorks;
  final List<AsmrTrackFile> trackTree;
  final List<AsmrReviewRecord> remoteReviewRecords;
  final Set<String> failingFetchOrders;
  int failPutReviewCount;
  String _lastLoginName = '';

  @override
  Future<AsmrAuthSession> login({
    required String name,
    required String password,
  }) async {
    _lastLoginName = name;
    return AsmrAuthSession(token: 'token-$name', userName: name);
  }

  @override
  Future<AsmrAuthSession?> checkSession(String token) async {
    if (token.isEmpty) {
      return null;
    }
    final name = _lastLoginName.isEmpty ? 'restored' : _lastLoginName;
    return AsmrAuthSession(token: token, userName: name);
  }

  @override
  Future<AsmrWorkPage> fetchWorks({
    required String order,
    required String sort,
    int page = 1,
    int pageSize = 40,
    String? token,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
  }) async {
    fetchWorkOrders.add('$order:$sort');
    fetchWorkRequests.add('$order:$sort:$page');
    if (failingFetchOrders.contains(order)) {
      throw HttpException('Simulated ASMR work fetch failure for $order');
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
      final pageOffset = (page - 1) * pageSize;
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
  }) async {
    searchKeywords.add(keyword);
    return AsmrWorkPage(
      works: <AsmrWork>[
        _work(id: 21, title: 'Search Sleep', tags: <String>['sleep']),
      ],
      currentPage: page,
      pageSize: pageSize,
      totalCount: 1,
    );
  }

  @override
  Future<List<AsmrTrackFile>> fetchTrackTree(
    int workId, {
    String? token,
  }) async => trackTree;

  @override
  Future<List<AsmrReviewRecord>> fetchReviews({
    required String token,
    String? filter,
    int page = 1,
    String order = 'updated_at',
    String sort = 'desc',
    AsmrContentLanguage language = AsmrContentLanguage.zh,
  }) async {
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
    deletedReviewWorkIds.add(workId);
  }
}

class _MemoryAsmrTokenStore implements AsmrTokenStore {
  String? token;

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
  Future<void> clearCredentials() async {}

  @override
  Future<Map<String, String>?> readCredentials() async => null;

  @override
  Future<void> writeCredentials(String username, String password) async {}
}

class _FakeAudioDatabaseRepository extends AudioDatabaseRepository {
  _FakeAudioDatabaseRepository(this.tracks);

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
}) {
  return AsmrTrackFile(
    hash: relativePath,
    title: title,
    type: type,
    streamUrl: 'https://example.test/$relativePath',
    downloadUrl: 'https://example.test/$relativePath',
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
