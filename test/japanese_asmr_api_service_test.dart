import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_category_catalog.dart';
import 'package:doujin_audio/features/asmr/application/asmr_remote_catalog_service.dart';
import 'package:doujin_audio/features/asmr/application/japanese_asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_metadata_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_work_content_mapping.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_asmr_repository.dart';

void main() {
  test(
    'Japanese search uses its own identity and maps indexed work metadata',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(request.uri.path, '/api/jp-asmr/search');
        expect(request.uri.queryParameters['q'], 'sleep');
        expect(request.uri.queryParameters['offset'], '40');
        expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
        expect(
          request.headers.value('X-Listen-Together-Device-Fingerprint'),
          isNull,
        );
        expect(
          request.headers.value(HttpHeaders.userAgentHeader),
          startsWith('DoujinAudio/'),
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'items': [
              {
                'workId': 42,
                'rj': 'UN42',
                'title': 'Sleep',
                'circle': 'Circle',
                'cvs': ['Voice'],
                'tags': ['sleep'],
                'pageUrl': 'https://japaneseasmr.com/42/',
                'mainCoverUrl': 'https://pic.weeabo0.xyz/UN42_img_main.jpg',
                'publishedAt': '2026-10-20T08:00:00+08:00',
              },
            ],
            'total': 41,
          }),
        );
        await request.response.close();
      });
      final api = JapaneseAsmrApiService(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}/'),
      );
      addTearDown(api.close);
      final result = await api.searchWorks(keyword: 'sleep', page: 2);
      final work = result.works.single;
      expect(work.workKey, 'code:UN42');
      expect(work.rjCode, isEmpty);
      expect(work.voiceActors, ['Voice']);
      expect(work.createDate, isNotNull);
      expect(
        work.preferredCoverUrl,
        'https://pic.weeabo0.xyz/UN42_img_main.jpg',
      );
      expect(work.preferredResource.source, AsmrCatalogSource.japaneseAsmr);
      expect(result.hasMore, isFalse);
    },
  );

  test(
    'Japanese tree preserves chapter identities and assigns the stable work key',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'trackTree': [
              {
                'type': 'folder',
                'title': 'japaneseasmr.com',
                'children': [
                  for (var i = 0; i < 2; i++)
                    {
                      'type': 'audio',
                      'title': 'track$i.m4a',
                      'duration': 10,
                      'streamUrl':
                          'https://v.weeab0o.xyz/a.m3u8#eara-chapter=${i * 10000},${(i + 1) * 10000}&file=track$i.m4a',
                    },
                ],
              },
            ],
          }),
        );
        await request.response.close();
      });
      final api = JapaneseAsmrApiService(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}/'),
      );
      addTearDown(api.close);
      final work = _work(42, japanese: true);
      final tracks = (await api.fetchTrackTree(work)).single.children;
      expect(tracks.map((node) => node.streamUrl).toSet(), hasLength(2));
      expect(tracks.every((node) => node.workKey == work.workKey), isTrue);
      expect(tracks.every((node) => node.isAudio), isTrue);
    },
  );

  test('a cancelled request aborts while a response body is pending', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final opened = Completer<void>();
    server.listen((request) async {
      request.response.write('{');
      await request.response.flush();
      opened.complete();
    });
    final api = JapaneseAsmrApiService(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}/'),
    );
    addTearDown(api.close);
    final token = AsmrRequestCancellationToken();
    final pending = api.searchWorks(keyword: '', cancellationToken: token);
    final assertion = expectLater(
      pending,
      throwsA(isA<AsmrRequestCancelled>()),
    );
    await opened.future;
    token.cancel();
    await assertion;
  });

  test(
    'merged pagination retains each source buffer and keeps remote IDs isolated',
    () async {
      final one = _OneApi({
        1: [for (var i = 1; i <= 40; i++) _work(i)],
      });
      final jp = _JapaneseApi({
        1: [
          for (var i = 1; i <= 40; i++) _work(i, japanese: true, code: 'UN$i'),
        ],
      });
      final catalog = _catalog(one, jp);
      final cursor = AsmrCatalogCursor();
      final first = await _page(catalog, 1, cursor);
      final second = await _page(catalog, 2, cursor);
      expect(first.works, hasLength(40));
      expect(second.works, hasLength(40));
      expect(first.totalCount, 80);
      expect(second.totalCount, 80);
      expect(first.works.first.id, second.works.first.id);
      expect(first.works.first.workKey, isNot(second.works.first.workKey));
      expect(jp.calls, [1]);
      expect(second.hasMore, isFalse);
    },
  );

  test(
    'same-code works are merged once and resources survive duplicate pages',
    () async {
      final one = _OneApi({
        1: [_work(7)],
      });
      final jp = _JapaneseApi({
        1: [_work(999, japanese: true, code: 'RJ000007')],
      });
      final page = await _page(_catalog(one, jp), 1, AsmrCatalogCursor());
      expect(page.works, hasLength(1));
      expect(page.totalCount, 2);
      expect(page.works.single.resources, hasLength(2));
      expect(
        page.works.single.preferredResource.source,
        AsmrCatalogSource.asmrOne,
      );
    },
  );

  test(
    'a failed source preserves successful results and its retry position',
    () async {
      final one = _OneApi({
        1: [_work(1)],
      });
      final jp = _JapaneseApi({
        1: [_work(2, japanese: true)],
      })..failure = true;
      final catalog = _catalog(one, jp);
      final cursor = AsmrCatalogCursor();
      final first = await _page(catalog, 1, cursor) as AsmrMergedWorkPage;
      expect(first.works, hasLength(1));
      expect(first.partialError?.sources, [AsmrCatalogSource.japaneseAsmr]);
      expect(first.hasMore, isTrue);
      expect(first.sourceTotalCount, isNull);
      jp.failure = false;
      final second = await _page(catalog, 2, cursor);
      expect(second.works.single.workCode, 'RJ000002');
      expect((second as AsmrMergedWorkPage).sourceTotalCount, 2);
      expect(jp.calls, [1, 1]);
    },
  );

  test(
    'category publishes source totals without extending deduplicated paging',
    () async {
      final service = _catalog(
        _OneApi({
          1: [for (var i = 1; i <= 40; i++) _work(i)],
        }),
        _JapaneseApi({
          1: [for (var i = 1; i <= 40; i++) _work(i, japanese: true)],
        }),
      );
      const context = (
        authEpoch: 0,
        token: null,
        contentEpoch: 0,
        language: AsmrContentLanguage.zh,
        scope: 'combined-totals',
      );
      final catalog = AsmrCategoryCatalog(
        remoteCatalogService: service,
        onChanged: () {},
        isContextCurrent: (_) => true,
        currentContext: () => context,
        localWorks: (_) => const [],
        favoriteIds: () => const {},
      );
      for (final category in [
        AsmrCategoryType.collected,
        AsmrCategoryType.release,
        AsmrCategoryType.recommendation,
      ]) {
        await catalog.refresh(category, searchQuery: '', context: context);
        final state = catalog.viewState(category);
        expect(state.totalCount, 80, reason: category.name);
        expect(state.hasCombinedTotalCount, isTrue);
        expect(state.works, hasLength(40));
        expect(state.hasMore, isFalse);
        expect(catalog.totalCount(category), 80);
      }
    },
  );

  test(
    'metric rankings do not request unsupported Japanese rankings',
    () async {
      final one = _OneApi({
        1: [_work(1)],
      });
      final jp = _JapaneseApi({});
      final result = await _catalog(one, jp).loadPage(
        AsmrCategoryType.rating,
        searchQuery: '',
        page: 1,
        language: AsmrContentLanguage.zh,
        token: null,
      );
      expect(result.works, hasLength(1));
      expect(jp.calls, isEmpty);
    },
  );

  test(
    'duplicate-only source pages advance without dropping later works',
    () async {
      final one = _OneApi({
        1: [for (var i = 1; i <= 40; i++) _work(i)],
      });
      final jp = _JapaneseApi({
        1: [for (var i = 1; i <= 40; i++) _work(i, japanese: true)],
        2: [for (var i = 1; i <= 40; i++) _work(i, japanese: true)],
        3: [_work(99, japanese: true)],
      });
      final service = _catalog(one, jp);
      final cursor = AsmrCatalogCursor();
      await _page(service, 1, cursor);
      final second = await _page(service, 2, cursor) as AsmrMergedWorkPage;
      expect(second.works.single.workCode, 'RJ000099');
      expect(second.resourceUpdates, hasLength(40));
      expect(second.hasMore, isFalse);
      expect(jp.calls, [1, 2, 3]);
    },
  );

  test(
    'release pagination refills uneven source buffers before choosing the next page',
    () async {
      AsmrWork dated(int id, int day, {bool japanese = false}) =>
          AsmrWork.fromJson({
            ..._work(
              id,
              japanese: japanese,
              code: japanese ? 'UN$id' : null,
            ).toJson(),
            'releaseDate': DateTime(
              2020,
            ).add(Duration(days: day)).toIso8601String(),
          });
      final oneWorks = [for (var i = 0; i < 80; i++) dated(i + 1, 100 - i)];
      final jpWorks = [
        dated(999, 110, japanese: true),
        for (var i = 0; i < 39; i++) dated(i + 101, 60 - i, japanese: true),
      ];
      final service = _catalog(
        _OneApi({1: oneWorks.take(40).toList(), 2: oneWorks.skip(40).toList()}),
        _JapaneseApi({1: jpWorks}),
      );
      final cursor = AsmrCatalogCursor();
      Future<AsmrWorkPage> page(int number) => service.loadPage(
        AsmrCategoryType.release,
        searchQuery: '',
        page: number,
        language: AsmrContentLanguage.zh,
        token: null,
        cursor: cursor,
      );
      final first = await page(1);
      final second = await page(2);
      final expected = [...oneWorks, ...jpWorks]
        ..sort((a, b) {
          final date = b.releaseDate!.compareTo(a.releaseDate!);
          return date != 0 ? date : a.workKey.compareTo(b.workKey);
        });
      expect(
        [...first.works, ...second.works].map((work) => work.workKey),
        expected.take(80).map((work) => work.workKey),
      );
    },
  );

  test('cancelled aggregation does not consume either source cursor', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final jp =
        _JapaneseApi({
            1: [_work(2, japanese: true)],
          })
          ..beforeResponse = () async {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          };
    final catalog = _catalog(
      _OneApi({
        1: [_work(1)],
      }),
      jp,
    );
    final cursor = AsmrCatalogCursor();
    final token = AsmrRequestCancellationToken();
    final pending = catalog.loadPage(
      AsmrCategoryType.collected,
      searchQuery: '',
      page: 1,
      language: AsmrContentLanguage.zh,
      token: null,
      cursor: cursor,
      cancellationToken: token,
    );
    final assertion = expectLater(
      pending,
      throwsA(isA<AsmrRequestCancelled>()),
    );
    await entered.future;
    token.cancel();
    release.complete();
    await assertion;
    jp.beforeResponse = null;
    final retried = await _page(catalog, 1, cursor);
    expect(retried.works.map((work) => work.workCode), [
      'RJ000001',
      'RJ000002',
    ]);
    expect(jp.calls, [1, 1]);
  });

  test(
    'recommendations retain merged pending pages without invented total counts',
    () async {
      final one = _OneApi({
        1: [for (var i = 1; i <= 40; i++) _work(i)],
      });
      final jp = _JapaneseApi({
        1: [for (var i = 41; i <= 80; i++) _work(i, japanese: true)],
      });
      final ranked = await _catalog(one, jp).loadRecommendations(
        searchQuery: '',
        language: AsmrContentLanguage.zh,
        token: null,
        favoriteWorks: [],
        historyWorks: [],
        refreshSeed: 3,
      );
      expect(ranked.map((work) => work.workKey).toSet(), hasLength(80));
      expect(jp.calls, [1, 1]);
    },
  );

  test(
    'daily creator recommendations sample old pages within each source total',
    () async {
      AsmrWork creatorWork(int id, bool japanese, bool recent) =>
          AsmrWork.fromJson({
            ..._work(id, japanese: japanese).toJson(),
            'circleName': 'Favorite circle',
            'releaseDate': recent ? '2026-10-25' : '2020-01-01',
          });
      final one = _OneApi({
        1: [for (var i = 1; i <= 40; i++) creatorWork(i, false, true)],
        2: [for (var i = 41; i <= 80; i++) creatorWork(i, false, false)],
      });
      final jp = _JapaneseApi({
        1: [for (var i = 101; i <= 140; i++) creatorWork(i, true, true)],
        2: [for (var i = 141; i <= 180; i++) creatorWork(i, true, false)],
      });
      final service = _catalog(one, jp)
        ..circleWeights = () => {'favorite circle': 1};
      final picks = await service.loadDailyRecommendations(
        language: AsmrContentLanguage.zh,
        daySeed: 20261025,
        previousWorkKeys: {},
      );
      expect(jp.calls, [1, 2]);
      expect(picks, hasLength(80));
      expect(picks.take(40).every((w) => w.releaseDate!.year == 2026), isTrue);
      expect(picks.skip(40).every((w) => w.releaseDate!.year == 2020), isTrue);
    },
  );

  test(
    'unavailable ONE media switches the entire directory before queue creation',
    () async {
      final one = _OneApi({})..mediaError = const HttpException('Unavailable');
      final jp = _JapaneseApi({});
      final service = _catalog(one, jp);
      final work = _work(
        1,
      ).mergedWith(_work(10, japanese: true, code: 'RJ000001'));
      final tree = await service.loadTrackTree(work, token: 'one-token');
      expect(tree.single.streamUrl, contains('eara-chapter='));
      expect(one.mediaProbes, 1);
      expect(jp.treeCalls, 1);
    },
  );

  test(
    'reachable ONE media retains its directory and does not load Japanese tracks',
    () async {
      final one = _OneApi({});
      final jp = _JapaneseApi({});
      final tree = await _catalog(one, jp).loadTrackTree(_work(1), token: null);
      expect(tree.single.streamUrl, 'https://media.example/one.m4a');
      expect(one.mediaProbes, 1);
      expect(jp.treeCalls, 0);
    },
  );

  test(
    'HLS playback candidates exclude original chapter downloads and keep stable work groups',
    () {
      final work = _work(1);
      final node = AsmrTrackFile.fromJson(const {
        'type': 'audio',
        'title': 'chapter.m4a',
        'mediaStreamUrl':
            'https://v.weeab0o.xyz/a.m3u8#eara-chapter=10000,20000',
        'mediaDownloadUrl': 'https://ts.buzzheavier.com/d/original',
        'work': {'id': 1, 'source_id': 'RJ000001'},
      });
      final track = flattenAsmrPlayableTracks(work, [node]).single;
      expect(track.remoteMetadataKind, 'jp-asmr');
      expect(track.groupKey, 'asmr-work-code:RJ000001');
      expect(track.remoteMetadata!['playbackUrls'], [node.streamUrl]);
      expect(
        track.remoteMetadata!['mediaReference'],
        containsPair('startMs', 10000),
      );
    },
  );

  test('metadata services keep ONE and Japanese sources separate', () async {
    final oneWork = _work(1);
    final jpWork = _work(999, japanese: true, code: 'RJ000001');
    final one = _OneApi({
      1: [oneWork],
    });
    final jp = _JapaneseApi({
      1: [jpWork, _work(2, japanese: true)],
    });
    addTearDown(one.close);
    addTearDown(jp.close);
    final service = AsmrMetadataService(apiService: one);
    final japanese = AsmrMetadataService.japanese(apiService: jp);
    final oneMatch = await service.findAsmrWorkByRjCode('RJ000001');
    expect(oneMatch!.title, oneWork.title);
    expect(oneMatch.resources.single.source, AsmrCatalogSource.asmrOne);
    expect(jp.calls, isEmpty);
    expect(await service.findAsmrWorkByRjCode('RJ000002'), isNull);
    final japaneseMatch = await japanese.findAsmrWorkByRjCode('RJ000001');
    expect(japaneseMatch!.id, jpWork.id);
    expect(
      japaneseMatch.resources.single.source,
      AsmrCatalogSource.japaneseAsmr,
    );
    final onlyJapanese = await japanese.fetchByRjCode('RJ000002');
    expect(onlyJapanese.rjCode, 'RJ000002');
  });
}

