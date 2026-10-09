import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../domain/asmr_models.dart';
import '../domain/asmr_media_sources.dart';
import 'asmr_request_cancellation.dart';

export 'asmr_request_cancellation.dart';

class AsmrApiService {
  AsmrApiService({HttpClient? httpClient, Uri? baseUri})
    : _httpClient = httpClient ?? HttpClient() {
    try {
      _httpClient.connectionTimeout = _requestTimeout;
    } catch (_) {
      // Test doubles and platform clients may not expose socket settings.
    }
    if (baseUri != null) {
      _candidateDomains = [baseUri.toString(), ...asmrApiDomains];
    } else {
      _candidateDomains = List.of(asmrApiDomains);
    }
  }

  final HttpClient _httpClient;
  late final List<String> _candidateDomains;
  int _currentDomainIndex = 0;
  bool _closed = false;

  bool get isClosed => _closed;

  void close({bool force = true}) {
    if (_closed) return;
    _closed = true;
    _httpClient.close(force: force);
  }

  static bool isOfficialMediaUrl(String? value) {
    final host = Uri.tryParse(value?.trim() ?? '')?.host.toLowerCase() ?? '';
    return isAsmrApiHost(host) ||
        host == 'kiko-play-niptan.one' ||
        host.endsWith('.kiko-play-niptan.one');
  }

  static List<String> mediaStreamUrlsForHash(String hash) =>
      _mediaUrlsForHash(hash, operation: 'stream');

  static List<String> mediaDownloadUrlsForHash(String hash) =>
      _mediaUrlsForHash(hash, operation: 'download');

