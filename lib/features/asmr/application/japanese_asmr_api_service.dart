import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../domain/asmr_models.dart';
import '../domain/asmr_search_suggestions.dart';
import 'asmr_api_service.dart';

export '../domain/asmr_search_suggestions.dart';

/// Eara exposes an indexed Japanese ASMR catalog, not an ASMR.ONE account API.
class JapaneseAsmrApiService {
  JapaneseAsmrApiService({HttpClient? httpClient, Uri? baseUri})
    : _client = httpClient ?? HttpClient(),
      _baseUri = baseUri ?? Uri.parse('https://earaasmr.com/');

  final HttpClient _client;
  final Uri _baseUri;
  bool _closed = false;
  static const _timeout = Duration(seconds: 20);

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }

  Future<AsmrSearchSuggestions> fetchSearchSuggestions({
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    final body = await _get(
      'search-suggestions',
      const {},
      cancellationToken,
      endpointPath: 'api/search-suggestions',
    );
    final result = await compute(_decodeSearchSuggestions, body);
    cancellationToken?.throwIfCancelled();
    return result;
  }

  Future<AsmrWorkPage> searchWorks({
    required String keyword,
    int page = 1,
    int pageSize = 40,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    final body = await _get('search', {
      'q': keyword.trim(),
      'limit': '$pageSize',
      'offset': '${(page - 1) * pageSize}',
      'sort': 'release',
    }, cancellationToken);
    final result = await compute(_decodeJapaneseWorkPage, (
      body: body,
      page: page,
      pageSize: pageSize,
    ));
    cancellationToken?.throwIfCancelled();
    return result;
  }

  Future<List<AsmrTrackFile>> fetchTrackTree(
    AsmrWork work, {
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    final resource = work.resourceFor(AsmrCatalogSource.japaneseAsmr);
    final code = normalizeAsmrWorkCode(resource?.code ?? work.workCode);
    if (code.isEmpty) {
      throw const FormatException('Japanese ASMR work is missing its code.');
    }
    final body = await _get('tracks', {'rj': code}, cancellationToken);
    final result = await compute(_decodeJapaneseTrackTree, (
      body: body,
      work: work,
    ));
    cancellationToken?.throwIfCancelled();
    return result;
  }

  Future<String> _get(
    String operation,
    Map<String, String> query,
    AsmrRequestCancellationToken? cancellationToken, {
    String? endpointPath,
  }) async {
    if (_closed) throw StateError('Japanese ASMR client is closed.');
    cancellationToken?.throwIfCancelled();
    final uri = _baseUri
        .resolve(endpointPath ?? 'api/jp-asmr/$operation')
        .replace(queryParameters: query);
    HttpClientRequest? request;
    StreamSubscription<String>? subscription;
    var retired = false;
    final removeListener = cancellationToken?.addListener(() {
      request?.abort(const AsmrRequestCancelled());
      unawaited(subscription?.cancel());
    });
    try {
      final opening = _client.getUrl(uri).then((value) {
        if (retired || cancellationToken?.isCancelled == true) {
          value.abort();
          throw const AsmrRequestCancelled();
        }
        return request = value;
      });
      request = await (cancellationToken?.waitFor(opening) ?? opening).timeout(
        _timeout,
      );
      request!.headers.set(
        HttpHeaders.userAgentHeader,
        'DoujinAudio/online-library',
      );
      request!.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final closing = request!.close();
      final response = await (cancellationToken?.waitFor(closing) ?? closing)
          .timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.listen(null).cancel();
        throw AsmrApiException(
          'Japanese ASMR request failed (${response.statusCode}).',
          statusCode: response.statusCode,
          uri: uri,
        );
      }
      final completed = Completer<String>();
      final text = StringBuffer();
      subscription = response
          .transform(utf8.decoder)
          .listen(
            text.write,
            onDone: () => completed.complete(text.toString()),
            onError: (Object error, StackTrace stack) =>
                completed.completeError(error, stack),
            cancelOnError: true,
          );
      return await (cancellationToken?.waitFor(completed.future) ??
              completed.future)
          .timeout(_timeout);
    } finally {
      retired = true;
      removeListener?.call();
      request?.abort();
      await subscription?.cancel();
    }
  }
}

AsmrSearchSuggestions _decodeSearchSuggestions(String body) {
  final json = jsonDecode(body);
  if (json is! Map<String, dynamic>) {
    throw const FormatException('Invalid Eara search suggestions response.');
  }
  return AsmrSearchSuggestions.fromJson(json);
}

AsmrWorkPage _decodeJapaneseWorkPage(
  ({String body, int page, int pageSize}) input,
) {
  final json = jsonDecode(input.body) as Map<String, dynamic>;
  final items = json['items'];
  if (items is! List || json['total'] is! num) {
    throw const FormatException('Invalid Japanese ASMR search response.');
  }
  return AsmrWorkPage(
    works: items
        .map(
          (item) =>
              japaneseAsmrWorkFromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(growable: false),
    currentPage: input.page,
    pageSize: input.pageSize,
    totalCount: (json['total'] as num).toInt(),
  );
}

AsmrWork japaneseAsmrWorkFromJson(Map<String, dynamic> json) {
  final id = (json['workId'] as num?)?.toInt();
  if (id == null || id <= 0) {
    throw const FormatException('Japanese ASMR work is missing workId.');
  }
  final code = normalizeAsmrWorkCode(
    (json['rj'] ?? json['sourceId'] ?? '').toString(),
  );
  final pageUrl = (json['pageUrl'] as String?) ?? '';
  final mapped = <String, dynamic>{
    ...json,
    'id': id,
    'sourceId': code,
    'sourceType': 'jp-asmr',
    'sourceUrl': pageUrl,
    'circleName': json['circle'] ?? '',
    'voiceActors': json['cvs'] ?? const <String>[],
    'createDate': json['publishedAt'],
    'resources': [
      AsmrWorkResource(
        source: AsmrCatalogSource.japaneseAsmr,
        id: id,
        code: code,
        pageUrl: pageUrl,
      ).toJson(),
    ],
  };
  return AsmrWork.fromJson(mapped);
}

List<AsmrTrackFile> _decodeJapaneseTrackTree(
  ({String body, AsmrWork work}) input,
) {
  final json = jsonDecode(input.body) as Map<String, dynamic>;
  final roots = json['trackTree'];
  if (roots is! List) {
    throw const FormatException('Invalid Japanese ASMR track response.');
  }
  Map<String, dynamic> mapNode(Map<dynamic, dynamic> raw) => <String, dynamic>{
    ...raw.cast<String, dynamic>(),
    'mediaStreamUrl': raw['streamUrl'] ?? raw['mediaStreamUrl'],
    'workTitle': input.work.title,
    'workKey': input.work.workKey,
    'work': {
      'id': input.work.resourceFor(AsmrCatalogSource.japaneseAsmr)?.id ??
          json['workId'] ?? input.work.id,
      'source_id': input.work.workCode,
    },
    'children': [
      for (final child
          in (raw['children'] as List<dynamic>? ?? const <dynamic>[]))
        mapNode(child as Map<dynamic, dynamic>),
    ],
  };
  return roots
      .map(
        (node) =>
            AsmrTrackFile.fromJson(mapNode(node as Map<dynamic, dynamic>)),
      )
      .toList(growable: false);
}
