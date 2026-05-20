import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../i18n/app_language_provider.dart';
import '../models/audio_detail.dart';
import '../models/dlsite_metadata.dart';
import 'path_matcher.dart';
import 'platform_channels.dart';

class DlsiteMetadataException implements Exception {
  const DlsiteMetadataException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DlsiteMetadataService {
  DlsiteMetadataService({HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient();

  static const MethodChannel _fileCacheChannel = MethodChannel(
    FileCacheChannel.name,
  );
  static const List<String> _productSites = <String>[
    'maniax',
    'home',
    'girls',
    'bl',
    'books',
    'pro',
  ];

  final HttpClient _httpClient;

  Future<DlsiteMetadata> fetchByRjCode(
    String rjCode, {
    AppLanguage language = AppLanguage.ja,
  }) async {
    final normalized = AudioDetail.findRjCodeInText(rjCode);
    if (normalized == null) {
      throw const DlsiteMetadataException('Invalid RJ code');
    }

    final languages = <AppLanguage>[
      language,
      if (language != AppLanguage.ja) AppLanguage.ja,
    ];
    Object? lastError;
    for (final candidateLanguage in languages) {
      for (final site in _productSites) {
        try {
          final uri = Uri.https('www.dlsite.com', '/$site/api/=/product.json', {
            'workno': normalized,
          });
          return await _fetchProductMetadata(uri, language: candidateLanguage);
        } catch (error) {
          lastError = error;
        }
      }
      for (final site in _productSites) {
        try {
          final uri = Uri.https(
            'www.dlsite.com',
            '/$site/work/=/product_id/$normalized.html',
          );
          final html = await _get(uri, language: candidateLanguage);
          final metadata = decodeDlsiteProductHtml(
            html,
            fallbackRjCode: normalized,
          );
          if (metadata != null &&
              metadata.rjCode.isNotEmpty &&
              metadata.workTitle.isNotEmpty) {
            return metadata;
          }
        } catch (error) {
          lastError = error;
        }
      }
    }
    if (lastError is DlsiteMetadataException) throw lastError;
    throw const DlsiteMetadataException('No DLsite metadata found');
  }

  Future<List<DlsiteMetadata>> searchByTitleCandidates(
    Iterable<String> titles, {
    int limit = 10,
    AppLanguage language = AppLanguage.ja,
  }) async {
    final titleList = titles.toList(growable: false);
    final queries = buildDlsiteTitleSearchQueries(titleList);
    final keywords = titleList
        .expand(extractDlsiteTitleKeywords)
        .map((keyword) => keyword.toLowerCase())
        .toSet();
    final resultsByRjCode = <String, _ScoredDlsiteMetadata>{};

    for (final title in titleList) {
      final rjCode = AudioDetail.findRjCodeInText(title);
      if (rjCode == null || resultsByRjCode.containsKey(rjCode)) continue;
      try {
        final metadata = await fetchByRjCode(rjCode, language: language);
        resultsByRjCode[rjCode] = _ScoredDlsiteMetadata(
          metadata,
          keywords.length + 100,
        );
      } catch (_) {
        // Fall through to title search if an embedded RJ code is stale.
      }
    }

    for (final query in queries) {
      final rjCodes = await _searchProductIdsByTitle(query, language: language);
      for (final rjCode in rjCodes) {
        if (resultsByRjCode.containsKey(rjCode)) continue;
        try {
          final metadata = await fetchByRjCode(rjCode, language: language);
          final score = scoreDlsiteMetadataTitleMatch(metadata, keywords);
          if (score <= 0) continue;
          resultsByRjCode[rjCode] = _ScoredDlsiteMetadata(metadata, score);
        } catch (_) {
          // Search results can contain products unavailable through the JSON
          // endpoint; keep later candidates usable.
        }
      }
    }

    if (resultsByRjCode.isEmpty) {
      throw const DlsiteMetadataException('No DLsite metadata found');
    }
    final results = resultsByRjCode.values.toList()
      ..sort((a, b) {
        final scoreOrder = b.score.compareTo(a.score);
        if (scoreOrder != 0) return scoreOrder;
        return a.metadata.rjCode.compareTo(b.metadata.rjCode);
      });
    return List.unmodifiable(
      results.take(limit).map((result) => result.metadata),
    );
  }

  Future<List<String>> _searchProductIdsByTitle(
    String query, {
    required AppLanguage language,
  }) async {
    for (final site in _productSites) {
      final suggestUri = Uri.https('www.dlsite.com', '/suggest/', {
        'term': query,
        'site': site,
        'time': DateTime.now().millisecondsSinceEpoch.toString(),
        'touch': '0',
      });
      try {
        final response = await _get(suggestUri, language: language);
        final rjCodes = extractDlsiteProductIdsFromSuggestResponse(response);
        if (rjCodes.isNotEmpty) return rjCodes;
      } catch (_) {
        // Keep title search resilient when DLsite changes or blocks one endpoint.
      }
    }

    final encodedTitle = Uri.encodeComponent(query);
    for (final site in _productSites) {
      final searchUri = Uri.parse(
        'https://www.dlsite.com/$site/fsr/=/keyword/$encodedTitle',
      );
      try {
        final response = await _get(searchUri, language: language);
        final rjCodes = extractDlsiteProductIdsFromSearchHtml(response);
        if (rjCodes.isNotEmpty) return rjCodes;
      } catch (_) {}
    }
    return const <String>[];
  }

  Future<String> downloadCover({
    required String coverUrl,
    required String folderPath,
    required String rjCode,
    AppLanguage language = AppLanguage.ja,
  }) async {
    final uri = Uri.parse(coverUrl);
    final extension = _coverExtension(uri);
    final fileName = 'dlsite_${rjCode.toUpperCase()}_cover$extension';
    final request = await _httpClient.getUrl(uri);
    _applyHeaders(request, language);
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DlsiteMetadataException(
        'Cover download failed: ${response.statusCode}',
      );
    }

    if (PathMatcher.isContentUri(folderPath)) {
      final bytes = await response.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      final mimeType =
          response.headers.contentType?.mimeType ?? _coverMimeType(extension);
      final savedPath = await _fileCacheChannel.invokeMethod<String>(
        FileCacheMethod.writeFileBytesToFolder,
        <String, Object?>{
          'folder': folderPath,
          'name': fileName,
          'bytes': Uint8List.fromList(bytes),
          'mimeType': mimeType,
        },
      );
      if (savedPath == null || savedPath.isEmpty) {
        throw const DlsiteMetadataException('Content cover save failed');
      }
      return savedPath;
    }

    final destination = File(path.join(folderPath, fileName));
    await response.pipe(destination.openWrite());
    return destination.path;
  }

  Future<String> _get(Uri uri, {required AppLanguage language}) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt += 1) {
      try {
        final request = await _httpClient.getUrl(uri);
        _applyHeaders(request, language);
        final response = await request.close();
        final bytes = await response.fold<List<int>>(
          <int>[],
          (buffer, chunk) => buffer..addAll(chunk),
        );
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return utf8.decode(bytes);
        }
        final error = DlsiteMetadataException(
          'DLsite request failed: ${response.statusCode}',
        );
        if (!_shouldRetryStatus(response.statusCode) || attempt == 2) {
          throw error;
        }
        lastError = error;
      } on IOException catch (error) {
        if (attempt == 2) rethrow;
        lastError = error;
      }
      await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
    }
    if (lastError is DlsiteMetadataException) throw lastError;
    throw const DlsiteMetadataException('DLsite request failed');
  }

  Future<DlsiteMetadata> _fetchProductMetadata(
    Uri uri, {
    required AppLanguage language,
  }) async {
    final response = await _get(uri, language: language);
    final product = decodeDlsiteProductJsonResponse(response);
    if (product == null) {
      throw const DlsiteMetadataException('No DLsite metadata found');
    }

    final metadata = DlsiteMetadata.fromProductJson(product);
    if (metadata.rjCode.isEmpty || metadata.workTitle.isEmpty) {
      throw const DlsiteMetadataException('Incomplete DLsite metadata');
    }
    return metadata;
  }

  bool _shouldRetryStatus(int statusCode) {
    return statusCode == HttpStatus.requestTimeout ||
        statusCode == HttpStatus.tooManyRequests ||
        statusCode == HttpStatus.internalServerError ||
        statusCode == HttpStatus.badGateway ||
        statusCode == HttpStatus.serviceUnavailable ||
        statusCode == HttpStatus.gatewayTimeout;
  }

  void _applyHeaders(HttpClientRequest request, AppLanguage language) {
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0 Safari/537.36',
    );
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/json,text/javascript,text/html,text/*,*/*',
    );
    request.headers.set(
      HttpHeaders.acceptLanguageHeader,
      dlsiteAcceptLanguageForLanguage(language),
    );
    request.headers.set(
      HttpHeaders.cookieHeader,
      'adultchecked=1; __dlsite_com_share_adultchecked=1; '
      'locale=${dlsiteLocaleForLanguage(language)}',
    );
    request.headers.set(HttpHeaders.refererHeader, 'https://www.dlsite.com/');
    request.headers.set('X-Requested-With', 'XMLHttpRequest');
  }

  String _coverExtension(Uri uri) {
    final extension = path.extension(uri.path).toLowerCase();
    if (const <String>{'.jpg', '.jpeg', '.png', '.webp'}.contains(extension)) {
      return extension;
    }
    return '.jpg';
  }

  String _coverMimeType(String extension) {
    return switch (extension.toLowerCase()) {
      '.png' => 'image/png',
      '.webp' => 'image/webp',
      '.jpeg' => 'image/jpeg',
      '.jpg' => 'image/jpeg',
      _ => 'image/jpeg',
    };
  }
}