  static List<String> _mediaUrlsForHash(
    String hash, {
    required String operation,
  }) {
    final segments = hash
        .trim()
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty ||
        segments.any((segment) => segment == '.' || segment == '..')) {
      return const <String>[];
    }
    return asmrApiDomains
        .map(
          (domain) => Uri.parse(domain)
              .replace(
                pathSegments: <String>['api', 'media', operation, ...segments],
              )
              .toString(),
        )
        .toList(growable: false);
  }

  static const String _acceptLanguage = 'zh-CN,zh;q=0.9,en;q=0.8';
  static const Duration _requestTimeout = Duration(seconds: 15);

  Future<AsmrAuthSession> login({
    required String name,
    required String password,
  }) async {
    final response = await _sendJsonRequest(
      method: 'POST',
      path: '/api/auth/me',
      body: <String, Object?>{'name': name, 'password': password},
    );
    final token = (response['token'] as String?) ?? '';
    final user = response['user'] as Map<String, dynamic>? ?? response;
    final userName =
        (user['name'] as String?) ??
        (user['username'] as String?) ??
        (user['userName'] as String?) ??
        name;
    if (token.trim().isEmpty) {
      throw const HttpException('ASMR login response did not include a token.');
    }
    return AsmrAuthSession(token: token, userName: userName);
  }

  Future<AsmrAuthSession?> checkSession(String token) async {
    final response = await _sendJsonRequest(
      method: 'GET',
      path: '/api/auth/me',
      token: token,
    );
    final user = response['user'] as Map<String, dynamic>? ?? response;
    final loggedIn = user['loggedIn'] as bool? ?? token.trim().isNotEmpty;
    if (!loggedIn) {
      return null;
    }
    final userName =
        (user['name'] as String?) ??
        (user['username'] as String?) ??
        (user['userName'] as String?) ??
        '';
    final newToken = (response['token'] as String?)?.trim();
    return AsmrAuthSession(
      token: (newToken != null && newToken.isNotEmpty) ? newToken : token,
      userName: userName,
    );
  }

  Future<List<AsmrReviewRecord>> fetchReviews({
    required String token,
    String? filter,
    int page = 1,
    String order = 'updated_at',
    String sort = 'desc',
    AsmrContentLanguage language = AsmrContentLanguage.zh,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    final query = <String, String>{
      'order': order,
      'sort': sort,
      'page': '$page',
    };
    if (filter != null && filter.isNotEmpty) {
      query['filter'] = filter;
    }
    final response = await _sendJsonRequest(
      method: 'GET',
      path: '/api/review',
      token: token,
      queryParameters: query,
      cancellationToken: cancellationToken,
    );
    return (response['works'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map((json) => AsmrReviewRecord.fromJson(json, language: language))
        .toList(growable: false);
  }

  Future<void> putReviewProgress({
    required int workId,
    required String progress,
    required String token,
  }) async {
    await _send(
      method: 'PUT',
      path: '/api/review',
      token: token,
      body: <String, Object?>{'work_id': workId, 'progress': progress},
    );
  }

  Future<void> deleteReview({
    required int workId,
    required String token,
  }) async {
    await _send(
      method: 'DELETE',
      path: '/api/review',
      token: token,
      queryParameters: <String, String>{'work_id': '$workId'},
    );
  }

  Future<AsmrWorkPage> fetchWorks({
    required String order,
    required String sort,
    int page = 1,
    int pageSize = 40,
    String? token,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    final query = <String, String>{
      'order': order,
      'sort': sort,
      'page': '$page',
      'pageSize': '$pageSize',
      'subtitle': '0',
    };
    final response = await _sendJsonRequest(
      method: 'GET',
      path: '/api/works',
      queryParameters: query,
      token: token,
      cancellationToken: cancellationToken,
    );
    return AsmrWorkPage.fromJson(response, language: language);
  }

  Future<AsmrWorkPage> searchWorks({
    required String keyword,
    required String order,
    required String sort,
    int page = 1,
    int pageSize = 40,
    String? token,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    final response = await _sendJsonRequest(
      method: 'POST',
      path: '/api/search/',
      token: token,
      cancellationToken: cancellationToken,
      body: <String, Object?>{
        'keyword': keyword,
        'order': order,
        'sort': sort,
        'page': page,
        'pageSize': pageSize,
        'subtitle': 0,
        'includeTranslationWorks': true,
      },
    );
    return AsmrWorkPage.fromJson(response, language: language);
  }

  Future<List<AsmrTrackFile>> fetchTrackTree(
    int workId, {
    String? token,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    final response = await _send(
      method: 'GET',
      path: '/api/tracks/$workId',
      token: token,
      decodeResponse: _decodeTrackTree,
      cancellationToken: cancellationToken,
    );
    if (response is List<AsmrTrackFile>) return response;
    throw const HttpException('Unexpected API response list.');
  }

  Future<Map<String, dynamic>> _sendJsonRequest({
    required String method,
    required String path,
    Map<String, String>? queryParameters,
    String? token,
    Object? body,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    final response = await _send(
      method: method,
      path: path,
      queryParameters: queryParameters,
      token: token,
      body: body,
      cancellationToken: cancellationToken,
    );
    if (response is Map<String, dynamic>) {
      return response;
    }
    throw const HttpException('Unexpected API response.');
  }

  Future<Object?> _send({
    required String method,
    required String path,
    Map<String, String>? queryParameters,
    String? token,
    Object? body,
    ComputeCallback<String, Object?> decodeResponse = jsonDecode,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    final startDomainIndex = _currentDomainIndex;
    int attempt = 0;
    Object? lastError;
    StackTrace? lastStackTrace;

    while (attempt < _candidateDomains.length) {
      cancellationToken?.throwIfCancelled();
      final domainIndex =
          (startDomainIndex + attempt) % _candidateDomains.length;
      final domain = _candidateDomains[domainIndex];
      final baseUri = Uri.parse(domain);
      final uri = baseUri.replace(path: path, queryParameters: queryParameters);

      void Function()? removeAbortListener;
      HttpClientRequest? openedRequest;
      var attemptRetired = false;
      try {
        final opening = _httpClient.openUrl(method, uri).then((request) {
          // openUrl may finish after the caller has already been cancelled.
          if (cancellationToken?.isCancelled ?? false) {
            request.abort(const AsmrRequestCancelled());
            throw const AsmrRequestCancelled();
          }
          if (attemptRetired) {
            request.abort();
            throw const HttpException('ASMR API request attempt has ended.');
          }
          openedRequest = request;
          return request;
        });
        final request = await (cancellationToken?.waitFor(opening) ?? opening)
            .timeout(_requestTimeout);
        removeAbortListener = cancellationToken?.addListener(
          () => request.abort(const AsmrRequestCancelled()),
        );
        cancellationToken?.throwIfCancelled();
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        request.headers.set(HttpHeaders.acceptLanguageHeader, _acceptLanguage);
        request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        if (token != null && token.isNotEmpty) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        if (body != null) {
          request.add(utf8.encode(json.encode(body)));
        }
        final closing = request.close().then((response) {
          if (cancellationToken?.isCancelled ?? false) {
            unawaited(response.listen(null).cancel());
            throw const AsmrRequestCancelled();
          }
          return response;
        });
        final response = await (cancellationToken?.waitFor(closing) ?? closing)
            .timeout(_requestTimeout);
        final responseBody = await _readResponseBody(
          response,
          cancellationToken,
        );
        cancellationToken?.throwIfCancelled();
        if (response.statusCode >= 500 && response.statusCode <= 599) {
          throw AsmrApiException(
            'ASMR API server error (${response.statusCode}).',
            statusCode: response.statusCode,
            uri: uri,
          );
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw AsmrApiException(
            'ASMR API request failed (${response.statusCode}).',
            statusCode: response.statusCode,
            uri: uri,
          );
        }

        _currentDomainIndex = domainIndex;

        if (responseBody.isEmpty) {
          return null;
        }
        // Responses can arrive during a later navigation or dock animation.
        // Decode off the UI isolate even when the request started while idle.
        final decoding = compute(decodeResponse, responseBody);
        return await (cancellationToken?.waitFor(decoding) ?? decoding);
      } catch (error, stackTrace) {
        cancellationToken?.throwIfCancelled();
        if (error is AsmrRequestCancelled) rethrow;
        lastError = error;
        lastStackTrace = stackTrace;
        if (error is AsmrApiException && error.statusCode < 500) {
          rethrow;
        }
        // Model field errors are not endpoint failures and previously escaped
        // from fetchTrackTree after JSON decoding without retrying a domain.
        if (error is Error) rethrow;
      } finally {
        // A timeout also retires this attempt; it must not keep a socket alive
        // after failover has moved on and detached its cancellation listener.
        attemptRetired = true;
        removeAbortListener?.call();
        openedRequest?.abort();
      }
      attempt++;
    }

    if (lastError != null) {
      Error.throwWithStackTrace(
        lastError,
        lastStackTrace ?? StackTrace.current,
      );
    }
    throw const HttpException('All ASMR API candidates failed.');
  }

  Future<String> _readResponseBody(
    HttpClientResponse response,
    AsmrRequestCancellationToken? cancellationToken,
  ) async {
    final body = StringBuffer();
    final completed = Completer<String>();
    final subscription = response
        .transform(utf8.decoder)
        .listen(
          body.write,
          onError: (Object error, StackTrace stackTrace) {
            if (!completed.isCompleted) {
              completed.completeError(error, stackTrace);
            }
          },
          onDone: () {
            if (!completed.isCompleted) completed.complete(body.toString());
          },
          cancelOnError: true,
        );
    // HttpClientRequest.abort no longer affects an already received response;
    // cancel its body subscription too to stop downloading stale response data.
    final removeListener = cancellationToken?.addListener(() {
      unawaited(subscription.cancel());
      if (!completed.isCompleted) {
        completed.completeError(const AsmrRequestCancelled());
      }
    });
    try {
      return await completed.future.timeout(const Duration(seconds: 30));
    } finally {
      removeListener?.call();
      await subscription.cancel();
    }
  }
}

Object? _decodeTrackTree(String body) {
  final response = jsonDecode(body);
  // Keep shape validation at the caller, outside endpoint failover.
  if (response is! List<dynamic>) return response;
  return response
      .whereType<Map<String, dynamic>>()
      .map(AsmrTrackFile.fromJson)
      .toList(growable: false);
}

class AsmrApiException extends HttpException {
  const AsmrApiException(super.message, {required this.statusCode, super.uri});

  final int statusCode;

  bool get isAuthenticationFailure =>
      statusCode == HttpStatus.unauthorized ||
      statusCode == HttpStatus.forbidden ||
      statusCode == 419;

  static bool isAuthenticationError(Object error) =>
      error is AsmrApiException && error.isAuthenticationFailure;
}
