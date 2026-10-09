import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/asmr/application/asmr_playback_cache_service.dart';

void main() {
  for (final testCase
      in <({int status, int length, int? expected, bool success})>[
        (status: 200, length: 3, expected: 3, success: true),
        (status: 200, length: 4, expected: null, success: false),
        (status: 200, length: 2, expected: null, success: false),
        (status: 206, length: 3, expected: 3, success: false),
        (status: 200, length: -1, expected: null, success: true),
        (status: 200, length: -1, expected: 4, success: false),
      ]) {
    test('cache verifies EOF and lengths $testCase', () async {
      final directory = await Directory.systemTemp.createTemp('cache_length_');
      final client = _StreamClient(
        Stream.value([1, 2, 3]),
        status: testCase.status,
        length: testCase.length,
      );
      final service = AsmrPlaybackCacheService(
        temporaryDirectory: () async => directory,
        httpClientFactory: () => client,
      );
      addTearDown(() async {
        await service.dispose();
        await directory.delete(recursive: true);
      });
      const url = 'https://example.test/audio.mp3';
      final result = await service.cacheTrack(
        _track(
          url,
          fileSizeBytes: testCase.expected,
          remoteMetadata: {
            'fullQualityPlaybackUrls': [url],
          },
        ),
      );
      expect(result != null, testCase.success);
      expect(client.autoUncompress, isFalse);
      expect(
        client.request.headers.value(HttpHeaders.acceptEncodingHeader),
        'identity',
      );
      final files = await Directory(
        '${directory.path}/${AsmrPlaybackCacheService.cacheDirectoryName}',
      ).list().toList();
      expect(files.where((file) => file.path.endsWith('.part')), isEmpty);
      if (testCase.success) {
        expect(result, contains('v2-'));
        expect(await File(result!).readAsBytes(), [1, 2, 3]);
      } else {
        expect(files, isEmpty);
      }
    });
  }

  test(
    'low quality and old metadata use response size, not original size',
    () async {
      final directory = await Directory.systemTemp.createTemp('cache_quality_');
      final service = AsmrPlaybackCacheService(
        temporaryDirectory: () async => directory,
        httpClientFactory: () =>
            _StreamClient(Stream.value([1, 2, 3]), length: 3),
      );
      addTearDown(() async {
        await service.dispose();
        await directory.delete(recursive: true);
      });
      for (final metadata in [
        <String, Object?>{},
        <String, Object?>{
          'fullQualityPlaybackUrls': ['https://example.test/full.mp3'],
        },
      ]) {
        final result = await service.cacheTrack(
          _track(
            'https://example.test/low-${metadata.length}.mp3',
            fileSizeBytes: 99,
            remoteMetadata: metadata,
          ),
        );
        expect(result, isNotNull);
      }
    },
  );

  test(
    'legacy cache is retired and damaged v2 hit is downloaded again',
    () async {
      final directory = await Directory.systemTemp.createTemp('cache_version_');
      final root = await Directory(
        '${directory.path}/${AsmrPlaybackCacheService.cacheDirectoryName}',
      ).create();
      const url = 'https://example.test/full.mp3';
      final name = '${sha1.convert(utf8.encode(url))}.mp3';
      final legacy = await File('${root.path}/$name').writeAsBytes([8]);
      final current = await File('${root.path}/v2-$name').writeAsBytes([9]);
      var requests = 0;
      final service = AsmrPlaybackCacheService(
        temporaryDirectory: () async => directory,
        httpClientFactory: () {
          requests++;
          return _StreamClient(Stream.value([1, 2, 3]), length: 3);
        },
      );
      addTearDown(() async {
        await service.dispose();
        await directory.delete(recursive: true);
      });
      final track = _track(
        url,
        fileSizeBytes: 3,
        remoteMetadata: {
          'fullQualityPlaybackUrls': [url],
        },
      );
      expect(await service.cacheTrack(track), path.normalize(current.path));
      expect(await legacy.exists(), isFalse);
      expect(await current.readAsBytes(), [1, 2, 3]);
      expect(await service.cacheTrack(track), path.normalize(current.path));
      expect(requests, 1);
    },
  );

  test('a blocked file write pauses the download source', () async {
    final directory = await Directory.systemTemp.createTemp(
      'asmr_backpressure_',
    );
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    final originalIo = _OriginalIo();
    var producedChunks = 0;
    Stream<List<int>> body() async* {
      for (var index = 0; index < 20; index++) {
        producedChunks++;
        yield [index];
      }
    }

    final service = AsmrPlaybackCacheService(
      temporaryDirectory: () async => directory,
      httpClientFactory: () => _StreamClient(body()),
    );
    addTearDown(() async {
      if (!releaseWrite.isCompleted) releaseWrite.complete();
      await service.dispose();
      await directory.delete(recursive: true);
    });
    await IOOverrides.runZoned(
      () async {
        final result = service.cacheTrack(
          _track('https://example.test/audio.mp3'),
        );
        await writeStarted.future.timeout(const Duration(seconds: 1));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(producedChunks, 1);
        releaseWrite.complete();
        final cached = await result;
        expect(cached, isNotNull);
        expect(await File(cached!).readAsBytes(), List.generate(20, (i) => i));
      },
      createFile: (filePath) {
        final file = originalIo.createFile(filePath);
        return filePath.endsWith('.part')
            ? _WriteGateFile(file, writeStarted, releaseWrite.future)
            : file;
      },
    );
  });

  test('distinct cache transfers are capped at two and queued FIFO', () async {
    final directory = await Directory.systemTemp.createTemp('asmr_queue_');
    final requests = <String, HttpRequest>{};
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => requests[request.uri.path] = request);
    final service = _service(directory);
    addTearDown(() async {
      await service.dispose();
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    final first = service.cacheTrack(_track(_url(server, '/1.mp3')));
    final second = service.cacheTrack(_track(_url(server, '/2.mp3')));
    await _waitUntil(() => requests.length == 2);
    final thirdTrack = _track(_url(server, '/3.mp3'));
    final third = service.cacheTrack(thirdTrack);
    final duplicate = service.cacheTrack(thirdTrack);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final fourth = service.cacheTrack(_track(_url(server, '/4.mp3')));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(requests.keys, unorderedEquals(['/1.mp3', '/2.mp3']));
    requests['/1.mp3']!.response.add([1, 2, 3]);
    await requests['/1.mp3']!.response.close();
    await first;
    await _waitUntil(() => requests.length == 3);
    expect(requests.keys.last, '/3.mp3');
    requests['/2.mp3']!.response.add([4, 5]);
    await requests['/2.mp3']!.response.close();
    await second;
    await _waitUntil(() => requests.length == 4);
    for (final key in ['/3.mp3', '/4.mp3']) {
      requests[key]!.response.add([6, 7]);
      await requests[key]!.response.close();
    }
    final results = await Future.wait([third, duplicate, fourth]);
    expect(results.every((result) => result != null), isTrue);
    expect(results[0], results[1]);
    expect(requests.keys.skip(2), ['/3.mp3', '/4.mp3']);
  });

  test('dispose finishes active and queued cache transfers', () async {
    final directory = await Directory.systemTemp.createTemp('asmr_queue_stop_');
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      request.response.add([1]);
      await request.response.flush();
    });
    final service = _service(directory);
    addTearDown(() async {
      await service.dispose();
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    final pending = [
      for (var index = 0; index < 6; index++)
        service.cacheTrack(_track(_url(server, '/$index.mp3'))),
    ];
    await _waitUntil(() => requests == 2);
    await service.dispose().timeout(const Duration(seconds: 1));
    expect(await Future.wait(pending), everyElement(isNull));
    expect(requests, 2);
    expect(
      await service.cacheTrack(_track(_url(server, '/later.mp3'))),
      isNull,
    );
    expect(
      await directory.list(recursive: true).where((e) => e is File).toList(),
      isEmpty,
    );
  });

  test('same ASMR track shares one in-flight download', () async {
    final directory = await Directory.systemTemp.createTemp('asmr_cache_');
    final release = Completer<void>();
    final requestStarted = Completer<void>();
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      if (!requestStarted.isCompleted) requestStarted.complete();
      await release.future;
      request.response.add(<int>[1, 2, 3, 4]);
      await request.response.close();
    });
    final service = _service(directory);
    addTearDown(() async {
      await service.dispose();
      await server.close(force: true);
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final track = _track(_url(server, '/audio.mp3'));

    final first = service.cacheTrack(track);
    final second = service.cacheTrack(track);
    await requestStarted.future.timeout(const Duration(seconds: 1));
    expect(requests, 1);
    release.complete();

    final paths = await Future.wait(<Future<String?>>[first, second]);
    expect(paths.first, isNotNull);
    expect(paths.last, paths.first);
    expect(await File(paths.first!).readAsBytes(), <int>[1, 2, 3, 4]);
  });

  test('failed ASMR cache download remains retryable', () async {
    final directory = await Directory.systemTemp.createTemp('asmr_retry_');
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      if (requests == 1) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
      } else {
        request.response.add(<int>[5, 6, 7]);
      }
      await request.response.close();
    });
    final service = _service(directory);
    addTearDown(() async {
      await service.dispose();
      await server.close(force: true);
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final track = _track(_url(server, '/retry.mp3'));

    expect(await service.cacheTrack(track), isNull);
    final cached = await service.cacheTrack(track);

    expect(cached, isNotNull);
    expect(requests, 2);
  });

  test('stalled response times out and dispose removes partial file', () async {
    final directory = await Directory.systemTemp.createTemp('asmr_timeout_');
    final requestStarted = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.add(<int>[1]);
      if (!requestStarted.isCompleted) requestStarted.complete();
    });
    final service = _service(
      directory,
      requestTimeout: const Duration(milliseconds: 100),
      idleTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(() async {
      await service.dispose();
      await server.close(force: true);
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final future = service.cacheTrack(_track(_url(server, '/stalled.mp3')));
    await requestStarted.future.timeout(const Duration(seconds: 1));

    expect(await future.timeout(const Duration(seconds: 1)), isNull);
    await service.dispose();
    final partials = directory.existsSync()
        ? directory
              .listSync(recursive: true)
              .whereType<File>()
              .where((file) => file.path.endsWith('.part'))
              .toList()
        : const <File>[];
    expect(partials, isEmpty);
  });

  test('stalled response headers respect the request timeout', () async {
    final directory = await Directory.systemTemp.createTemp(
      'asmr_header_timeout_',
    );
    final requestStarted = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      if (!requestStarted.isCompleted) requestStarted.complete();
    });
    final service = _service(
      directory,
      requestTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(() async {
      await service.dispose();
      await server.close(force: true);
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    final future = service.cacheTrack(_track(_url(server, '/headers.mp3')));
    await requestStarted.future.timeout(const Duration(seconds: 1));

    expect(await future.timeout(const Duration(seconds: 1)), isNull);
  });

  test('dispose cancels an active download before rename', () async {
    final directory = await Directory.systemTemp.createTemp('asmr_dispose_');
    final responseStarted = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.add(<int>[1]);
      await request.response.flush();
      if (!responseStarted.isCompleted) responseStarted.complete();
    });
    final service = _service(directory);
    addTearDown(() async {
      await service.dispose();
      await server.close(force: true);
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    final future = service.cacheTrack(_track(_url(server, '/dispose.mp3')));
    await responseStarted.future.timeout(const Duration(seconds: 1));
    await service.dispose().timeout(const Duration(seconds: 1));

    expect(await future, isNull);
    final files = directory.existsSync()
        ? directory.listSync(recursive: true).whereType<File>().toList()
        : const <File>[];
    expect(files.where((file) => file.path.endsWith('.part')), isEmpty);
    expect(files.where((file) => !file.path.endsWith('.part')), isEmpty);
  });
}

AsmrPlaybackCacheService _service(
  Directory directory, {
  Duration requestTimeout = const Duration(seconds: 1),
  Duration idleTimeout = const Duration(seconds: 1),
}) => AsmrPlaybackCacheService(
  temporaryDirectory: () async => directory,
  requestTimeout: requestTimeout,
  downloadIdleTimeout: idleTimeout,
);

MusicTrack _track(
  String url, {
  int? fileSizeBytes,
  Map<String, Object?>? remoteMetadata,
}) => MusicTrack(
  path: url,
  displayName: 'track.mp3',
  groupKey: 'asmr-work',
  groupTitle: 'ASMR Work',
  groupSubtitle: 'ASMR',
  isSingle: false,
  remoteMetadataKind: 'asmr.one',
  fileSizeBytes: fileSizeBytes,
  remoteMetadata:
      remoteMetadata ??
      <String, Object?>{
        'playbackUrls': <String>[url],
      },
);

String _url(HttpServer server, String path) =>
    'http://${server.address.address}:${server.port}$path';

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for requests');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final class _OriginalIo extends IOOverrides {}

class _WriteGateFile implements File {
  _WriteGateFile(this.file, this.started, this.release);
  final File file;
  final Completer<void> started;
  final Future<void> release;
  @override
  String get path => file.path;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<int> length() => file.length();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);
  @override
  Future<File> rename(String newPath) => file.rename(newPath);
  @override
  IOSink openWrite({
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
  }) =>
      IOSink(_WriteGateConsumer(file.openWrite(mode: mode), started, release));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WriteGateConsumer implements StreamConsumer<List<int>> {
  _WriteGateConsumer(this.sink, this.started, this.release);
  final IOSink sink;
  final Completer<void> started;
  final Future<void> release;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      if (!started.isCompleted) started.complete();
      await release;
      sink.add(chunk);
    }
    await sink.flush();
  }

  @override
  Future<void> close() async => sink.close();
}

class _StreamClient implements HttpClient {
  _StreamClient(this.body, {this.status = 200, this.length = -1});
  final Stream<List<int>> body;
  final int status;
  final int length;
  late _StreamRequest request;
  @override
  bool autoUncompress = true;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      request = _StreamRequest(body, status, length);
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StreamRequest implements HttpClientRequest {
  _StreamRequest(this.body, this.status, this.length);
  final Stream<List<int>> body;
  final int status;
  final int length;
  @override
  final HttpHeaders headers = _Headers();
  @override
  Future<HttpClientResponse> close() async =>
      _StreamResponse(body, status, length);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StreamResponse extends Stream<List<int>> implements HttpClientResponse {
  _StreamResponse(this.body, this.statusCode, this.contentLength);
  final Stream<List<int>> body;
  @override
  final int statusCode;
  @override
  final int contentLength;
  @override
  final HttpHeaders headers = _Headers();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  final values = <String, String>{};
  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