Map<String, dynamic>? decodeDlsiteProductJsonResponse(String response) {
  final decoded = json.decode(response);
  final product = _firstDlsiteProductObject(decoded);
  return product?.cast<String, dynamic>();
}

DlsiteMetadata? decodeDlsiteProductHtml(
  String html, {
  required String fallbackRjCode,
}) {
  final rjCode =
      AudioDetail.findRjCodeInText(fallbackRjCode) ??
      AudioDetail.findRjCodeInText(html) ??
      fallbackRjCode.toUpperCase();
  final title =
      _htmlCapture(
        html,
        RegExp(
          r'<h1[^>]*id=["'
          ']work_name["'
          '][^>]*>(.*?)</h1>',
          caseSensitive: false,
          dotAll: true,
        ),
      ) ??
      _htmlMetaContent(
        html,
        'og:title',
      )?.replaceFirst(RegExp(r'\s*\[[^\]]+\]\s*\|\s*DLsite.*$'), '') ??
      _htmlAttribute(html, 'data-product-name');
  if (title == null || title.isEmpty) return null;

  final circleName =
      _htmlAttribute(html, 'data-maker-name') ??
      _htmlCapture(
        html,
        RegExp(
          r"""class=["']maker_name["'][\s\S]*?<a[^>]*>(.*?)</a>""",
          caseSensitive: false,
          dotAll: true,
        ),
      ) ??
      _htmlMetaContent(
        html,
        'og:title',
      )?.replaceFirst(RegExp(r'^.*\[([^\]]+)\]\s*\|\s*DLsite.*$'), r'$1');
  final coverUrl = _normalizeDlsiteUrl(_htmlMetaContent(html, 'og:image'));

  return DlsiteMetadata(
    rjCode: rjCode,
    workTitle: title,
    circleName: circleName ?? '',
    voiceActors: const <String>[],
    tags: const <String>[],
    coverUrl: coverUrl,
  );
}

