import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';

void main() {
  test(
    'complete voice directory retains UUIDs and multilingual names',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        expect(request.uri.path, '/api/vas/');
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode([
            {
              'id': 'c75838bb-1c4d-5850-8a93-b9a56593d511',
              'name': '声優',
              'i18n': {
                'en-us': {'name': 'Voice Actor'},
              },
              'count': 1,
            },
          ]),
        );
        await request.response.close();
      });
      final service = AsmrApiService(
        baseUri: Uri.parse('http://${server.address.address}:${server.port}'),
      );
      try {
        final voices = await service.fetchVoiceActorCatalog();
        expect(
          voices.single.key,
          'online:c75838bb-1c4d-5850-8a93-b9a56593d511',
        );
        expect(voices.single.aliases, containsAll(['声優', 'Voice Actor']));
      } finally {
        service.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );
  test(
    'complete tag directory keeps stable ids and all language aliases',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        expect(request.uri.path, '/api/tags/');
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode([
            {
              'id': 509,
              'name': '3D作品',
              'i18n': {
                'en-us': {'name': '3D Works'},
                'ja-jp': {'name': '3D作品'},
                'zh-cn': {'name': '3D作品'},
              },
              'count': 37,
            },
          ]),
        );
        await request.response.close();
      });
      final service = AsmrApiService(
        baseUri: Uri.parse('http://${server.address.address}:${server.port}'),
      );
      try {
        final tags = await service.fetchTagCatalog();
        expect(tags.single.key, 'online:509');
        expect(tags.single.onlineId, 509);
        expect(tags.single.aliases, containsAll(['3D作品', '3D Works']));
      } finally {
        service.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'tag directory rejects partial envelopes instead of marking complete',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"tags":[],"pagination":{"hasMore":true}}');
        await request.response.close();
      });
      final service = AsmrApiService(
        baseUri: Uri.parse('http://${server.address.address}:${server.port}'),
      );
      try {
        await expectLater(service.fetchTagCatalog(), throwsFormatException);
      } finally {
        service.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'cancelled requests abort an openUrl result that arrives late',
    () async {
      final client = _PendingOpenClient();
      final service = AsmrApiService(httpClient: client);
      final token = AsmrRequestCancellationToken();
      final loading = service.fetchWorks(
        order: 'release',
        sort: 'desc',
        cancellationToken: token,
      );
      final cancelled = expectLater(
        loading,
        throwsA(isA<AsmrRequestCancelled>()),
      );
      token.cancel();
      await cancelled;
      final request = _AbortTrackingRequest();
      client.opened.complete(request);
      await Future<void>.delayed(Duration.zero);
      expect(request.aborted, isTrue);
      expect(client.openCount, 1);
      service.close();
    },
  );

  test('already cancelled requests do not open a connection', () async {
    final client = _PendingOpenClient();
    final service = AsmrApiService(httpClient: client);
    final token = AsmrRequestCancellationToken()..cancel();
    await expectLater(
      service.searchWorks(
        keyword: 'old',
        order: 'release',
        sort: 'desc',
        cancellationToken: token,
      ),
      throwsA(isA<AsmrRequestCancelled>()),
    );
    expect(client.openCount, 0);
    service.close();
  });

  for (final operation in ['search', 'review', 'tree']) {
    for (final readingBody in [false, true]) {
      test(
        '$operation cancellation stops ${readingBody ? 'body reading' : 'header waiting'} without domain failover',
        () async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final started = Completer<void>();
          var cancelledRequests = 0;
          final path = switch (operation) {
            'review' => '/api/review',
            'tree' => '/api/tracks/72',
            _ => '/api/search/',
          };
          final subscription = server.listen((request) async {
            if (request.uri.path == path) {
              cancelledRequests++;
              if (readingBody) {
                request.response.headers.contentType = ContentType.json;
                request.response.write(
                  operation == 'tree' ? '[' : '{"works":[',
                );
                await request.response.flush();
              }
              started.complete();
              return;
            }
            request.response.write(
              '{"works":[],"pagination":{"currentPage":1,"pageSize":40,"totalCount":0}}',
            );
            await request.response.close();
          });
          final hosts = <String>[];
          final client = HttpClient()
            ..findProxy = (uri) {
              hosts.add(uri.host);
              return 'DIRECT';
            };
          final service = AsmrApiService(
            httpClient: client,
            baseUri: Uri.parse(
              'http://${server.address.address}:${server.port}',
            ),
          );
          try {
            final token = AsmrRequestCancellationToken();
            final loading = switch (operation) {
              'review' => service.fetchReviews(
                token: 'test-token',
                cancellationToken: token,
              ),
              'tree' => service.fetchTrackTree(72, cancellationToken: token),
              _ => service.searchWorks(
                keyword: 'old',
                order: 'release',
                sort: 'desc',
                cancellationToken: token,
              ),
            };
            final cancelled = expectLater(
              loading,
              throwsA(isA<AsmrRequestCancelled>()),
            );
            await started.future;
            token.cancel();
            await cancelled.timeout(const Duration(seconds: 2));
            final sibling = await service.fetchWorks(
              order: 'release',
              sort: 'desc',
            );
            expect(sibling.works, isEmpty);
            expect(cancelledRequests, 1);
            expect(hosts, everyElement(server.address.address));
            expect(service.isClosed, isFalse);
          } finally {
            service.close();
            await subscription.cancel();
            await server.close(force: true);
          }
        },
      );
    }
  }

  test(
    'cancellation consumes a task error that arrives after cancellation',
    () async {
      final token = AsmrRequestCancellationToken();
      final task = Completer<void>();
      final cancelled = expectLater(
        token.waitFor(task.future),
        throwsA(isA<AsmrRequestCancelled>()),
      );
      token.cancel();
      token.cancel();
      await cancelled;
      task.completeError(const SocketException('late error'));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'background decoding preserves localized pages and nested tracks',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        final Object payload = request.uri.path.startsWith('/api/tracks/')
            ? [
                {
                  'title': '中文 folder',
                  'type': 'folder',
                  'children': [
                    {
                      'title': '音声 10.mp3',
                      'type': 'audio',
                      'hash': 'voice',
                      'duration': 1.25,
                      'size': 4096,
                      'mediaStreamUrl': 'https://example.test/voice.mp3',
                      'work': {'id': 72, 'source_id': 'RJ123456'},
                    },
                  ],
                },
              ]
            : {
                'works': [
                  {
                    'id': 72,
                    'title': 'Fallback',
                    'progress': 'marked',
                    'updated_at': '2026-10-18T08:30:00Z',
                    'i18n': {
                      'zh-cn': {'title': '中文标题'},
                      'ja-jp': {'title': '日本語'},
                      'en-us': {'title': 'English'},
                    },
                  },
                ],
                'pagination': {
                  'currentPage': 1,
                  'pageSize': 1,
                  'totalCount': 1,
                },
              };
        request.response.write(jsonEncode(payload));
        await request.response.close();
      });
      final service = AsmrApiService(
        baseUri: Uri.parse('http://${server.address.address}:${server.port}'),
      );
      try {
        for (final (language, title) in [
          (AsmrContentLanguage.zh, '中文标题'),
          (AsmrContentLanguage.ja, '日本語'),
          (AsmrContentLanguage.en, 'English'),
        ]) {
          final page = await service.fetchWorks(
            order: 'release',
            sort: 'desc',
            language: language,
          );
          final search = await service.searchWorks(
            keyword: 'voice',
            order: 'release',
            sort: 'desc',
            language: language,
          );
          final reviews = await service.fetchReviews(
            token: 'token',
            language: language,
          );
          expect(page.works.single.title, title);
          expect(search.works.single.title, title);
          expect(reviews.single.work.title, title);
          expect(reviews.single.progress, 'marked');
          expect(reviews.single.updatedAt, DateTime.utc(2026, 10, 18, 8, 30));
        }
        final tree = await service.fetchTrackTree(72);
        final track = tree.single.children.single;
        expect(track.relativePath, '中文 folder/音声 10.mp3');
        expect(track.duration, const Duration(milliseconds: 1250));
        expect(track.size, 4096);
        expect(track.workId, 72);
        expect(track.sourceId, 'RJ123456');
        expect(track.streamUrl, 'https://example.test/voice.mp3');
      } finally {
        service.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'page and review model errors do not trigger endpoint failover',
    () async {
      var payload = '[]';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(payload);
        await request.response.close();
      });
      final client = HttpClient();
      final hosts = <String>[];
      client.findProxy = (uri) {
        hosts.add(uri.host);
        return 'DIRECT';
      };
      final service = AsmrApiService(
        httpClient: client,
        baseUri: Uri.parse('http://${server.address.address}:${server.port}'),
      );
      try {
        for (final request in <Future<Object> Function()>[
          () => service.fetchWorks(order: 'release', sort: 'desc'),
          () => service.searchWorks(
            keyword: 'voice',
            order: 'release',
            sort: 'desc',
          ),
          () => service.fetchReviews(token: 'token'),
        ]) {
          payload = '[]';
          await expectLater(request(), throwsA(isA<HttpException>()));
          payload = '{"works":[{"id":1,"sourceId":42}]}';
          await expectLater(request(), throwsA(isA<TypeError>()));
          payload = '{"works":[{"title":"invalid duration","duration":1e400}]}';
          await expectLater(request(), throwsA(isA<UnsupportedError>()));
        }
        expect(hosts, everyElement(server.address.address));
      } finally {
        service.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'track decoding retains shape and model field errors without failover',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(switch (request.uri.path) {
          '/api/tracks/1' => '{"unexpected":true}',
          '/api/tracks/2' => '[{"title":42}]',
          _ => '[{"title":"invalid duration","duration":1e400}]',
        });
        await request.response.close();
      });
      final client = HttpClient();
      final hosts = <String>[];
      client.findProxy = (uri) {
        hosts.add(uri.host);
        return 'DIRECT';
      };
      final service = AsmrApiService(
        httpClient: client,
        baseUri: Uri.parse('http://${server.address.address}:${server.port}'),
      );
      try {
        await expectLater(
          service.fetchTrackTree(1),
          throwsA(
            isA<HttpException>().having(
              (error) => error.message,
              'message',
              'Unexpected API response list.',
            ),
          ),
        );
        await expectLater(service.fetchTrackTree(2), throwsA(isA<TypeError>()));
        await expectLater(
          service.fetchTrackTree(3),
          throwsA(isA<UnsupportedError>()),
        );
        expect(hosts, everyElement(server.address.address));
      } finally {
        service.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test('official media hashes use API redirect endpoints before raw URLs', () {
    expect(
      AsmrApiService.mediaStreamUrlsForHash('1583603/1853944').first,
      'https://api.asmr-300.com/api/media/stream/1583603/1853944',
    );
    expect(
      AsmrApiService.mediaDownloadUrlsForHash('1583603/1853944').first,
      'https://api.asmr-300.com/api/media/download/1583603/1853944',
    );
    expect(
      AsmrApiService.isOfficialMediaUrl(
        'https://raw.kiko-play-niptan.one/media/stream/file.mp3',
      ),
      isTrue,
    );
    expect(AsmrApiService.mediaStreamUrlsForHash('../file'), isEmpty);
  });

  test(
    'ASMR API requests include the language accepted by the gateway',
    () async {
      final language = Completer<String?>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        language.complete(
          request.headers.value(HttpHeaders.acceptLanguageHeader),
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            'works': const <Object?>[],
            'pagination': const <String, Object?>{
              'currentPage': 1,
              'pageSize': 1,
              'totalCount': 0,
            },
          }),
        );
        await request.response.close();
      });

      try {
        final service = AsmrApiService(
          baseUri: Uri.parse('http://${server.address.address}:${server.port}'),
        );

        await service.fetchWorks(order: 'release', sort: 'desc', pageSize: 1);

        expect(await language.future, 'zh-CN,zh;q=0.9,en;q=0.8');
      } finally {
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test('ASMR API errors do not expose an HTML rejection page', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.headers.contentType = ContentType.html;
      request.response.write('<!doctype html><html>gateway rejection</html>');
      await request.response.close();
    });

    try {
      final service = AsmrApiService(
        baseUri: Uri.parse('http://${server.address.address}:${server.port}'),
      );

      await expectLater(
        service.fetchWorks(order: 'release', sort: 'desc'),
        throwsA(
          isA<AsmrApiException>()
              .having((error) => error.statusCode, 'statusCode', 403)
              .having(
                (error) => error.message,
                'message',
                allOf(contains('(403)'), isNot(contains('<html>'))),
              ),
        ),
      );
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}

class _PendingOpenClient extends Fake implements HttpClient {
  final opened = Completer<HttpClientRequest>();
  int openCount = 0;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    openCount++;
    return opened.future;
  }

  @override
  void close({bool force = false}) {}
}

class _AbortTrackingRequest extends Fake implements HttpClientRequest {
  bool aborted = false;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
  }
}
