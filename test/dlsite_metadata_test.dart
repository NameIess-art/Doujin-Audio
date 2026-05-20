import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/i18n/app_language_provider.dart';
import 'package:nameless_audio/models/dlsite_metadata.dart';
import 'package:nameless_audio/services/dlsite_metadata_service.dart';

void main() {
  test('maps selected DLsite metadata language to locale headers', () {
    expect(dlsiteLocaleForLanguage(AppLanguage.zh), 'zh-cn');
    expect(dlsiteLocaleForLanguage(AppLanguage.ja), 'ja-jp');
    expect(dlsiteLocaleForLanguage(AppLanguage.en), 'en-us');
    expect(
      dlsiteAcceptLanguageForLanguage(AppLanguage.en),
      'en-US,en;q=0.9,ja-JP;q=0.8,zh-CN;q=0.7',
    );
  });

  test('parses DLsite product json into editable metadata', () {
    final metadata = DlsiteMetadata.fromProductJson({
      'workno': 'RJ01014447',
      'work_name': 'Work title',
      'maker_name': 'Circle',
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
    const metadata = DlsiteMetadata(
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
