import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_remote_catalog_service.dart';
import 'package:doujin_audio/features/asmr/application/japanese_asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_persistence_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('remote catalog requires its managed Eara client', () {
    final oneApi = AsmrApiService();
    addTearDown(oneApi.close);
    final catalog = AsmrRemoteCatalogService(
      apiService: oneApi,
      persistenceRepository: _UnusedPersistence(),
    );
    expect(catalog.loadSearchSuggestions, throwsStateError);
  });

  test('remote catalog forwards suggestions and cancellation token', () async {
    final oneApi = AsmrApiService();
    final earaApi = _SuggestionsApi();
    addTearDown(oneApi.close);
    addTearDown(earaApi.close);
    final catalog = AsmrRemoteCatalogService(
      apiService: oneApi,
      persistenceRepository: _UnusedPersistence(),
      japaneseApiService: earaApi,
    );
    final token = AsmrRequestCancellationToken();
    final result = await catalog.loadSearchSuggestions(
      cancellationToken: token,
    );
    expect(earaApi.token, same(token));
    expect(result.voiceActors, ['Voice']);
    expect(result.tags, ['Sleep']);
  });

  test(
    'suggestions preserve server order, trim, deduplicate and cap at 30',
    () {
      final suggestions = AsmrSearchSuggestions.fromJson({
        'hotCvs': [
          {'value': ' Voice ', 'count': 2, 'rank': 1},
          {'value': 'Voice', 'count': 5, 'rank': 2},
          for (var i = 1; i <= 40; i++) {'value': 'Voice$i', 'count': 100},
        ],
        'hotTags': [
          {'value': ' Sleep ', 'count': 2},
          {'value': 'Other', 'count': 100},
        ],
      });
      expect(suggestions.voiceActors, [
        'Voice',
        for (var i = 1; i < 30; i++) 'Voice$i',
      ]);
      expect(suggestions.tags, ['Sleep', 'Other']);
      expect(() => suggestions.tags.add('new'), throwsUnsupportedError);
      final restored = AsmrSearchSuggestions.fromJson(suggestions.toJson());
      expect(restored.voiceActors, suggestions.voiceActors);
      expect(restored.tags, suggestions.tags);
    },
  );

  test('constructor copies its input and accepts empty suggestions', () {
    final input = [' Voice ', 'Voice', ''];
    final suggestions = AsmrSearchSuggestions(voiceActors: input, tags: []);
    input.add('Later');
    expect(suggestions.voiceActors, ['Voice']);
    expect(suggestions.tags, isEmpty);
    final empty = AsmrSearchSuggestions.fromJson({
      'hotCvs': <dynamic>[],
      'hotTags': <dynamic>[],
    });
    expect(empty.voiceActors, isEmpty);
    expect(empty.tags, isEmpty);
  });

  test('missing lists and malformed suggestion values are rejected', () {
    for (final payload in <Map<String, dynamic>>[
      {},
      {'hotCvs': <dynamic>[], 'hotTags': null},
      {'hotCvs': <String, dynamic>{}, 'hotTags': <dynamic>[]},
      {
        'hotCvs': ['Voice'],
        'hotTags': <dynamic>[],
      },
      {
        'hotCvs': [
          {'value': 2},
        ],
        'hotTags': <dynamic>[],
      },
      {
        'hotCvs': <dynamic>[],
        'hotTags': [
          {'value': ' '},
        ],
      },
    ]) {
      expect(
        () => AsmrSearchSuggestions.fromJson(payload),
        throwsFormatException,
      );
    }
  });

  test(
    'hot suggestions use the public Eara endpoint without credentials',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(request.method, 'GET');
        expect(request.uri.path, '/api/search-suggestions');
        expect(request.uri.queryParameters, isEmpty);
        expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
        expect(
          request.headers.value('X-Listen-Together-Device-Fingerprint'),
          isNull,
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'hotCvs': [
              {'value': 'Voice', 'count': 20, 'rank': 1},
            ],
            'hotTags': [
              {'value': 'Sleep', 'count': 30, 'rank': 1},
            ],
            'hotWorks': <dynamic>[],
            'serverTimeEpochMs': 1792790000000,
          }),
        );
        await request.response.close();
      });
      final api = JapaneseAsmrApiService(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}/'),
      );
      addTearDown(api.close);
      final result = await api.fetchSearchSuggestions();
      expect(result.voiceActors, ['Voice']);
      expect(result.tags, ['Sleep']);
    },
  );

  test('cancelled suggestions abort an unfinished response', () async {
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
    final pending = api.fetchSearchSuggestions(cancellationToken: token);
    final assertion = expectLater(
      pending,
      throwsA(isA<AsmrRequestCancelled>()),
    );
    await opened.future;
    token.cancel();
    await assertion;
  });

  test('API rejects a malformed response root', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('[]');
      await request.response.close();
    });
    final api = JapaneseAsmrApiService(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}/'),
    );
    addTearDown(api.close);
    await expectLater(api.fetchSearchSuggestions(), throwsFormatException);
  });
}

class _UnusedPersistence implements AsmrPersistenceRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SuggestionsApi extends JapaneseAsmrApiService {
  AsmrRequestCancellationToken? token;

  @override
  Future<AsmrSearchSuggestions> fetchSearchSuggestions({
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    token = cancellationToken;
    return AsmrSearchSuggestions(voiceActors: ['Voice'], tags: ['Sleep']);
  }
}
