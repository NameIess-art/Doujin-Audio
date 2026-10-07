import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:doujin_audio/core/persistence/json_document_store.dart';
import 'package:doujin_audio/core/translation/text_translation_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late _Documents documents;
  late TextTranslationService service;
  late Future<void> Function(HttpRequest) handler;
  var requests = 0;
  var clock = DateTime.utc(2026, 10, 7);

  Future<List<String>> sources(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    return Uri(query: body).queryParametersAll['q']!;
  }

  Future<void> respond(HttpRequest request, Object value) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(value));
    await request.response.close();
  }

  TextTranslationService createService({
    Duration interval = Duration.zero,
    int memoryCapacity = 1000,
    int diskCapacity = 3000,
    Future<Directory> Function()? directory,
    HttpClient Function()? clientFactory,
    DateTime Function()? now,
    Duration requestTimeout = const Duration(seconds: 20),
  }) => TextTranslationService(
    endpoint: Uri.parse('http://127.0.0.1:${server.port}/translate_a/t'),
    documentStore: documents,
    temporaryDirectory: directory ?? () async => Directory.systemTemp,
    now: now ?? () => clock,
    clientFactory: clientFactory,
    requestTimeout: requestTimeout,
    requestInterval: interval,
    memoryCapacity: memoryCapacity,
    diskCapacity: diskCapacity,
  );

  Future<TextTranslationResult> translate(
    List<String> texts, {
    String target = 'zh-CN',
    String source = 'auto',
    TextTranslationRequest? request,
  }) => service.translate(
    texts,
    target: target,
    source: source,
    request: request ?? service.newRequest(),
  );

  setUp(() async {
    requests = 0;
    clock = DateTime.utc(2026, 10, 7);
    documents = _Documents();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    handler = (request) async {
      final texts = await sources(request);
      await respond(request, texts.map((text) => 'translated $text').toList());
    };
    server.listen((request) async {
      requests++;
      try {
        await handler(request);
      } on IOException {
        // Cancellation closes the socket before a delayed test reply is sent.
      }
    });
    service = createService();
  });

  tearDown(() async {
    service.dispose();
    await server.close(force: true);
  });

  test(
    'construction, lookup and disposal do not access platform or network',
    () {
      var directoryCalls = 0;
      final lazy = createService(
        directory: () async {
          directoryCalls++;
          throw StateError('must stay lazy');
        },
      );
      expect(lazy.cached('title', 'ja'), isNull);
      lazy.dispose();
      expect(directoryCalls, 0);
      expect(requests, 0);
    },
  );

  test(
    'posts repeated form q fields with auto detection and maps both shapes',
    () async {
      handler = (request) async {
        expect(request.method, 'POST');
        expect(request.uri.path, '/translate_a/t');
        expect(request.uri.queryParameters, {
          'client': 'dict-chrome-ex',
          'sl': 'auto',
          'tl': 'zh-CN',
        });
        expect(
          request.headers.contentType?.mimeType,
          'application/x-www-form-urlencoded',
        );
        expect(await sources(request), ['a & b+?', '\u8033\u304b\u304d']);
        await respond(request, [
          'translated',
          ['\u638f\u8033', 'ja'],
        ]);
      };
      final result = await translate([
        'a & b+?',
        '\u8033\u304b\u304d',
        'a & b+?',
        'RJ123456',
        '123',
        ' ',
      ]);
      expect(result.failure, isNull);
      expect(result.translations, {
        'a & b+?': 'translated',
        '\u8033\u304b\u304d': '\u638f\u8033',
      });
      expect(requests, 1);
    },
  );

  test(
    'explicit source language is sent without automatic detection',
    () async {
      handler = (request) async {
        expect(request.uri.queryParameters['sl'], 'ja');
        expect(request.uri.queryParameters['tl'], 'en');
        expect(await sources(request), ['\u8033\u304b\u304d']);
        await respond(request, ['ear cleaning']);
      };
      final result = await translate(
        ['\u8033\u304b\u304d'],
        source: 'ja',
        target: 'en',
      );
      expect(result.failure, isNull);
      expect(result.translations, {'\u8033\u304b\u304d': 'ear cleaning'});
      expect(requests, 1);
    },
  );

  test(
    'source languages use independent memory and disk cache entries',
    () async {
      handler = (request) async {
        final language = request.uri.queryParameters['sl'];
        await respond(request, ['translated from $language']);
      };
      await translate(['title']);
      expect(service.cached('title', 'zh-CN', source: 'ja'), isNull);
      await translate(['title'], source: 'ja');
      expect(service.cached('title', 'zh-CN'), 'translated from auto');
      expect(
        service.cached('title', 'zh-CN', source: 'ja'),
        'translated from ja',
      );
      await translate(['title']);
      await translate(['title'], source: 'ja');
      expect(requests, 2);
      await documents.waitForWrites(2);
      final saved = jsonDecode(utf8.decode(documents.bytes!)) as Map;
      expect(saved['version'], 2);
      expect(saved['entries'], [
        ['zh-CN', 'auto', 'title', 'translated from auto'],
        ['zh-CN', 'ja', 'title', 'translated from ja'],
      ]);
      service.dispose();
      service = createService();
      expect(
        (await translate(['title'])).translations['title'],
        'translated from auto',
      );
      expect(
        (await translate(['title'], source: 'ja')).translations['title'],
        'translated from ja',
      );
      expect(requests, 2);
    },
  );

  test('version 1 cache is discarded and translated again', () async {
    documents.bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 1,
          'entries': [
            ['zh-CN', 'title', 'old translation'],
          ],
        }),
      ),
    );
    final result = await translate(['title']);
    expect(result.translations, {'title': 'translated title'});
    expect(requests, 1);
    await documents.waitForWrites(1);
    final saved = jsonDecode(utf8.decode(documents.bytes!)) as Map;
    expect(saved['version'], 2);
    expect(saved['entries'], [
      ['zh-CN', 'auto', 'title', 'translated title'],
    ]);
  });

  test('file labels retain supported extensions and numbers are skipped', () {
    for (final suffix in ['.WAV', '.md', '.ssa', '.m4v', '.3gp']) {
      final parts = textTranslationText('track$suffix', fileName: true);
      expect(parts, (source: 'track', suffix: suffix));
      expect('translated${parts.suffix}', 'translated$suffix');
    }
    expect(textTranslationText('track.wav'), (source: 'track.wav', suffix: ''));
    expect(
      textTranslationText('title.ending', fileName: true).source,
      'title.ending',
    );
    for (final text in [
      '',
      ' \n',
      '123.45',
      '---',
      'RJ123',
      'bj123',
      'VJ123',
    ]) {
      expect(canTranslateText(text), isFalse, reason: text);
    }
    expect(canTranslateText('\u8033\u304b\u304d'), isTrue);
    expect(canTranslateText('RJ123 title'), isTrue);
  });

  test('batches cap item count and UTF-16 length without splitting text', () {
    final items = List.generate(51, (index) => 'title $index');
    expect(textTranslationBatches(items).map((batch) => batch.length), [50, 1]);
    final surrogateText = '\u{1F600}' * 1999;
    expect(surrogateText.length, 3998);
    expect(
      textTranslationBatches([
        surrogateText,
        'ab',
        'c',
      ]).map((batch) => batch.length),
      [2, 1],
    );
    expect(textTranslationBatches([]), isEmpty);
    expect(() => textTranslationBatches(['x' * 4001]), throwsArgumentError);
    expect(canTranslateText('x' * 4001), isFalse);
  });

  test('document segments preserve lines, whitespace and stable prefixes', () {
    const text = '  First line  \r\n\r\nSecond line\n\tThird line\t';
    final segments = textTranslationSegments(text);
    expect(segments.join(), text);
    expect(segments.where(canTranslateText), [
      'First line',
      'Second line',
      'Third line',
    ]);
    expect(
      textTranslationSegments('$text\nNext line').take(segments.length),
      segments,
    );
    expect(textTranslationSegments('').join(), '');
  });

  test(
    'document segments cap long lines without splitting surrogate pairs',
    () {
      final text = '${'x' * 3999}\u{1F600}${'y' * 4100}\n';
      final segments = textTranslationSegments(text);
      expect(segments.join(), text);
      for (final segment in segments) {
        expect(segment.length, lessThanOrEqualTo(4000));
        expect(utf8.decode(utf8.encode(segment)), segment);
      }
    },
  );

  for (final invalid in <List<Object?>>[
    [],
    ['only one'],
    ['ok', 1],
    ['ok', ' '],
    [
      'ok',
      ['bad', 1],
    ],
    [
      'ok',
      ['bad', 'ja', 'extra'],
    ],
  ]) {
    test(
      'rejects invalid batch response $invalid without partial mapping',
      () async {
        handler = (request) => respond(request, invalid);
        final result = await translate(['first', 'second']);
        expect(result.failure, TextTranslationFailure.invalidResponse);
        expect(result.translations, isEmpty);
        expect(service.cached('first', 'zh-CN'), isNull);
        expect(requests, 1);
      },
    );
  }

  test('keeps earlier successful batches when a later batch fails', () async {
    handler = (request) async {
      final texts = await sources(request);
      if (requests == 2) {
        request.response.statusCode = 503;
        await request.response.close();
      } else {
        await respond(
          request,
          texts.map((text) => 'translated $text').toList(),
        );
      }
    };
    final result = await translate(
      List.generate(51, (index) => 'title $index'),
    );
    expect(result.failure, TextTranslationFailure.unavailable);
    expect(result.translations.length, 50);
    expect(service.cached('title 0', 'zh-CN'), 'translated title 0');
    expect(service.cached('title 50', 'zh-CN'), isNull);
    expect(requests, 2);
  });

  test(
    'memory cache separates target languages and disk survives service recreation',
    () async {
      await translate(['title']);
      await translate(['title']);
      expect(requests, 1);
      await translate(['title'], target: 'ja');
      expect(requests, 2);
      await documents.waitForWrites(2);
      service.dispose();
      service = createService();
      final cached = await translate(['title']);
      expect(cached.translations['title'], 'translated title');
      expect(requests, 2);
      expect(documents.lastLocation?.name, 'cache.json');
      expect(
        documents.lastLocation?.basePath,
        endsWith(textTranslationCacheDirectoryName),
      );
    },
  );

  test(
    'memory LRU evicts the least used text and disk stays within its cap',
    () async {
      service.dispose();
      service = createService(memoryCapacity: 2, diskCapacity: 3);
      await translate(['first', 'second']);
      expect(service.cached('first', 'zh-CN'), isNotNull);
      await translate(['third']);
      expect(service.cached('second', 'zh-CN'), isNull);
      expect(service.cached('first', 'zh-CN'), isNotNull);
      await translate(['fourth']);
      await documents.waitForWrites(3);
      final saved = jsonDecode(utf8.decode(documents.bytes!)) as Map;
      expect((saved['entries'] as List).length, 3);
      service.dispose();
      service = createService(memoryCapacity: 2, diskCapacity: 3);
      await translate(['second']);
      expect(requests, 4);
    },
  );

  for (final status in [429, 403]) {
    test(
      'HTTP $status cools down for at least a minute and respects Retry-After',
      () async {
        handler = (request) async {
          if (requests == 1) {
            request.response.statusCode = status;
            request.response.headers.set(HttpHeaders.retryAfterHeader, '120');
            await request.response.close();
          } else {
            await respond(request, ['success']);
          }
        };
        expect(
          (await translate(['title'])).failure,
          TextTranslationFailure.rateLimited,
        );
        clock = clock.add(const Duration(seconds: 61));
        expect(
          (await translate(['title'])).failure,
          TextTranslationFailure.rateLimited,
        );
        expect(requests, 1);
        clock = clock.add(const Duration(seconds: 60));
        expect((await translate(['title'])).translations, {'title': 'success'});
        expect(requests, 2);
      },
    );
  }

  test(
    'unusual traffic blocks requests for five minutes and accepts HTTP-date Retry-After',
    () async {
      handler = (request) async {
        if (requests == 1) {
          request.response.statusCode = 403;
          request.response.headers.set(
            HttpHeaders.retryAfterHeader,
            HttpDate.format(clock.add(const Duration(seconds: 20))),
          );
          request.response.write('Our systems detected Unusual Traffic');
          await request.response.close();
        } else {
          await respond(request, ['success']);
        }
      };
      expect(
        (await translate(['title'])).failure,
        TextTranslationFailure.unusualTraffic,
      );
      clock = clock.add(const Duration(minutes: 4));
      expect(
        (await translate(['title'])).failure,
        TextTranslationFailure.unusualTraffic,
      );
      expect(requests, 1);
      clock = clock.add(const Duration(minutes: 1));
      expect((await translate(['title'])).failure, isNull);
      expect(requests, 2);
    },
  );

  test(
    'cancels pending network and ignores late response and cache mutation',
    () async {
      final received = Completer<void>();
      final release = Completer<void>();
      handler = (request) async {
        await sources(request);
        received.complete();
        await release.future;
        await respond(request, ['late']);
      };
      final request = service.newRequest();
      final pending = translate(['title'], request: request);
      await received.future;
      request.cancel();
      final result = await pending.timeout(const Duration(seconds: 1));
      expect(request.cancelled, isTrue);
      expect(result.failure, isNull);
      expect(result.translations, isEmpty);
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(service.cached('title', 'zh-CN'), isNull);
      expect(documents.writes, 0);
    },
  );

  test(
    'serializes calls and cancellation interrupts the inter-request wait',
    () async {
      service.dispose();
      service = createService(interval: const Duration(milliseconds: 250));
      await translate(['first']);
      final request = service.newRequest();
      final pending = translate(['second'], request: request);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      request.cancel();
      expect((await pending).failure, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 270));
      expect(requests, 1);
    },
  );

  test(
    'queues simultaneous calls and deduplicates after the first completes',
    () async {
      final received = Completer<void>();
      final release = Completer<void>();
      handler = (request) async {
        received.complete();
        await release.future;
        await respond(request, ['success']);
      };
      final first = translate(['same']);
      await received.future;
      final second = translate(['same']);
      release.complete();
      expect((await first).translations, {'same': 'success'});
      expect((await second).translations, {'same': 'success'});
      expect(requests, 1);
    },
  );

  test('cache write failures preserve successful translations', () async {
    documents.failWrites = true;
    final result = await translate(['title']);
    expect(result.failure, isNull);
    expect(result.translations, {'title': 'translated title'});
    await documents.waitForWrites(1);
    expect(service.cached('title', 'zh-CN'), 'translated title');
  });

  test(
    'clear cancels active requests and prevents stale writes recreating cache',
    () async {
      await translate(['saved']);
      await documents.waitForWrites(1);
      final received = Completer<void>();
      final release = Completer<void>();
      handler = (request) async {
        received.complete();
        await release.future;
        await respond(request, ['late']);
      };
      final request = service.newRequest();
      final pending = translate(['pending'], request: request);
      await received.future;
      await service.clearCache();
      expect(request.cancelled, isTrue);
      expect((await pending).failure, isNull);
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.cached('saved', 'zh-CN'), isNull);
      expect(service.cached('pending', 'zh-CN'), isNull);
      expect(documents.bytes, isNull);
    },
  );
  test(
    'normal translations mentioning unusual traffic are not blocked',
    () async {
      handler = (request) => respond(request, ['Unusual traffic']);
      final result = await translate(['title']);
      expect(result.failure, isNull);
      expect(result.translations, {'title': 'Unusual traffic'});
    },
  );

  test('short Retry-After cannot shorten the one-minute cooldown', () async {
    handler = (request) async {
      if (requests == 1) {
        request.response.statusCode = 429;
        request.response.headers.set(HttpHeaders.retryAfterHeader, '1');
        await request.response.close();
      } else {
        await respond(request, ['success']);
      }
    };
    expect(
      (await translate(['title'])).failure,
      TextTranslationFailure.rateLimited,
    );
    clock = clock.add(const Duration(seconds: 59));
    expect(
      (await translate(['title'])).failure,
      TextTranslationFailure.rateLimited,
    );
    expect(requests, 1);
    clock = clock.add(const Duration(seconds: 1));
    expect((await translate(['title'])).failure, isNull);
    expect(requests, 2);
  });

  test(
    'slow replies still leave 250ms between completion and next request',
    () async {
      service.dispose();
      service = createService(
        interval: const Duration(milliseconds: 250),
        now: DateTime.now,
      );
      final elapsed = Stopwatch()..start();
      var firstCompleted = Duration.zero;
      var secondReceived = Duration.zero;
      handler = (request) async {
        if (requests == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          await respond(request, ['first translated']);
          firstCompleted = elapsed.elapsed;
        } else {
          secondReceived = elapsed.elapsed;
          await respond(request, ['second translated']);
        }
      };
      final first = translate(['first']);
      final second = translate(['second']);
      await first;
      await second;
      expect(
        secondReceived - firstCompleted,
        greaterThanOrEqualTo(const Duration(milliseconds: 240)),
      );
    },
  );

  test(
    'unexpected caller failure does not poison later queued requests',
    () async {
      service.dispose();
      var factories = 0;
      service = createService(
        clientFactory: () {
          if (factories++ == 0) throw StateError('test factory failure');
          return HttpClient();
        },
      );
      await expectLater(translate(['first']), throwsStateError);
      expect((await translate(['second'])).failure, isNull);
      expect(requests, 1);
    },
  );

  test(
    'invalid UTF-8 response is classified without caching the batch',
    () async {
      handler = (request) async {
        request.response.add([0xff]);
        await request.response.close();
      };
      expect(
        (await translate(['title'])).failure,
        TextTranslationFailure.invalidResponse,
      );
      expect(service.cached('title', 'zh-CN'), isNull);
    },
  );

  test('network timeout returns unavailable and does not retry', () async {
    service.dispose();
    service = createService(requestTimeout: const Duration(milliseconds: 50));
    final release = Completer<void>();
    handler = (request) async {
      await release.future;
      await respond(request, ['late']);
    };
    expect(
      (await translate(['title'])).failure,
      TextTranslationFailure.unavailable,
    );
    release.complete();
    expect(requests, 1);
  });

  test(
    'clear waits for a disk write already in progress before deleting',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      documents.writeStarted = started;
      documents.writeDelay = release.future;
      await translate(['title']);
      await started.future;
      final clearing = service.clearCache();
      release.complete();
      await clearing;
      expect(documents.bytes, isNull);
      expect(service.cached('title', 'zh-CN'), isNull);
    },
  );
  test(
    'requests created during clear start after its barrier and cannot reload old cache',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      documents.writeStarted = started;
      documents.writeDelay = release.future;
      await translate(['title']);
      await started.future;
      final clearing = service.clearCache();
      final afterClear = translate(['title']);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(requests, 1);
      release.complete();
      await clearing;
      expect((await afterClear).translations, {'title': 'translated title'});
      expect(requests, 2);
    },
  );
}