String? _htmlMetaContent(String html, String property) {
  return _htmlCapture(
    html,
    RegExp(
      '<meta[^>]+(?:property|name)=["\\\']${RegExp.escape(property)}["\\\']'
      '[^>]+content=["\\\']([^"\\\']*)["\\\']',
      caseSensitive: false,
      dotAll: true,
    ),
    decodeTags: false,
  );
}

String? _htmlAttribute(String html, String attributeName) {
  return _htmlCapture(
    html,
    RegExp(
      '${RegExp.escape(attributeName)}=["\\\']([^"\\\']*)["\\\']',
      caseSensitive: false,
      dotAll: true,
    ),
    decodeTags: false,
  );
}

String? _htmlCapture(String html, RegExp pattern, {bool decodeTags = true}) {
  final raw = pattern.firstMatch(html)?.group(1);
  if (raw == null) return null;
  final withoutTags = decodeTags
      ? raw.replaceAll(RegExp(r'<[^>]+>'), ' ')
      : raw;
  final decoded = _decodeHtmlEntities(
    withoutTags.replaceAll(RegExp(r'\s+'), ' ').trim(),
  );
  return decoded.isEmpty ? null : decoded;
}

String _decodeHtmlEntities(String value) {
  return value
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ');
}

String? _normalizeDlsiteUrl(String? rawUrl) {
  if (rawUrl == null || rawUrl.isEmpty) return null;
  if (rawUrl.startsWith('//')) return 'https:$rawUrl';
  if (rawUrl.startsWith('/')) return 'https://www.dlsite.com$rawUrl';
  return rawUrl;
}

