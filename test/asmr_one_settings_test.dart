import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/asmr_models.dart';
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
    'ASMR controller logs in and requests recommendations with uuid',
    () async {
      await resetPrefs();
      final api = _FakeAsmrApiService();
      final controller = AsmrLibraryController(apiService: api);
      await controller.initialize(defaultLanguage: AsmrContentLanguage.en);

      await controller.login(name: 'alice', password: 'secret');
      await controller.refreshCategory(AsmrCategoryType.recommendation);

      expect(controller.authSession.token, 'token-alice');
      expect(controller.authSession.favoritePlaylistId, 42);
      expect(api.recommendationUuid, isNotEmpty);
      expect(api.recommendationToken, 'token-alice');
      expect(
        controller.worksFor(AsmrCategoryType.recommendation).single.title,
        'Recommended',
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
  _FakeAsmrApiService({this.failFavoritePlaylist = false})
    : super(baseUri: Uri.parse('https://example.test'));

  String? recommendationUuid;
  String? recommendationToken;
  final bool failFavoritePlaylist;

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
  Future<AsmrWorkPage> fetchRecommendedWorks({
    required String recommenderUuid,
    String keyword = '',
    int page = 1,
    int pageSize = 40,
    String? token,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
  }) async {
    recommendationUuid = recommenderUuid;
    recommendationToken = token;
    return AsmrWorkPage.fromJson(const <String, dynamic>{
      'works': <Map<String, Object?>>[
        <String, Object?>{'id': 9, 'title': 'Recommended'},
      ],
      'pagination': <String, Object?>{
        'currentPage': 1,
        'pageSize': 40,
        'totalCount': 1,
      },
    }, language: language);
  }
}