class _Documents implements JsonDocumentStore {
  Uint8List? bytes;
  JsonDocumentLocation? lastLocation;
  var writes = 0;
  var failWrites = false;
  Completer<void>? writeStarted;
  Future<void>? writeDelay;

  Future<void> waitForWrites(int count) async {
    for (var index = 0; index < 100 && writes < count; index++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(writes, greaterThanOrEqualTo(count));
  }

  @override
  Future<JsonDocumentReadResult> read(JsonDocumentLocation location) async {
    lastLocation = location;
    final value = bytes;
    return value == null
        ? const JsonDocumentReadResult.missing()
        : JsonDocumentReadResult.found(
            JsonDocumentSnapshot(bytes: value, revision: '$writes'),
          );
  }

  @override
  Future<JsonDocumentWriteResult> write({
    required JsonDocumentLocation location,
    required Uint8List bytes,
    required JsonDocumentWriteMode mode,
    String? expectedRevision,
  }) async {
    if (writeStarted != null && !writeStarted!.isCompleted) {
      writeStarted!.complete();
    }
    final delay = writeDelay;
    if (delay != null) await delay;
    writes++;
    if (failWrites) throw const FileSystemException('test write failure');
    this.bytes = bytes;
    return JsonDocumentWriteResult(
      status: JsonDocumentWriteStatus.created,
      revision: '$writes',
    );
  }

  @override
  Future<JsonDocumentDeleteResult> delete({
    required JsonDocumentLocation location,
    required String expectedRevision,
  }) async {
    bytes = null;
    return const JsonDocumentDeleteResult(
      status: JsonDocumentDeleteStatus.deleted,
    );
  }
}
