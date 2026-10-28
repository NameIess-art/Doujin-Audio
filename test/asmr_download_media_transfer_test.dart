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
  for (final saf in [false, true]) {
    test(
      'Japanese cover sends its Referer and saves the image (SAF=$saf)',
      () async {
        final gateway = saf ? _SafGateway() : null;
        final env = await _Environment.create(gateway: gateway);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final transport = HttpClient();
        const image = <int>[0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4];
        server.listen((request) async {
          if (request.headers.value(HttpHeaders.refererHeader) !=
              'https://japaneseasmr.com/') {
            request.response.statusCode = HttpStatus.forbidden;
          } else {
            expect(
              request.headers.value(HttpHeaders.authorizationHeader),
              isNull,
            );
            request.response.headers.contentType = ContentType('image', 'jpeg');
            request.response.add(image);
          }
          await request.response.close();
        });
        try {
          final service = AsmrDownloadTransferService(
            store: env.store,
            outputs: env.outputs,
            automaticFileRetryDelay: Duration.zero,
            isDisposed: () => false,
            isPaused: (_) => false,
            throwIfCancelled: (_) {},
          );
          final result = await service.downloadItem(
            const PlannedDownloadFile.cover(
              url: 'https://pic.weeabo0.xyz/RJ123456_img_main.jpg',
              relativePath: 'cover/cover.cover',
              coverFileStem: 'cover',
              maxBytes: 5 * 1024 * 1024,
            ),
            workId: env.work.workKey,
            task: env.task,
            workRootPath: env.task.workRootPath,
            conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
            client: _RedirectClient(transport, server.port),
          );
          expect(result.saved, isTrue);
          if (gateway != null) {
            expect(gateway.relativePath, 'cover/cover.jpg');
            expect(gateway.bytes, image);
          } else {
            expect(
              await File(
                path.join(env.task.workRootPath, 'cover', 'cover.jpg'),
              ).readAsBytes(),
              image,
            );
          }
          expect(
            env.store[env.work.workKey]!.coverOutputPath,
            endsWith('cover.jpg'),
          );
        } finally {
          transport.close(force: true);
          await server.close(force: true);
          await env.dispose();
        }
      },
    );
  }

  test(
    'download tree removes only the Japanese source wrapper and keeps media',
    () {
      const planner = AsmrDownloadPlanner();
      final work = AsmrWork.fromJson(const {
        'id': 42,
        'resources': [
          {'source': 'japaneseAsmr', 'id': 42, 'code': '', 'pageUrl': ''},
        ],
      });
      final root = AsmrTrackFile.fromJson(const {
        'type': 'folder',
        'title': 'japaneseasmr.com',
        'children': [
          {
            'type': 'folder',
            'title': 'Disc 1',
            'children': [
              {
                'type': 'audio',
                'title': '01.m4a',
                'hash': 'chapter-one',
                'mediaStreamUrl':
                    'https://media.test/a.m3u8#eara-chapter=0,1000',
                'mediaDownloadUrl': 'https://media.test/01.m4a',
              },
            ],
          },
        ],
      });
      final original = root.children.single.children.single;
      final tree = planner.prepareDownloadTree(work, [root]);
      final file = tree.single.children.single;
      expect(tree.single.relativePath, 'Disc 1');
      expect(file.relativePath, 'Disc 1/01.m4a');
      expect(file.hash, original.hash);
      expect(file.streamUrl, original.streamUrl);
      expect(file.downloadUrl, original.downloadUrl);
      expect(original.relativePath, 'japaneseasmr.com/Disc 1/01.m4a');
      expect(
        planner.prepareDownloadTree(work, [original]).single.relativePath,
        'Disc 1/01.m4a',
      );
      expect(
        planner.prepareDownloadTree(work, tree).single.relativePath,
        'Disc 1',
      );
      final one = AsmrWork.fromJson(const {'id': 42});
      final oneRoots = [root];
      expect(planner.prepareDownloadTree(one, oneRoots), same(oneRoots));
    },
  );

  for (final status in [200, 403, 404, 410, 500]) {
    test(
      'original resolver classifies HTTP $status without guessing',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final forwarding = HttpClient();
        server.listen((request) async {
          expect(request.headers.value('Authorization'), isNull);
          if (request.uri.path == '/abc') {
            expect(request.headers.value('HX-Request'), isNull);
            request.response.statusCode = status;
            request.response.write('<button hx-get="/abc/download"></button>');
            await request.response.close();
            return;
          }
          expect(request.uri.path, '/abc/download');
          expect(request.headers.value('HX-Request'), 'true');
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

  for (final direct in [true, false]) {
    test(
      'Buzzheavier subdomain resolves ${direct ? "audio" : "page endpoint"}',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final transport = HttpClient();
        final paths = <String>[];
        server.listen((request) async {
          paths.add(request.uri.path);
          expect(
            request.headers.value('User-Agent'),
            japaneseAsmrDownloadUserAgent,
          );
          if (request.uri.path == '/d/file') {
            if (direct) {
              request.response.headers.contentType = ContentType(
                'audio',
                'mp4',
              );
              request.response.add(_audio);
            } else {
              request.response.write(
                '<button hx-get="/resolve/file?a=1&amp;b=2">Download</button>',
              );
            }
          } else {
            expect(request.uri.queryParameters, {'a': '1', 'b': '2'});
            expect(request.headers.value('HX-Request'), 'true');
            request.response.headers.set(
              'HX-Redirect',
              'https://cdn.test/audio.m4a',
            );
          }
          await request.response.close();
        });
        try {
          final url = await resolveAsmrOriginalUrl(
            _RedirectClient(transport, server.port),
            'https://ts.buzzheavier.com/d/file',
          );
          expect(
            url,
            direct
                ? 'https://ts.buzzheavier.com/d/file'
                : 'https://cdn.test/audio.m4a',
          );
          expect(paths, direct ? ['/d/file'] : ['/d/file', '/resolve/file']);
        } finally {
          transport.close(force: true);
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

  for (final status in [200, 403, 404, 410, 500]) {
    for (final html in status == 200 ? [false, true] : [false]) {
      test(
        'original transfer $status HTML=$html keeps usable originals or tries HLS',
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
            final unavailable = status != 200 || html;
            expect(env.hls.calls, unavailable ? 1 : 0);
            expect(result.saved, unavailable || (status == 200 && !html));
            expect(
              env.store[env.work.workKey]!.actualOutputPaths,
              unavailable ? {'Folder/01.flac': 'Folder/01.m4a'} : isEmpty,
            );
            if (result.saved) {
              if (unavailable) {
                final task = env.store[env.work.workKey]!;
                expect(task.totalBytes, _audio.length);
                expect(task.fileTotalBytes['Folder/01.flac'], _audio.length);
              }
              final relative = unavailable ? 'Folder/01.m4a' : 'Folder/01.flac';
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

  for (final error in [
    const SocketException('offline'),
    const HandshakeException('TLS failed'),
    TimeoutException('original timed out'),
  ]) {
    test(
      'original ${error.runtimeType} retries before HLS selection',
      () async {
        final env = await _Environment.create(retries: 1);
        final client = _FailingClient(error);
        try {
          final result = await env.download(
            const PlaybackMediaReference(
              streamUrl: 'https://media.test/audio.m3u8',
              downloadUrl: 'https://original.test/audio.flac',
            ),
            client: client,
          );
          expect(result.saved, isTrue);
          expect(client.calls, 2);
          expect(env.hls.calls, 1);
        } finally {
          await env.dispose();
        }
      },
    );
  }

  test('local I/O errors and cancellation never switch to HLS', () async {
    final env = await _Environment.create();
    const reference = PlaybackMediaReference(
      streamUrl: 'https://media.test/audio.m3u8',
      downloadUrl: 'https://original.test/audio.flac',
    );
    try {
      final result = await env.download(
        reference,
        client: _FailingClient(const FileSystemException('disk unavailable')),
      );
      expect(result.saved, isFalse);
      expect(env.hls.calls, 0);
      await expectLater(
        env.download(
          reference,
          client: _FailingClient(const DownloadCancelled()),
        ),
        throwsA(isA<DownloadCancelled>()),
      );
      expect(env.hls.calls, 0);
    } finally {
      await env.dispose();
    }
  });

  test('HLS publishes bytes and chapter progress before completion', () async {
    final env = await _Environment.create();
    final key = env.work.workKey;
    env.store[key] = env.task.copyWith(
      totalFiles: 3,
      totalBytes: 4,
      downloadedBytes: 4,
      completedFiles: 1,
      completedFilePaths: const {'metadata.json'},
      fileTotalBytes: const {'metadata.json': 4, 'other.flac': 0},
      fileDownloadedBytes: const {'metadata.json': 4},
      fileProgressFractions: const {'other.flac': 0.25},
    );
    final updates = <AsmrDownloadTaskSnapshot>[];
    final subscription = env.store.taskStream(key).listen((task) {
      if (task != null) updates.add(task);
    });
    env.hls.transferring = (progress, bytes) async {
      bytes!(12);
      progress!(0.5);
      env.store.flushPendingProgressNotifications();
      await Future<void>.delayed(Duration.zero);
      final live = updates.last;
      expect(live.status, AsmrDownloadTaskStatus.downloading);
      expect(live.fileDownloadedBytes['Folder/01.flac'], 12);
      expect(
        live.downloadedBytes,
        16,
        reason: 'Known sibling size is not a cap.',
      );
      expect(live.totalBytes, 4);
      expect(live.estimateFileTotalBytes('Folder/01.flac'), 24);
      expect(live.estimatedTotalBytes, isNull);
      expect(live.hasUnknownFileSizes, isTrue);
      expect(live.progress, closeTo(1.75 / 3, 0.0001));
      expect(env.store.buttonViewState.progress, live.progress);
      expect(live.completedFilePaths, isNot(contains('Folder/01.flac')));
    };
    try {
      expect(
        (await env.download(
          const PlaybackMediaReference(
            streamUrl: 'https://media.test/audio.m3u8',
            endMs: 2000,
          ),
        )).saved,
        isTrue,
      );
      expect(env.store[key]!.fileTotalBytes['Folder/01.flac'], _audio.length);
    } finally {
      await subscription.cancel();
      await env.dispose();
    }
  });

  for (final chunked in [false, true]) {
    test(
      'Japanese original learns size ${chunked ? "after chunked transfer" : "from headers before completion"}',
      () async {
        final env = await _Environment.create();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final headersRead = Completer<void>();
        final release = Completer<void>();
        server.listen((request) async {
          if (!chunked) request.response.contentLength = _audio.length;
          request.response.add(_audio.take(4).toList());
          await request.response.flush();
          await release.future;
          request.response.add(_audio.skip(4).toList());
          await request.response.close();
        });
        final key = env.work.workKey;
        final subscription = env.store.taskStream(key).listen((task) {
          if (!chunked &&
              task?.fileTotalBytes['Folder/01.flac'] == _audio.length &&
              !headersRead.isCompleted) {
            headersRead.complete();
          }
        });
        try {
          final download = env.download(
            PlaybackMediaReference(
              streamUrl: 'https://media.test/audio.m3u8',
              downloadUrl: 'http://127.0.0.1:${server.port}/original',
            ),
          );
          if (!chunked) {
            await headersRead.future.timeout(const Duration(seconds: 5));
            expect(
              env.store[key]!.fileTotalBytes['Folder/01.flac'],
              _audio.length,
            );
          }
          release.complete();
          expect((await download).saved, isTrue);
          expect(
            env.store[key]!.fileTotalBytes['Folder/01.flac'],
            _audio.length,
          );
          expect(env.store[key]!.totalBytes, _audio.length);
          expect(env.store[key]!.hasUnknownFileSizes, isFalse);
          expect(env.hls.calls, 0);
        } finally {
          if (!release.isCompleted) release.complete();
          await subscription.cancel();
          await server.close(force: true);
          await env.dispose();
        }
      },
    );
  }

  test('resuming skips a saved HLS chapter without losing its size', () async {
    final env = await _Environment.create();
    const reference = PlaybackMediaReference(
      streamUrl: 'https://media.test/audio.m3u8',
    );
    try {
      final saved = await env.download(reference);
      final skipped = await env.download(
        reference,
        conflictPolicy: AsmrDownloadConflictPolicy.skip,
      );
      expect(skipped.skipped, isTrue);
      expect(skipped.bytesDownloaded, saved.bytesDownloaded);
      expect(env.hls.calls, 1);
      expect(
        env.store[env.work.workKey]!.fileTotalBytes['Folder/01.flac'],
        _audio.length,
      );
      expect(env.store[env.work.workKey]!.hasUnknownFileSizes, isFalse);
    } finally {
      await env.dispose();
    }
  });

  test(
    'HLS retry discards partial progress without resetting siblings',
    () async {
      final env = await _Environment.create(retries: 1);
      final key = env.work.workKey;
      env.store[key] = env.task.copyWith(
        downloadedBytes: 8,
        fileDownloadedBytes: const {'other.flac': 8},
        fileTotalBytes: const {'other.flac': 0},
        fileProgressFractions: const {'other.flac': 0.25},
      );
      env.hls.transferring = (progress, bytes) async {
        expect(env.store[key]!.fileRetryAttempts, isEmpty);
        expect(
          env.store.liveFileDownloadedBytes(key)['Folder/01.flac'] ?? 0,
          0,
        );
        expect(env.store[key]!.fileProgressFractions['Folder/01.flac'], 0);
        expect(env.store[key]!.fileProgressFractions['other.flac'], 0.25);
        bytes!(12);
        progress!(0.5);
        if (env.hls.calls == 1) throw const HttpException('interrupted');
      };
      try {
        expect(
          (await env.download(
            const PlaybackMediaReference(
              streamUrl: 'https://media.test/audio.m3u8',
              endMs: 2000,
            ),
          )).saved,
          isTrue,
        );
        expect(env.hls.calls, 2);
        expect(env.store.liveDownloadedBytes(key), 20);
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

  for (final hls in [false, true]) {
    test('retry intervals increase for ${hls ? 'HLS' : 'HTTP'}', () async {
      final env = await _Environment.create(retries: 3);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final elapsed = Stopwatch()..start();
      final attempts = <Duration>[];
      server.listen((request) async {
        attempts.add(elapsed.elapsed);
        if (attempts.length <= 3) {
          request.response.statusCode = HttpStatus.serviceUnavailable;
        } else {
          request.response.add(_audio);
        }
        await request.response.close();
      });
      env.hls.transferring = (progress, bytes) async {
        attempts.add(elapsed.elapsed);
        expect(env.store[env.work.workKey]!.fileRetryAttempts, isEmpty);
        if (attempts.length <= 3) throw const HttpException('unavailable');
      };
      try {
        final result = await env.download(
          PlaybackMediaReference(
            streamUrl: hls
                ? 'https://media.test/audio.m3u8'
                : 'http://${server.address.host}:${server.port}/audio.mp3',
          ),
          retryDelay: const Duration(milliseconds: 120),
        );

        expect(result.saved, isTrue);
        expect(attempts, hasLength(4));
        for (var attempt = 1; attempt < attempts.length; attempt++) {
          expect(
            attempts[attempt] - attempts[attempt - 1],
            greaterThanOrEqualTo(Duration(milliseconds: 120 * attempt)),
            reason: 'retry $attempt must wait for its increasing backoff',
          );
        }
        expect(env.store[env.work.workKey]!.fileRetryAttempts, isEmpty);
      } finally {
        await server.close(force: true);
        await env.dispose();
      }
    });
  }

  test('long retry backoff is interrupted and clears retry state', () async {
    final env = await _Environment.create(retries: 1);
    env.hls.failure = const HttpException('unavailable');
    var cancelled = false;
    final waiting = env.store
        .taskStream(env.work.workKey)
        .firstWhere((task) => task?.fileRetryAttempts['Folder/01.flac'] == 1);
    final transfer = env.download(
      const PlaybackMediaReference(streamUrl: 'https://media.test/audio.m3u8'),
      retryDelay: const Duration(seconds: 5),
      throwIfCancelled: (_) {
        if (cancelled) throw const DownloadCancelled();
      },
    );
    final result = expectLater(transfer, throwsA(isA<DownloadCancelled>()));
    try {
      await waiting.timeout(const Duration(seconds: 2));
      cancelled = true;
      await result.timeout(const Duration(seconds: 1));

      expect(env.hls.calls, 1);
      expect(env.store[env.work.workKey]!.fileRetryAttempts, isEmpty);
    } finally {
      cancelled = true;
      await result;
      await env.dispose();
    }
  });

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
          return _Process(
            0,
            progress: 'total_size=12\nout_time_us=1000000\nprogress=continue\n',
          );
        },
      );
      final progress = <double>[];
      final sizes = <int>[];
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
          onBytes: sizes.add,
        );
        final command = commands.first;
        final proxy = Uri.parse(command[command.indexOf('-http_proxy') + 1]);
        expect(proxy.scheme, 'http');
        expect(proxy.host, InternetAddress.loopbackIPv4.address);
        expect(proxy.port, greaterThan(0));
        expect(proxy.userInfo, isEmpty);
        expect(command.indexOf('-http_proxy'), lessThan(command.indexOf('-i')));
        expect(commands.last, isNot(contains('-http_proxy')));
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
        expect(sizes, [12, _audio.length]);
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

  Future<DownloadWriteResult> download(
    PlaybackMediaReference reference, {
    HttpClient? client,
    Duration retryDelay = Duration.zero,
    void Function(String)? throwIfCancelled,
    AsmrDownloadConflictPolicy conflictPolicy =
        AsmrDownloadConflictPolicy.overwrite,
  }) async {
    final transport = client ?? HttpClient();
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
        automaticFileRetryDelay: retryDelay,
        isDisposed: () => false,
        isPaused: (_) => false,
        throwIfCancelled: throwIfCancelled ?? (_) {},
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
        conflictPolicy: conflictPolicy,
        client: transport,
      );
    } finally {
      if (client == null) transport.close(force: true);
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
  Future<void> Function(void Function(double)?, void Function(int)?)?
  transferring;
  @override
  Future<void> save({
    required PlaybackMediaReference reference,
    required File output,
    required bool Function() isCancelled,
    void Function(double fraction)? onProgress,
    void Function(int bytes)? onBytes,
  }) async {
    calls++;
    await output.parent.create(recursive: true);
    await output.writeAsBytes(_audio);
    await transferring?.call(onProgress, onBytes);
    if (failure != null) throw failure!;
  }
}

class _SafGateway extends FileCachePlatformGateway {
  String? relativePath;
  String? folder;
  List<int>? bytes;
  @override
  Future<String?> ensureFolderPath({
    required String folder,
    required String relativePath,
    required bool overwrite,
  }) async => relativePath;
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
  Future<HttpClientRequest> getUrl(Uri uri) => client.getUrl(
    Uri.parse('http://127.0.0.1:$port${uri.path}?${uri.query}'),
  );
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

class _FailingClient implements HttpClient {
  _FailingClient(this.error);
  final Object error;
  int calls = 0;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    calls++;
    throw error;
  }

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
