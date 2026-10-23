import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doujin_audio/core/media/playback_media_reference.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/persistence/json_document_store.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_cleanup.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_internal_models.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_media_transfer.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_models.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_planner.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_serialization.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_task_store.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_transfer_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_download.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

const _audio = [0, 0, 0, 24, 102, 116, 121, 112, 77, 52, 65, 32];

void main() {
  for (final status in [200, 404, 410, 500]) {
    test(
      'original resolver classifies HTTP $status without guessing',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final forwarding = HttpClient();
        server.listen((request) async {
          expect(request.uri.path, '/abc/download');
          expect(request.headers.value('HX-Request'), 'true');
          expect(request.headers.value('Authorization'), isNull);
          request.response.statusCode = status;
          if (status == 200) {
            request.response.headers.set(
              'HX-Redirect',
              'https://cdn.test/file.flac',
            );
          }
          await request.response.close();
        });
        final client = _RedirectClient(forwarding, server.port);
        try {
          final pending = resolveAsmrOriginalUrl(
            client,
            'https://buzzheavier.com/abc',
          );
          if (status == 200) {
            expect(await pending, 'https://cdn.test/file.flac');
          } else {
            await expectLater(
              pending,
              throwsA(
                status == 500
                    ? isA<HttpException>()
                    : isA<AsmrOriginalUnavailable>(),
              ),
            );
          }
        } finally {
          forwarding.close(force: true);
          await server.close(force: true);
        }
      },
    );
  }

  test('resolver timeout is not evidence of a missing original', () async {
    await expectLater(
      resolveAsmrOriginalUrl(_TimeoutClient(), 'https://buzzheavier.com/abc'),
      throwsA(isA<TimeoutException>()),
    );
  });

  for (final status in [200, 404, 410, 500]) {
    for (final html in status == 200 ? [false, true] : [false]) {
      test(
        'original transfer $status HTML=$html only falls back on missing',
        () async {
          final env = await _Environment.create();
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((request) async {
            expect(request.headers.value('Authorization'), isNull);
            request.response.statusCode = status;
            if (status == 200) {
              request.response.add(
                html ? utf8.encode('<html>error</html>') : _audio,
              );
            }
            await request.response.close();
          });
          final reference = PlaybackMediaReference(
            streamUrl: 'https://media.test/stream.m3u8',
            startMs: 1000,
            endMs: 3000,
            downloadUrl: 'http://127.0.0.1:${server.port}/original',
          );
          try {
            final result = await env.download(reference);
            final missing = status == 404 || status == 410;
            expect(env.hls.calls, missing ? 1 : 0);
            expect(result.saved, missing || (status == 200 && !html));
            expect(
              env.store[env.work.workKey]!.actualOutputPaths,
              missing ? {'Folder/01.flac': 'Folder/01.m4a'} : isEmpty,
            );
            if (result.saved) {
              final relative = missing ? 'Folder/01.m4a' : 'Folder/01.flac';
              expect(
                await File(
                  path.join(env.task.workRootPath, relative),
                ).readAsBytes(),
                _audio,
              );
            }
          } finally {
            await env.dispose();
            await server.close(force: true);
          }
        },
      );
    }
  }

  test(
    'HLS selection persists and pins recovery to the same representation',
    () async {
      final env = await _Environment.create();
      try {
        final result = await env.download(
          const PlaybackMediaReference(
            streamUrl: 'https://media.test/stream.m3u8',
            startMs: 500,
            endMs: 1500,
          ),
        );
        expect(result.saved, isTrue);
        final persisted = downloadTaskToJson(
          env.store[env.work.workKey]!,
          createdOutputPaths: env.outputs.createdOutputPaths[env.work.workKey]!,
          createdJsonDocuments: const {},
        );
        final restored = downloadTaskFromJson(persisted).task;
        expect(restored.actualOutputPaths, {'Folder/01.flac': 'Folder/01.m4a'});
        env.store[env.work.workKey] = restored;
        await env.download(
          const PlaybackMediaReference(
            streamUrl: 'https://media.test/stream.m3u8',
            startMs: 500,
            endMs: 1500,
            downloadUrl: 'https://must-not-resolve.invalid/original',
          ),
        );
        expect(env.hls.calls, 2);
      } finally {
        await env.dispose();
      }
    },
  );

  test(
    'HLS errors mark only the file failed and use configured retries',
    () async {
      final env = await _Environment.create(retries: 2);
      env.hls.failure = const HttpException('HLS unavailable');
      try {
        final result = await env.download(
          const PlaybackMediaReference(
            streamUrl: 'https://media.test/audio.m3u8',
          ),
        );
        expect(result.saved, isFalse);
        expect(env.hls.calls, 3);
        expect(env.store[env.work.workKey]!.fileRetryAttempts, isEmpty);
        expect(env.root.listSync(recursive: true).whereType<File>(), isEmpty);
      } finally {
        await env.dispose();
      }
    },
  );

  test(
    'HLS cancellation propagates and removes the temporary output',
    () async {
      final env = await _Environment.create();
      env.hls.failure = const DownloadCancelled();
      try {
        await expectLater(
          env.download(
            const PlaybackMediaReference(
              streamUrl: 'https://media.test/audio.m3u8',
            ),
          ),
          throwsA(isA<DownloadCancelled>()),
        );
        expect(env.hls.calls, 1);
        expect(env.root.listSync(recursive: true).whereType<File>(), isEmpty);
      } finally {
        await env.dispose();
      }
    },
  );

  test(
    'HLS SAF commit uses actual output path and retains deletion ownership',
    () async {
      final gateway = _SafGateway();
      final env = await _Environment.create(gateway: gateway);
      try {
        final result = await env.download(
          const PlaybackMediaReference(
            streamUrl: 'https://media.test/audio.m3u8',
          ),
        );
        expect(result.saved, isTrue);
        expect(gateway.relativePath, 'Folder/01.m4a');
        expect(gateway.folder, env.task.workRootPath);
        expect(gateway.bytes, _audio);
        expect(
          env.outputs.createdOutputPaths[env.work.workKey],
          contains('${env.task.workRootPath}/Folder/01.m4a'),
        );
        expect(env.root.listSync(recursive: true).whereType<File>(), isEmpty);
      } finally {
        await env.dispose();
      }
    },
  );

  test(
    'HLS conversion passes chapter, headers and Unicode path as arguments',
    () async {
      final root = await Directory.systemTemp.createTemp('hls_arguments_');
      final output = File(path.join(root.path, '音频 01.m4a.part'));
      final commands = <List<String>>[];
      final transfer = AsmrHlsAudioTransfer(
        startProcess: (arguments) async {
          commands.add(arguments);
          if (commands.length == 1) await output.writeAsBytes(_audio);
          return _Process(0, progress: 'out_time_us=1000000\n');
        },
      );
      final progress = <double>[];
      try {
        await transfer.save(
          reference: const PlaybackMediaReference(
            streamUrl: 'https://media.test/file.m3u8',
            startMs: 1500,
            endMs: 3500,
            httpHeaders: {'Referer': 'https://japaneseasmr.com/'},
          ),
          output: output,
          isCancelled: () => false,
          onProgress: progress.add,
        );
        final command = commands.first;
        expect(command[command.indexOf('-ss') + 1], '1.500');
        expect(command[command.indexOf('-t') + 1], '2.000');
        expect(
          command[command.indexOf('-headers') + 1],
          'Referer: https://japaneseasmr.com/\r\n',
        );
        expect(command.last, output.path);
        expect(command[command.indexOf('-f') + 1], 'ipod');
        expect(commands, hasLength(2));
        expect(progress, contains(0.5));
        expect(progress.last, 1);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'HLS FFmpeg invocation is killed and awaited when cancellation wins',
    () async {
      final root = await Directory.systemTemp.createTemp('hls_cancel_');
      final output = File(path.join(root.path, 'audio.part'));
      final process = _Process(null);
      var cancelled = false;
      final transfer = AsmrHlsAudioTransfer(
        startProcess: (_) async {
          await output.writeAsBytes(_audio);
          cancelled = true;
          return process;
        },
      );
      try {
        await expectLater(
          transfer.save(
            reference: const PlaybackMediaReference(
              streamUrl: 'https://media.test/file.m3u8',
            ),
            output: output,
            isCancelled: () => cancelled,
          ),
          throwsA(isA<DownloadCancelled>()),
        );
        expect(process.killed, isTrue);
        expect(await output.exists(), isFalse);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('HLS validation rejects HTML and removes partial output', () async {
    final root = await Directory.systemTemp.createTemp('hls_invalid_');
    final output = File(path.join(root.path, 'audio.part'));
    final transfer = AsmrHlsAudioTransfer(
      startProcess: (_) async {
        await output.writeAsString('<html>not audio</html>');
        return _Process(0);
      },
    );
    try {
      await expectLater(
        transfer.save(
          reference: const PlaybackMediaReference(
            streamUrl: 'https://media.test/file.m3u8',
          ),
          output: output,
          isCancelled: () => false,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await output.exists(), isFalse);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('different originals cannot collapse to the same generated M4A', () {
    const planner = AsmrDownloadPlanner();
    expect(
      () => planner.validateLocalOutputs([
        const PlannedDownloadFile(
          url: '',
          relativePath: 'Folder/01.flac',
          size: 0,
          mediaReference: PlaybackMediaReference(
            streamUrl: 'https://media.test/audio.m3u8',
          ),
        ),
        const PlannedDownloadFile(
          url: '',
          relativePath: 'Folder/01.wav',
          size: 0,
          mediaReference: PlaybackMediaReference(
            streamUrl: 'https://media.test/audio.m3u8',
          ),
        ),
      ], saveMetadata: false),
      throwsFormatException,
    );
  });
}

class _Environment {
  _Environment(
    this.root,
    this.store,
    this.outputs,
    this.work,
    this.task,
    this.hls,
  );
  final Directory root;
  final AsmrDownloadTaskStore store;
  final AsmrDownloadOutputStore outputs;
  final AsmrWork work;
  final AsmrDownloadTaskSnapshot task;
  final _HlsTransfer hls;

  static Future<_Environment> create({
    int retries = 0,
    _SafGateway? gateway,
  }) async {
    final root = await Directory.systemTemp.createTemp('jp_download_');
    final outputs = AsmrDownloadOutputStore(
      fileCacheGateway: gateway ?? FileCachePlatformGateway.instance,
      jsonDocumentStore: DefaultJsonDocumentStore(),
      stagingDirectoryProvider: () async => root,
    );
    final store = AsmrDownloadTaskStore(
      persistTasks: false,
      persistenceSnapshot: outputs.capturePersistenceSnapshot,
    );
    final work = AsmrWork.fromJson(const {
      'id': 42,
      'title': 'Work',
      'source_id': 'RJ123456',
    });
    final task = AsmrDownloadTaskSnapshot(
      work: work,
      destinationRoot: gateway == null
          ? root.path
          : 'content://storage/tree/root',
      workFolderName: 'Work',
      conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
      saveMetadata: false,
      automaticFileRetryCount: retries,
      status: AsmrDownloadTaskStatus.downloading,
      totalFiles: 1,
      completedFiles: 0,
      skippedFiles: 0,
      failedFiles: 0,
      totalBytes: 0,
      downloadedBytes: 0,
      startedAt: DateTime(2026),
    );
    store[work.workKey] = task;
    outputs.createdOutputPaths[work.workKey] = {};
    return _Environment(root, store, outputs, work, task, _HlsTransfer());
  }

  Future<DownloadWriteResult> download(PlaybackMediaReference reference) async {
    final client = HttpClient();
    try {
      final current = store[work.workKey]!.copyWith(
        selectedRoots: [
          AsmrTrackFile(
            hash: 'chapter',
            title: '01.flac',
            type: 'audio',
            streamUrl: reference.logicalUrl,
            downloadUrl: reference.downloadUrl,
            lowQualityUrl: null,
            duration: Duration.zero,
            size: 0,
            children: const [],
            workId: work.id,
            workKey: work.workKey,
            workTitle: work.title,
            sourceId: work.sourceId,
            relativePath: 'Folder/01.flac',
          ),
        ],
      );
      store[work.workKey] = current;
      final service = AsmrDownloadTransferService(
        store: store,
        outputs: outputs,
        automaticFileRetryDelay: Duration.zero,
        isDisposed: () => false,
        isPaused: (_) => false,
        throwIfCancelled: (_) {},
        hlsAudioTransfer: hls,
      );
      return await service.downloadItem(
        PlannedDownloadFile(
          url: reference.logicalUrl,
          relativePath: 'Folder/01.flac',
          size: 0,
          mediaReference: reference,
        ),
        workId: work.workKey,
        task: current,
        workRootPath: task.workRootPath,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        client: client,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> dispose() async {
    await store.shutdown();
    await root.delete(recursive: true);
  }
}

class _HlsTransfer extends AsmrHlsAudioTransfer {
  int calls = 0;
  Object? failure;
  @override
  Future<void> save({
    required PlaybackMediaReference reference,
    required File output,
    required bool Function() isCancelled,
    void Function(double fraction)? onProgress,
  }) async {
    calls++;
    await output.parent.create(recursive: true);
    await output.writeAsBytes(_audio);
    if (failure != null) throw failure!;
  }
}

class _SafGateway extends FileCachePlatformGateway {
  String? relativePath;
  String? folder;
  List<int>? bytes;
  @override
  Future<bool> documentPathExists(String path) async => false;
  @override
  Future<bool> copyFileToFolder({
    required String sourcePath,
    required String folder,
    required String relativePath,
    bool overwrite = false,
  }) async {
    this.relativePath = relativePath;
    this.folder = folder;
    bytes = await File(sourcePath).readAsBytes();
    return true;
  }
}

class _RedirectClient implements HttpClient {
  _RedirectClient(this.client, this.port);
  final HttpClient client;
  final int port;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) =>
      client.getUrl(Uri.parse('http://127.0.0.1:$port${uri.path}'));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TimeoutClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async =>
      throw TimeoutException('offline');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Process implements Process {
  _Process(int? code, {String progress = ''})
    : stdout = Stream.value(utf8.encode(progress)) {
    if (code != null) completion.complete(code);
  }
  final completion = Completer<int>();
  bool killed = false;
  @override
  final Stream<List<int>> stdout;
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<int> get exitCode => completion.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!completion.isCompleted) completion.complete(-1);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
