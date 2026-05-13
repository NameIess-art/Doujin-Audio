import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

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

  final HttpClient _httpClient;

  Future<DlsiteMetadata> fetchByRjCode(String rjCode) async {
    final normalized = AudioDetail.findRjCodeInText(rjCode);
    if (normalized == null) {
      throw const DlsiteMetadataException('Invalid RJ code');
    }

    final uri = Uri.https('www.dlsite.com', '/maniax/api/=/product.json', {
      'workno': normalized,
    });
    final response = await _get(uri);
    final decoded = json.decode(response);
    if (decoded is! List || decoded.isEmpty || decoded.first is! Map) {
      throw const DlsiteMetadataException('No DLsite metadata found');
    }

    final metadata = DlsiteMetadata.fromProductJson(
      (decoded.first as Map).cast<String, dynamic>(),
    );
    if (metadata.rjCode.isEmpty || metadata.workTitle.isEmpty) {
      throw const DlsiteMetadataException('Incomplete DLsite metadata');
    }
    return metadata;
  }

  Future<List<DlsiteMetadata>> searchByTitleCandidates(
    Iterable<String> titles, {
    int limit = 10,
  }) async {
    final queries = buildDlsiteTitleSearchQueries(titles);
    final keywords = titles
        .expand(extractDlsiteTitleKeywords)
        .map((keyword) => keyword.toLowerCase())
        .toSet();
    final resultsByRjCode = <String, _ScoredDlsiteMetadata>{};

    for (final query in queries) {
      final rjCodes = await _searchProductIdsByTitle(query);
      for (final rjCode in rjCodes) {
        if (resultsByRjCode.containsKey(rjCode)) continue;
        try {
          final metadata = await fetchByRjCode(rjCode);
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

  Future<List<String>> _searchProductIdsByTitle(String query) async {
    final suggestUri = Uri.https('www.dlsite.com', '/suggest/', {
      'term': query,
      'site': 'maniax',
      'time': DateTime.now().millisecondsSinceEpoch.toString(),
      'touch': '0',
    });
    try {
      final response = await _get(suggestUri);
      final rjCodes = extractDlsiteProductIdsFromSuggestResponse(response);
      if (rjCodes.isNotEmpty) return rjCodes;
    } catch (_) {
      // Keep title search resilient when DLsite changes or blocks one endpoint.
    }

    final encodedTitle = Uri.encodeComponent(query);
    final searchUri = Uri.parse(
      'https://www.dlsite.com/maniax/fsr/=/keyword/$encodedTitle',
    );
    try {
      final response = await _get(searchUri);
      return extractDlsiteProductIdsFromSearchHtml(response);
    } catch (_) {
      return const <String>[];
    }
  }

  Future<String> downloadCover({
    required String coverUrl,
    required String folderPath,
    required String rjCode,
  }) async {
    final uri = Uri.parse(coverUrl);
    final extension = _coverExtension(uri);
    final fileName = 'dlsite_${rjCode.toUpperCase()}_cover$extension';
    final request = await _httpClient.getUrl(uri);
    _applyHeaders(request);
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

  Future<String> _get(Uri uri) async {
    final request = await _httpClient.getUrl(uri);
    _applyHeaders(request);
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DlsiteMetadataException(
        'DLsite request failed: ${response.statusCode}',
      );
    }
    return utf8.decode(
      await response.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      ),
    );
  }

  void _applyHeaders(HttpClientRequest request) {
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 NamelessAudio/0.8.5',
    );
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/json,text/*,*/*',
    );
    request.headers.set(
      HttpHeaders.acceptLanguageHeader,
      'ja-JP,ja;q=0.9,zh-CN;q=0.8,en;q=0.7',
    );
    request.headers.set(
      HttpHeaders.cookieHeader,
      'adultchecked=1; __dlsite_com_share_adultchecked=1; locale=ja-jp',
    );
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
