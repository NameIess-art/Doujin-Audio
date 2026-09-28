import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/features/player/application/subtitle_model_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

class _Storage extends FileCachePlatformGateway {
  _Storage(this.availableBytes)
    : super(isAndroid: () => false, isWindows: () => false);

  final int availableBytes;

  @override
  Future<StorageUsagePlatformSnapshot?> readStorageUsage() async =>
      StorageUsagePlatformSnapshot(
        totalBytes: availableBytes * 2,
        availableBytes: availableBytes,
        cacheBytes: 0,
      );
}

void main() {
  test(
    'ready model skips download progress and rechecks a changed file',
    () async {
      final directory = await Directory.systemTemp.createTemp('ready_model_');
      addTearDown(() => directory.delete(recursive: true));
      final bytes = utf8.encode('ready-model');
      final file = File(path.join(directory.path, 'ready.gguf'));
      await file.writeAsBytes(bytes);
      final spec = SubtitleModelSpec(
        'ready.gguf',
        'https://example.com/ready.gguf',
        bytes.length,
        sha256.convert(bytes).toString(),
      );
      final store = SubtitleModelStore(
        directoryResolver: () async => directory,
      );
      expect((await store.status(spec)).ready, isTrue);
      var downloadProgress = false;
      expect(
        await store.ensure(
          spec,
          onProgress: (_, _, _) => downloadProgress = true,
        ),
        file.path,
      );
      expect(downloadProgress, isFalse);
      expect(store.snapshot(spec).active, isFalse);

      await file.writeAsBytes(utf8.encode('wrong-model'));
      await file.setLastModified(
        DateTime.now().add(const Duration(seconds: 2)),
      );
      expect((await store.status(spec)).ready, isFalse);
    },
  );

  test('resumes a model download and verifies its digest', () async {
    final directory = await Directory.systemTemp.createTemp('subtitle_model_');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    final bytes = utf8.encode('model-weights-for-test');
    final partial = File('${directory.path}/test.gguf.download');
    await partial.writeAsBytes(bytes.take(6).toList());
    final requests = <String?>[];
    server.listen((request) async {
      requests.add(request.headers.value(HttpHeaders.rangeHeader));
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes 6-${bytes.length - 1}/${bytes.length}',
      );
      request.response.add(bytes.skip(6).toList());
      await request.response.close();
    });
    final spec = SubtitleModelSpec(
      'test.gguf',
      'http://${server.address.host}:${server.port}/test.gguf',
      bytes.length,
      sha256.convert(bytes).toString(),
    );
    final store = SubtitleModelStore(
      storage: _Storage(256 * 1024 * 1024),
      directoryResolver: () async => directory,
    );
    final result = await store.ensure(spec);
    expect(requests, ['bytes=6-']);
    expect(await File(result).readAsBytes(), bytes);
    expect(await partial.exists(), isFalse);
    expect((await store.status(spec)).ready, isTrue);
  });

  test('rejects a corrupted model without installing it', () async {
    final directory = await Directory.systemTemp.createTemp(
      'subtitle_model_bad_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    server.listen((request) async {
      request.response.add(utf8.encode('bad'));
      await request.response.close();
    });
    final spec = SubtitleModelSpec(
      'test.gguf',
      'http://${server.address.host}:${server.port}/test.gguf',
      3,
      sha256.convert(utf8.encode('good')).toString(),
    );
    final store = SubtitleModelStore(
      storage: _Storage(256 * 1024 * 1024),
      directoryResolver: () async => directory,
    );
    await expectLater(store.ensure(spec), throwsFormatException);
    expect(await File('${directory.path}/test.gguf').exists(), isFalse);
  });

  test(
    'one download continues with progress after its listener leaves',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'model_background_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await server.close(force: true);
        await directory.delete(recursive: true);
      });
      final bytes = List<int>.filled(2 * 1048576, 7);
      final progressed = Completer<void>();
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.contentLength = bytes.length;
        request.response.add(bytes.sublist(0, 1048576));
        await request.response.flush();
        await release.future;
        request.response.add(bytes.sublist(1048576));
        await request.response.close();
      });
      final spec = SubtitleModelSpec(
        'background.gguf',
        'http://${server.address.host}:${server.port}/model.gguf',
        bytes.length,
        sha256.convert(bytes).toString(),
      );
      final store = SubtitleModelStore(
        storage: _Storage(256 * 1024 * 1024),
        directoryResolver: () async => directory,
      );
      void listener() {
        if (store.snapshot(spec).fraction >= 0.5 && !progressed.isCompleted) {
          progressed.complete();
        }
      }

      store.addListener(listener);
      final first = store.ensure(spec);
      final second = store.ensure(spec);
      expect(identical(first, second), isTrue);
      await progressed.future.timeout(const Duration(seconds: 5));
      expect(store.snapshot(spec).active, isTrue);
      expect(requests, 1);
      store.removeListener(listener);
      release.complete();
      expect(
        await first,
        '${directory.path}${Platform.pathSeparator}background.gguf',
      );
      expect(store.snapshot(spec).active, isFalse);
      expect(store.snapshot(spec).fraction, 1);
      expect((await store.status(spec)).ready, isTrue);
    },
  );
}
