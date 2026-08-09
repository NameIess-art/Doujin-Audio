import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/asmr/application/asmr_playback_cache_service.dart';

void main() {
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

MusicTrack _track(String url) => MusicTrack(
  path: url,
  displayName: 'track.mp3',
  groupKey: 'asmr-work',
  groupTitle: 'ASMR Work',
  groupSubtitle: 'ASMR',
  isSingle: false,
  remoteMetadataKind: 'asmr.one',
  remoteMetadata: <String, Object?>{
    'playbackUrls': <String>[url],
  },
);

String _url(HttpServer server, String path) =>
    'http://${server.address.address}:${server.port}$path';