Map<Object?, Object?>? _firstDlsiteProductObject(Object? decoded) {
  if (decoded is List) {
    return decoded.whereType<Map>().cast<Map<Object?, Object?>>().firstOrNull;
  }
  if (decoded is Map) {
    final map = decoded.cast<Object?, Object?>();
    if (_looksLikeDlsiteProduct(map)) return map;
    for (final key in const <String>['work', 'works', 'products', 'result']) {
      final nested = _firstDlsiteProductObject(map[key]);
      if (nested != null) return nested;
    }
    for (final value in map.values) {
      final nested = _firstDlsiteProductObject(value);
      if (nested != null) return nested;
    }
  }
  return null;
}

bool _looksLikeDlsiteProduct(Map<Object?, Object?> value) {
  return value.containsKey('workno') ||
      value.containsKey('product_id') ||
      value.containsKey('work_name') ||
      value.containsKey('product_name');
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return null;
    return iterator.current;
  }
}

String dlsiteLocaleForLanguage(AppLanguage language) {
  return switch (language) {
    AppLanguage.zh => 'zh-cn',
    AppLanguage.ja => 'ja-jp',
    AppLanguage.en => 'en-us',
  };
}

String dlsiteAcceptLanguageForLanguage(AppLanguage language) {
  return switch (language) {
    AppLanguage.zh => 'zh-CN,zh;q=0.9,ja-JP;q=0.8,en;q=0.7',
    AppLanguage.ja => 'ja-JP,ja;q=0.9,zh-CN;q=0.8,en;q=0.7',
    AppLanguage.en => 'en-US,en;q=0.9,ja-JP;q=0.8,zh-CN;q=0.7',
  };
}

List<String> extractDlsiteProductIdsFromSearchHtml(String html) {
  final seen = <String>{};
  final results = <String>[];
  final pattern = RegExp(r'product_id/(RJ\d{6,})', caseSensitive: false);
  for (final match in pattern.allMatches(html)) {
    final rjCode = match.group(1)?.toUpperCase();
    if (rjCode == null || !seen.add(rjCode)) continue;
    results.add(rjCode);
  }
  return List.unmodifiable(results);
}

List<String> extractDlsiteProductIdsFromSuggestResponse(String response) {
  final jsonText = _unwrapJsonp(response.trim());
  final decoded = json.decode(jsonText);
  if (decoded is! Map) return const <String>[];

  final seen = <String>{};
  final results = <String>[];
  void addWorkNo(Object? value) {
    if (value is! String) return;
    final rjCode = AudioDetail.findRjCodeInText(value);
    if (rjCode == null || !seen.add(rjCode)) return;
    results.add(rjCode);
  }

  final work = decoded['work'];
  if (work is List) {
    for (final item in work) {
      if (item is Map) addWorkNo(item['workno']);
    }
  }

  final maker = decoded['maker'];
  if (maker is List) {
    for (final item in maker) {
      if (item is Map) addWorkNo(item['workno']);
    }
  }

  return List.unmodifiable(results);
}

String _unwrapJsonp(String value) {
  final start = value.indexOf('(');
  final end = value.lastIndexOf(')');
  if (start > 0 && end > start) {
    return value.substring(start + 1, end);
  }
  return value;
}

List<String> buildDlsiteTitleSearchQueries(
  Iterable<String> titles, {
  int maxQueries = 24,
}) {
  final seen = <String>{};
  final queries = <String>[];

  void addQuery(String value) {
    final query = _normalizeSearchTitle(value);
    if (query.isEmpty || !seen.add(query.toLowerCase())) return;
    queries.add(query);
  }

  for (final title in titles) {
    addQuery(title);
    final keywords = extractDlsiteTitleKeywords(title);
    for (var index = 0; index < keywords.length - 2; index += 1) {
      addQuery(
        '${keywords[index]} ${keywords[index + 1]} ${keywords[index + 2]}',
      );
    }
    for (var index = 0; index < keywords.length - 1; index += 1) {
      addQuery('${keywords[index]} ${keywords[index + 1]}');
    }
    for (final keyword in keywords) {
      addQuery(keyword);
    }
    if (queries.length >= maxQueries) break;
  }

  return List.unmodifiable(queries.take(maxQueries));
}

