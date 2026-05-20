import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/asmr_models.dart';

class AsmrApiService {
  AsmrApiService({HttpClient? httpClient, Uri? baseUri})
    : _httpClient = httpClient ?? HttpClient(),
      _baseUri = baseUri ?? Uri.parse('https://api.asmr.one');

  final HttpClient _httpClient;
  final Uri _baseUri;

  Future<AsmrAuthSession> login({
    required String name,
    required String password,
  }) async {
    final response = await _sendJsonRequest(
      method: 'POST',
      path: '/api/auth/me',
      body: <String, Object?>{'name': name, 'password': password},
    );
    final token = response['token'] as String? ?? '';
    final user = response['user'] as Map<String, dynamic>? ?? response;
    return AsmrAuthSession(
      token: token,
      userId: (user['id'] as num?)?.toInt(),
      userName: (user['name'] as String?) ?? (user['username'] as String?),
    );
  }

  Future<AsmrAuthSession> fetchAuthSession(String token) async {
    final response = await _sendJsonRequest(
      method: 'GET',
      path: '/api/auth/me',
      token: token,
    );
    final user = response['user'] as Map<String, dynamic>? ?? response;
    return AsmrAuthSession(
      token: token,
      userId: (user['id'] as num?)?.toInt(),
      userName: (user['name'] as String?) ?? (user['username'] as String?),
    );
  }

  Future<int?> fetchFavoritePlaylistId(String token) async {
    final response = await _sendJsonRequest(
      method: 'GET',
      path: '/api/playlist/get-default-mark-target-playlist',
      token: token,
    );
    final id = response['id'] as num?;
    return id?.toInt();
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

  Future<AsmrWorkPage> fetchRecommendedWorks({
    required String recommenderUuid,
    String keyword = '',
    int page = 1,
    int pageSize = 40,
    String? token,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
  }) async {
    final response = await _sendJsonRequest(
      method: 'POST',
      path: '/api/recommender/recommend-for-user',
      token: token,
      body: <String, Object?>{
        'keyword': keyword,
        'recommenderUuid': recommenderUuid,
        'page': page,
        'pageSize': pageSize,
        'subtitle': 0,
        'localSubtitledWorks': const <int>[],
        'withPlaylistStatus': const <int>[],
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

  Future<List<AsmrWork>> fetchFavoriteWorks({
    required String token,
    required int playlistId,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
  }) async {
    final response = await _sendJsonRequest(
      method: 'GET',
      path: '/api/playlist/get-playlist-metadata',
      queryParameters: <String, String>{'id': '$playlistId'},
      token: token,
    );
    final workMaps = <Map<String, dynamic>>[];

    void collect(Object? value) {
      if (value is List) {
        for (final item in value) {
          collect(item);
        }
        return;
      }
      if (value is! Map) {
        return;
      }
      final map = value.map((key, item) => MapEntry(key.toString(), item));
      if (map.containsKey('source_id') && map.containsKey('title')) {
        workMaps.add(map);
      }
      for (final nested in map.values) {
        collect(nested);
      }
    }

    collect(response);
    final seenIds = <int>{};
    return workMaps
        .map((json) => AsmrWork.fromJson(json, language: language))
        .where((work) => work.id > 0 && seenIds.add(work.id))
        .toList(growable: false);
  }

  Future<void> addWorkToFavoritePlaylist({
    required String token,
    required int playlistId,
    required int workId,
  }) {
    return _sendWithoutResult(
      method: 'POST',
      path: '/api/playlist/add-works-to-playlist',
      token: token,
      body: <String, Object?>{
        'id': playlistId,
        'works': <int>[workId],
      },
    );
  }

  Future<void> removeWorkFromFavoritePlaylist({
    required String token,
    required int playlistId,
    required int workId,
  }) {
    return _sendWithoutResult(
      method: 'POST',
      path: '/api/playlist/remove-works-from-playlist',
      token: token,
      body: <String, Object?>{
        'id': playlistId,
        'works': <int>[workId],
      },
    );
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

  Future<void> _sendWithoutResult({
    required String method,
    required String path,
    Map<String, String>? queryParameters,
    String? token,
    Object? body,
  }) async {
    await _send(
      method: method,
      path: path,
      queryParameters: queryParameters,
      token: token,
      body: body,
    );
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
