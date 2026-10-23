import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/core/media/dlsite_metadata.dart';
import 'package:doujin_audio/features/library/application/dlsite_metadata_service.dart';

void main() {
  for (final scenario in [
    'complete',
    'partial',
    'JSON blocked',
    'page blocked',
  ]) {
    test('DLsite request preserves fields when $scenario', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final transport = HttpClient();
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.uri.path);
        if (request.uri.path.endsWith('product.json')) {
          if (scenario == 'JSON blocked') {
            request.response.statusCode = HttpStatus.forbidden;
          } else {
            request.response.write(
              jsonEncode({
                'workno': 'RJ01726046',
                'work_name': 'JSON title',
                'maker_name': 'JSON Circle',
                'genres': [
                  {'name': 'JSON tag'},
                ],
                'image_main': {'url': '//img.dlsite.jp/cover.jpg'},
                if (scenario == 'complete') ...{
                  'regist_date': '2026-10-03 00:00:00',
                  'creaters': {
                    'voice_by': [
                      {'name': 'JSON Voice'},
                    ],
                  },
                  'rate_average_star': 50,
                },
              }),
            );
          }
        } else if (scenario == 'page blocked') {
          request.response.statusCode = HttpStatus.forbidden;
        } else {
          request.response.write('''
            <h1 id="work_name">Page title</h1>
            <span class="maker_name"><a>Page Circle</a></span>
            <table>
              <tr><th>販売日</th><td>2026年10月03日</td></tr>
              <tr><th>声優</th><td><a>梅木ちはる</a> / <a>柚木つばめ</a></td></tr>
              <tr><th>ジャンル</th><td><a>Page tag</a></td></tr>
            </table>
            <meta itemprop="ratingValue" content="4.85">
            ''');
        }
        await request.response.close();
      });
      try {
        final metadata = await DlsiteMetadataService(
          httpClient: _LocalDlsiteHttpClient(transport, server.port),
        ).fetchByRjCode('RJ01726046', language: AppLanguage.zh);

        expect(metadata.rjCode, 'RJ01726046');
        expect(
          metadata.workTitle,
          scenario == 'JSON blocked' ? 'Page title' : 'JSON title',
        );
        expect(
          metadata.circleName,
          scenario == 'JSON blocked' ? 'Page Circle' : 'JSON Circle',
        );
        expect(metadata.tags, [
          scenario == 'JSON blocked' ? 'Page tag' : 'JSON tag',
        ]);
        if (scenario == 'page blocked') {
          expect(metadata.voiceActors, isEmpty);
          expect(metadata.releaseDate, isNull);
        } else {
          expect(
            metadata.voiceActors,
            scenario == 'complete' ? ['JSON Voice'] : ['梅木ちはる', '柚木つばめ'],
          );
          expect(metadata.releaseDate, DateTime(2026, 10, 3));
          expect(metadata.rating, scenario == 'complete' ? 5 : 4.85);
        }
        expect(
          requests.where((uri) => uri.endsWith('.html')).length,
          scenario == 'complete' ? 0 : 1,
        );
      } finally {
        transport.close(force: true);
        await server.close(force: true);
      }
    });
  }

  test('maps selected DLsite metadata language to locale headers', () {
    expect(dlsiteLocaleForLanguage(AppLanguage.zh), 'zh-cn');
    expect(dlsiteLocaleForLanguage(AppLanguage.ja), 'ja-jp');
    expect(dlsiteLocaleForLanguage(AppLanguage.en), 'en-us');
    expect(
      dlsiteAcceptLanguageForLanguage(AppLanguage.en),
      'en-US,en;q=0.9,ja-JP;q=0.8,zh-CN;q=0.7',
    );
  });

  test('stops DLsite lookup after bounded network timeouts', () async {
    final client = _HangingHttpClient();
    final service = DlsiteMetadataService(
      httpClient: client,
      requestTimeout: const Duration(milliseconds: 1),
    );

    await expectLater(
      service.fetchByRjCode('RJ01014447'),
      throwsA(
        isA<DlsiteMetadataException>()
            .having((error) => error.isNetworkFailure, 'network failure', true)
            .having(
              (error) => error.message,
              'message',
              'DLsite request timed out',
            ),
      ),
    );
    expect(client.getUrlCalls, 2);
  });

  test(
    'rejects oversized cover responses before writing a cache file',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final directory = await Directory.systemTemp.createTemp('dlsite_cover_');
      final subscription = server.listen((request) async {
        request.response.add(List<int>.filled(5 * 1024 * 1024 + 1, 1));
        await request.response.close();
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      final service = DlsiteMetadataService(
        requestTimeout: const Duration(seconds: 1),
      );

      await expectLater(
        service.downloadCover(
          coverUrl: 'http://${server.address.address}:${server.port}/cover.jpg',
          folderPath: directory.path,
          rjCode: 'RJ01014447',
        ),
        throwsA(
          isA<DlsiteMetadataException>().having(
            (error) => error.message,
            'message',
            'Cover response is too large',
          ),
        ),
      );
      expect(directory.listSync().whereType<File>(), isEmpty);
    },
  );

  test(
    'writes a cover with the requested name into a new cover folder',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final root = await Directory.systemTemp.createTemp('dlsite_cover_path_');
      final subscription = server.listen((request) async {
        request.response.add(const <int>[1, 2, 3]);
        await request.response.close();
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
        if (await root.exists()) await root.delete(recursive: true);
      });

      final coverFolder = Directory(
        '${root.path}${Platform.pathSeparator}cover',
      );
      final saved = await DlsiteMetadataService().downloadCover(
        coverUrl: 'http://${server.address.address}:${server.port}/cover.webp',
        folderPath: coverFolder.path,
        rjCode: 'RJ01014447',
        fileName: 'cover.jpg',
      );

      expect(
        saved.displayPath,
        '${coverFolder.path}${Platform.pathSeparator}cover.jpg',
      );
      expect(await File(saved.displayPath).readAsBytes(), const <int>[1, 2, 3]);
    },
  );

  test('parses DLsite product json into editable metadata', () {
    final metadata = DlsiteMetadata.fromProductJson({
      'workno': 'RJ01014447',
      'work_name': 'Work title',
      'maker_name': 'Circle',
      'regist_date': '2024-05-06',
      'duration': 3723,
      'dl_count': '1,234',
      'rate_average_star': 50,
      'image_main': {'url': '//img.dlsite.jp/path/cover.jpg'},
      'creaters': {
        'voice_by': [
          {'name': 'Voice A'},
          {'name': 'Voice A'},
          {'name': 'Voice B'},
        ],
      },
      'genres': [
        {'name': 'ASMR'},
        {'name': 'Ear cleaning'},
      ],
    });

    expect(metadata.rjCode, 'RJ01014447');
    expect(metadata.workTitle, 'Work title');
    expect(metadata.circleName, 'Circle');
    expect(metadata.voiceActors, const <String>['Voice A', 'Voice B']);
    expect(metadata.tags, const <String>['ASMR', 'Ear cleaning']);
    expect(metadata.coverUrl, 'https://img.dlsite.jp/path/cover.jpg');
    expect(metadata.releaseDate, DateTime(2024, 5, 6));
    expect(metadata.duration, const Duration(hours: 1, minutes: 2, seconds: 3));
    expect(metadata.salesCount, 1234);
    expect(metadata.rating, 5.0);
  });

  test('decodes DLsite product json wrapped as list or object', () {
    final fromList = decodeDlsiteProductJsonResponse('''
      [
        {"workno":"RJ01014447","work_name":"List title"}
      ]
    ''');
    final fromObject = decodeDlsiteProductJsonResponse('''
      {
        "products": {
          "RJ01014448": {
            "product_id": "RJ01014448",
            "product_name": "Object title"
          }
        }
      }
    ''');

    expect(fromList?['workno'], 'RJ01014447');
    expect(fromObject?['product_id'], 'RJ01014448');
  });

  test('decodes DLsite work page html as product metadata fallback', () {
    final metadata = decodeDlsiteProductHtml('''
      <meta property="og:title" content="Fallback title [Circle B] | DLsite">
      <meta property="og:image" content="//img.dlsite.jp/path/fallback.jpg">
      <h1 id="work_name">Fallback title</h1>
      <template data-product-name="Fallback title"
        data-maker-name="Circle A"></template>
      ''', fallbackRjCode: 'RJ01014449');

    expect(metadata?.rjCode, 'RJ01014449');
    expect(metadata?.workTitle, 'Fallback title');
    expect(metadata?.circleName, 'Circle A');
    expect(metadata?.coverUrl, 'https://img.dlsite.jp/path/fallback.jpg');
  });

  for (final labels in [
    ['販売日', '声優', 'ジャンル'],
    ['发售日', '声优', '分类'],
    ['Release date', 'Voice Actor', 'Genre'],
  ]) {
    test('RJ01726046 HTML retains metadata with ${labels[0]} labels', () {
      final metadata = decodeDlsiteProductHtml('''
        <h1 id="work_name">Work RJ01726046</h1>
        <span class="maker_name"><a>テグラユウキ</a></span>
        <meta itemprop="ratingValue" content="4.85">
        <table id="work_outline">
          <tr><th>${labels[0]}</th><td><a href="/maniax/new/=/year/2026/mon/10/day/03/">2026年10月03日</a></td></tr>
          <tr><th>${labels[1]}</th><td>
            <a href="/creator/23407">梅木ちはる</a> /
            <a href="/creator/17426">柚木つばめ</a>
          </td></tr>
          <tr><th>${labels[2]}</th><td><div class="main_genre">
            <a href="/genre/056">癒し</a>
            <a href="/genre/004">ラブラブ/あまあま</a>
          </div></td></tr>
        </table>
        ''', fallbackRjCode: 'RJ01726046');

      expect(metadata?.voiceActors, ['梅木ちはる', '柚木つばめ']);
      expect(metadata?.releaseDate, DateTime(2026, 10, 3));
      expect(metadata?.tags, ['癒し', 'ラブラブ/あまあま']);
      expect(metadata?.circleName, 'テグラユウキ');
      expect(metadata?.rating, 4.85);
    });
  }

  test('extracts unique RJ product ids from DLsite search html', () {
    final ids = extractDlsiteProductIdsFromSearchHtml('''
      <a href="/maniax/work/=/product_id/RJ01014447.html">A</a>
      <a href="/maniax/work/=/product_id/rj01014447.html">A duplicate</a>
      <a href="/maniax/work/=/product_id/RJ123456.html">B</a>
    ''');

    expect(ids, const <String>['RJ01014447', 'RJ123456']);
  });

  test('extracts RJ product ids from DLsite suggest json', () {
    final ids = extractDlsiteProductIdsFromSuggestResponse('''
      {
        "work": [
          {"workno": "RJ343103"},
          {"workno": "RJ01553075"}
        ],
        "maker": [
          {"workno": "RJ343103"}
        ],
        "reqtime": 1
      }
    ''');

    expect(ids, const <String>['RJ343103', 'RJ01553075']);
  });

  test('extracts RJ product ids from DLsite suggest jsonp', () {
    final ids = extractDlsiteProductIdsFromSuggestResponse(
      'callback({"work":[{"workno":"rj01553075"}],"maker":[]})',
    );

    expect(ids, const <String>['RJ01553075']);
  });

  test('builds title search queries from full name and keywords', () {
    final queries = buildDlsiteTitleSearchQueries(['RJ000000_雨音-ASMR_体験版.mp3']);

    expect(
      queries,
      containsAllInOrder(const <String>[
        'RJ000000 雨音 ASMR 体験版',
        '雨音 asmr',
        'asmr 体験版',
        '雨音',
        'asmr',
        '体験版',
      ]),
    );
  });

  test('expands long Japanese titles into searchable terms', () {
    final keywords = extractDlsiteTitleKeywords(
      '優しい耳舐め専門店と意地悪な足コキ専門店が合体しちゃった '
      '甘やかされながら叱られて頭どろどろになっていいよ',
    );

    expect(
      keywords,
      containsAll(const <String>['耳舐め', '足コキ', '意地悪', '頭どろどろ', '合体']),
    );
  });

  test('prioritizes meaningful phrase queries for long Japanese titles', () {
    final queries = buildDlsiteTitleSearchQueries([
      '\u512a\u3057\u3044\u8033\u8210\u3081\u5c02\u9580\u5e97'
          '\u3068\u610f\u5730\u60aa\u306a\u8db3\u30b3\u30ad\u5c02\u9580\u5e97'
          '\u304c\u5408\u4f53\u3057\u3061\u3083\u3063\u305f '
          '\u7518\u3084\u304b\u3055\u308c\u306a\u304c\u3089\u53f1\u3089\u308c\u3066'
          '\u982d\u3069\u308d\u3069\u308d\u306b\u306a\u3063\u3066\u3044\u3044\u3088',
    ]);

    expect(
      queries.take(8),
      containsAll(const <String>[
        '\u512a\u3057\u3044\u8033\u8210\u3081\u5c02\u9580\u5e97 '
            '\u8033\u8210\u3081\u5c02\u9580\u5e97 '
            '\u610f\u5730\u60aa\u306a\u8db3\u30b3\u30ad\u5c02\u9580\u5e97',
        '\u8033\u8210\u3081\u5c02\u9580\u5e97 '
            '\u610f\u5730\u60aa\u306a\u8db3\u30b3\u30ad\u5c02\u9580\u5e97 '
            '\u8db3\u30b3\u30ad\u5c02\u9580\u5e97',
        '\u610f\u5730\u60aa\u306a\u8db3\u30b3\u30ad\u5c02\u9580\u5e97 '
            '\u8db3\u30b3\u30ad\u5c02\u9580\u5e97 '
            '\u8033\u8210\u3081',
      ]),
    );
  });

  test('keeps exact long title as first DLsite suggest query', () {
    final queries = buildDlsiteTitleSearchQueries([
      '優しい耳舐め専門店と意地悪な足コキ専門店が合体しちゃった '
          '甘やかされながら叱られて頭どろどろになっていいよ',
    ]);

    expect(
      queries.first,
      '優しい耳舐め専門店と意地悪な足コキ専門店が合体しちゃった '
      '甘やかされながら叱られて頭どろどろになっていいよ',
    );
  });

  test('scores metadata by matched title keywords', () {
    final metadata = DlsiteMetadata(
      rjCode: 'RJ01014447',
      workTitle: '雨音と耳かき ASMR',
      circleName: 'Circle',
      voiceActors: <String>['Voice A'],
      tags: <String>['癒し'],
    );

    final score = scoreDlsiteMetadataTitleMatch(metadata, const <String>[
      '雨音',
      'asmr',
      '催眠',
    ]);

    expect(score, 2);
  });
}

class _HangingHttpClient implements HttpClient {
  int getUrlCalls = 0;

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    getUrlCalls += 1;
    return Completer<HttpClientRequest>().future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LocalDlsiteHttpClient implements HttpClient {
  _LocalDlsiteHttpClient(this.client, this.port);
  final HttpClient client;
  final int port;

  @override
  Future<HttpClientRequest> getUrl(Uri url) => client.getUrl(
    url.replace(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: port,
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