AsmrRemoteCatalogService _catalog(_OneApi one, _JapaneseApi jp) {
  addTearDown(one.close);
  addTearDown(jp.close);
  return AsmrRemoteCatalogService(
    apiService: one,
    japaneseApiService: jp,
    persistenceRepository: _EmptyRepository(),
  );
}

Future<AsmrWorkPage> _page(
  AsmrRemoteCatalogService service,
  int page,
  AsmrCatalogCursor cursor,
) => service.loadPage(
  AsmrCategoryType.collected,
  searchQuery: '',
  page: page,
  language: AsmrContentLanguage.zh,
  token: null,
  cursor: cursor,
);

AsmrWork _work(int id, {bool japanese = false, String? code}) {
  final workCode = code ?? 'RJ${id.toString().padLeft(6, '0')}';
  return AsmrWork.fromJson({
    'id': id,
    'title': 'Work $id',
    'sourceId': workCode,
    'createDate': japanese ? '2025-01-01' : '2026-01-01',
    'resources': [
      AsmrWorkResource(
        source: japanese
            ? AsmrCatalogSource.japaneseAsmr
            : AsmrCatalogSource.asmrOne,
        id: id,
        code: workCode,
        pageUrl: '',
      ).toJson(),
    ],
  });
}

class _OneApi extends AsmrApiService {
  _OneApi(this.pages);
  final Map<int, List<AsmrWork>> pages;
  Object? mediaError;
  int mediaProbes = 0;
  @override
  Future<void> verifyMediaStream(
    String url, {
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    mediaProbes++;
    if (mediaError != null) throw mediaError!;
  }

  @override
  Future<List<AsmrTrackFile>> fetchTrackTree(
    int workId, {
    String? token,
    AsmrRequestCancellationToken? cancellationToken,
  }) async => [
    AsmrTrackFile.fromJson(const {
      'type': 'audio',
      'title': 'one.m4a',
      'mediaStreamUrl': 'https://media.example/one.m4a',
    }),
  ];
  @override
  Future<AsmrWorkPage> searchWorks({
    required String keyword,
    required String order,
    required String sort,
    int page = 1,
    int pageSize = 40,
    String? token,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
    AsmrRequestCancellationToken? cancellationToken,
  }) => fetchWorks(
    page: page,
    pageSize: pageSize,
    token: token,
    language: language,
    cancellationToken: cancellationToken,
  );
  @override
  Future<AsmrWorkPage> fetchWorks({
    String order = 'release',
    String sort = 'desc',
    int page = 1,
    int pageSize = 40,
    String? token,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
    AsmrRequestCancellationToken? cancellationToken,
  }) async => AsmrWorkPage(
    works: pages[page] ?? const [],
    currentPage: page,
    pageSize: pageSize,
    totalCount: pages.values.fold(0, (sum, works) => sum + works.length),
  );
}

class _JapaneseApi extends JapaneseAsmrApiService {
  _JapaneseApi(this.pages);
  final Map<int, List<AsmrWork>> pages;
  final List<int> calls = [];
  bool failure = false;
  Future<void> Function()? beforeResponse;
  int treeCalls = 0;
  @override
  Future<List<AsmrTrackFile>> fetchTrackTree(
    AsmrWork work, {
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    treeCalls++;
    return [
      AsmrTrackFile.fromJson(const {
        'type': 'audio',
        'title': 'japanese.m4a',
        'mediaStreamUrl': 'https://v.weeab0o.xyz/a.m3u8#eara-chapter=0,1000',
      }),
    ];
  }

  @override
  Future<AsmrWorkPage> searchWorks({
    required String keyword,
    int page = 1,
    int pageSize = 40,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    calls.add(page);
    await beforeResponse?.call();
    if (failure) throw const FormatException('Unavailable');
    return AsmrWorkPage(
      works: pages[page] ?? const [],
      currentPage: page,
      pageSize: pageSize,
      totalCount: pages.values.fold(0, (sum, works) => sum + works.length),
    );
  }
}

class _EmptyRepository extends SqliteAsmrRepository {
  _EmptyRepository() : super(database: AppDatabase.instance);
  @override
  Future<List<MusicTrack>> loadTracksForRecommendations() async => [];
}