List<String> extractDlsiteTitleKeywords(String value) {
  final normalized = _normalizeSearchTitle(value).toLowerCase();
  if (normalized.isEmpty) return const <String>[];

  final seen = <String>{};
  final keywords = <String>[];
  for (final part in normalized.split(RegExp(r'\s+'))) {
    final keyword = part.trim();
    if (keyword.isEmpty || _isWeakSearchKeyword(keyword)) continue;
    for (final expanded in _expandJapaneseTitleKeyword(keyword)) {
      if (seen.add(expanded)) keywords.add(expanded);
    }
    if (seen.add(keyword)) keywords.add(keyword);
  }
  return List.unmodifiable(keywords);
}

int scoreDlsiteMetadataTitleMatch(
  DlsiteMetadata metadata,
  Iterable<String> keywords,
) {
  final haystack = _normalizeSearchTitle(
    <String>[
      metadata.rjCode,
      metadata.workTitle,
      metadata.circleName,
      ...metadata.voiceActors,
      ...metadata.tags,
    ].join(' '),
  ).toLowerCase();

  var score = 0;
  for (final keyword in keywords.toSet()) {
    if (haystack.contains(keyword.toLowerCase())) score += 1;
  }
  return score;
}

String _normalizeSearchTitle(String value) {
  return value
      .replaceAll(RegExp(r'\.[A-Za-z0-9]{1,8}$'), '')
      .replaceAll(RegExp(r'[\[\]【】「」『』（）()]+'), ' ')
      .replaceAll(RegExp(r'[_\-.\\/+,，、:：;；!！?？]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

bool _isWeakSearchKeyword(String keyword) {
  if (RegExp(r'^rj\d+$').hasMatch(keyword)) return true;
  if (RegExp(r'^\d+$').hasMatch(keyword)) return true;
  if (RegExp(r'^[a-z]$').hasMatch(keyword)) return true;
  return keyword.runes.length < 2;
}

Iterable<String> _expandJapaneseTitleKeyword(String keyword) sync* {
  if (keyword.runes.length < 6) return;

  const meaningfulTerms = <String>[
    '優しい耳舐め専門店',
    '耳舐め専門店',
    '意地悪な足コキ専門店',
    '足コキ専門店',
    '耳舐め',
    '耳なめ',
    '耳かき',
    '足コキ',
    '手コキ',
    'フェラ',
    'パイズリ',
    '専門店',
    '合体',
    '意地悪',
    '優しい',
    '甘やか',
    '叱られ',
    '頭どろどろ',
    'どろどろ',
    '催眠',
    '癒し',
    'ASMR',
  ];
  final lowerKeyword = keyword.toLowerCase();
  for (final term in meaningfulTerms) {
    final normalizedTerm = term.toLowerCase();
    if (lowerKeyword.contains(normalizedTerm)) yield normalizedTerm;
  }

  final compacted = keyword
      .replaceAll('専門店と', '専門店 ')
      .replaceAll('専門店が', '専門店 ')
      .replaceAll('意地悪な', '意地悪 ')
      .replaceAll('優しい', '優しい ')
      .replaceAll('が', ' ')
      .replaceAll('と', ' ')
      .replaceAll('しちゃった', ' ')
      .replaceAll('されながら', ' ')
      .replaceAll('ながら', ' ')
      .replaceAll('られて', ' ')
      .replaceAll('れて', ' ')
      .replaceAll('になって', ' ')
      .replaceAll('なって', ' ')
      .replaceAll('して', ' ')
      .replaceAll('した', ' ')
      .replaceAll('する', ' ')
      .replaceAll('いいよ', ' ');
  for (final chunk in compacted.split(RegExp(r'\s+'))) {
    final value = chunk.trim();
    if (value.isEmpty || value == keyword || _isWeakSearchKeyword(value)) {
      continue;
    }
    yield value;
  }
}

class _ScoredDlsiteMetadata {
  const _ScoredDlsiteMetadata(this.metadata, this.score);

  final DlsiteMetadata metadata;
  final int score;
}
