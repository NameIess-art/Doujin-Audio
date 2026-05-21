import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/asmr_models.dart';
import 'package:nameless_audio/models/music_track.dart';
import 'package:nameless_audio/services/audio_database_repository.dart';
import 'package:nameless_audio/services/app_preferences.dart';
import 'package:nameless_audio/services/asmr_api_service.dart';
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

    expect(await AsmrPreferences.loadVisibleCategories(), <AsmrCategoryType>[
      AsmrCategoryType.sales,
      AsmrCategoryType.rating,
      AsmrCategoryType.release,
      AsmrCategoryType.favorites,
      AsmrCategoryType.history,
    ]);
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

      await controller.login(name: 'alice', password: 'secret');
      await controller.refreshCategory(AsmrCategoryType.recommendation);

      expect(controller.authSession.token, 'token-alice');
      expect(controller.authSession.favoritePlaylistId, 42);
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

  test('ASMR recommendation refresh changes limited content', () async {
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

    await controller.refreshCategory(AsmrCategoryType.recommendation);
    final secondIds = controller
        .worksFor(AsmrCategoryType.recommendation)
        .map((work) => work.id)
        .toList(growable: false);

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
    'ASMR controller keeps login when favorite playlist lookup fails',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService(failFavoritePlaylist: true);
      final controller = AsmrLibraryController(apiService: api);
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      await controller.login(name: 'alice', password: 'secret');

      expect(controller.authSession.isLoggedIn, isTrue);
      expect(controller.authSession.token, 'token-alice');
      expect(controller.authSession.favoritePlaylistId, isNull);
      expect(controller.lastError, isNull);
    },
  );
}

class _FakeAsmrApiService extends AsmrApiService {
  _FakeAsmrApiService({
    this.failFavoritePlaylist = false,
    this.largeRecommendationPool = false,
    this.recommendationWorks,
  }) : super(baseUri: Uri.parse('https://example.test'));

  final List<String> fetchWorkOrders = <String>[];
  final List<String> fetchWorkRequests = <String>[];
  final List<String> searchKeywords = <String>[];
  final bool failFavoritePlaylist;
  final bool largeRecommendationPool;
  final List<AsmrWork>? recommendationWorks;

  @override
  Future<AsmrAuthSession> login({
    required String name,
    required String password,
  }) async {
    return AsmrAuthSession(token: 'token-$name', userName: name, userId: 7);
  }

  @override
  Future<int?> fetchFavoritePlaylistId(String token) async {
    if (failFavoritePlaylist) {
      throw const HttpException('Favorite playlist unavailable.');
    }
    return 42;
  }

  @override
  Future<List<AsmrWork>> fetchFavoriteWorks({
    required String token,
    required int playlistId,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
  }) async {
    return const <AsmrWork>[];
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
        totalCount: pageSize * 2,
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
