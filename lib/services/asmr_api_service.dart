import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/asmr_models.dart';

class AsmrApiService {
  AsmrApiService({HttpClient? httpClient, Uri? baseUri})
    : _httpClient = httpClient ?? HttpClient(),
      _baseUri = baseUri ?? Uri.parse('https://api.asmr-200.com');

  final HttpClient _httpClient;
  final Uri _baseUri;

  static const String _acceptLanguage = 'zh-CN,zh;q=0.9,en;q=0.8';

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
  }) async {
    final response = await _sendJsonRequest(
      method: 'POST',
      path: '/api/search/',
      token: token,
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

  Future<AsmrWorkDetail> fetchWorkDetail(
    int workId, {
    String? token,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
  }) async {
    final response = await _sendJsonRequest(
      method: 'GET',
      path: '/api/workInfo/$workId',
      token: token,
    );
    return AsmrWorkDetail.fromJson(response, language: language);
  }

  Future<List<AsmrTrackFile>> fetchTrackTree(
    int workId, {
    String? token,
  }) async {
    final response = await _sendJsonRequestList(
      method: 'GET',
      path: '/api/tracks/$workId',
      token: token,
    );
    return response
        .whereType<Map<String, dynamic>>()
        .map(AsmrTrackFile.fromJson)
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> _sendJsonRequest({
    required String method,
    required String path,
    Map<String, String>? queryParameters,
    String? token,
    Object? body,
  }) async {
    final response = await _send(
      method: method,
      path: path,
      queryParameters: queryParameters,
      token: token,
      body: body,
    );
    if (response is Map<String, dynamic>) {
      return response;
    }
    throw const HttpException('Unexpected API response.');
  }

  Future<List<dynamic>> _sendJsonRequestList({
    required String method,
    required String path,
    Map<String, String>? queryParameters,
    String? token,
    Object? body,
  }) async {
    final response = await _send(
      method: method,
      path: path,
      queryParameters: queryParameters,
      token: token,
      body: body,
    );
    if (response is List<dynamic>) {
      return response;
    }
    throw const HttpException('Unexpected API response list.');
  }

  Future<Object?> _send({
    required String method,
    required String path,
    Map<String, String>? queryParameters,
    String? token,
    Object? body,
  }) async {
    final uri = _baseUri.replace(path: path, queryParameters: queryParameters);
    final request = await _httpClient.openUrl(method, uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.acceptLanguageHeader, _acceptLanguage);
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    if (token != null && token.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      request.add(utf8.encode(json.encode(body)));
    }
    final response = await request.close();
    final responseBody = await utf8.decodeStream(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AsmrApiException(
        'ASMR API request failed (${response.statusCode}).',
        statusCode: response.statusCode,
        uri: uri,
      );
    }
    if (responseBody.isEmpty) {
      return null;
    }
    return json.decode(responseBody);
  }
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
