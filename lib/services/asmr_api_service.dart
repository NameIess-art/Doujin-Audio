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
      throw HttpException(
        'ASMR API request failed (${response.statusCode}): $responseBody',
        uri: uri,
      );
    }
    if (responseBody.isEmpty) {
      return null;
    }
    return json.decode(responseBody);
  }
}
