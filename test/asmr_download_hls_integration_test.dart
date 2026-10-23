import 'dart:async';
import 'dart:io';

import 'package:doujin_audio/core/media/playback_media_reference.dart';
import 'package:doujin_audio/core/platform/windows_media_tools.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/persistence/json_document_store.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_cleanup.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_models.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_task_store.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_transfer_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_download.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_internal_models.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_media_transfer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  final toolsDirectory = path.absolute('dist', 'windows', 'app');
  final tools = WindowsMediaTools(executableDirectory: toolsDirectory);
  final unavailable =
      !Platform.isWindows ||
      !File(path.join(toolsDirectory, 'tools', 'ffmpeg.exe')).existsSync();

  test(
    'download pipeline retries originals then saves decodable HLS chapters',
    () async {
      final root = await Directory.systemTemp.createTemp('HLS 音频_');
      final playlist = path.join(root.path, 'stream.m3u8');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var originalRequests = 0;
      try {
        final generation = await tools.start('ffmpeg', [
          '-nostdin',
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:sample_rate=48000',
          '-t',
          '6',
          '-c:a',
          'aac',
          '-b:a',
          '128k',
          '-hls_time',
          '1',
          '-hls_list_size',
          '0',
          '-f',
          'hls',
          playlist,
        ]);
        final errors = generation.stderr.drain<void>();
        final output = generation.stdout.drain<void>();
        expect(await generation.exitCode, 0);
        await Future.wait([errors, output]);
        server.listen((request) async {
          if (request.uri.path == '/original') {
            originalRequests++;
            request.response.statusCode = 500;
            await request.response.close();
            return;
          }
          final file = File(
            path.join(root.path, path.basename(request.uri.path)),
          );
          if (!await file.exists()) {
            request.response.statusCode = 404;
          } else {
            if (request.uri.path.endsWith('.ts')) {
              await Future<void>.delayed(const Duration(milliseconds: 350));
            }
            request.response.add(await file.readAsBytes());
          }
          await request.response.close();
        });
        final transfer = AsmrHlsAudioTransfer(
          startProcess: (args) => tools.start('ffmpeg', args),
        );
        for (final range in [(1200, 2700), (3100, 4100), (0, 6000)]) {
          final output = File(
            path.join(root.path, '作品', '输出 音频 ${range.$1}.m4a'),
          );
          final work = AsmrWork.fromJson(const {'id': 42});
          final outputs = AsmrDownloadOutputStore(
            fileCacheGateway: FileCachePlatformGateway.instance,
            jsonDocumentStore: DefaultJsonDocumentStore(),
            stagingDirectoryProvider: () async => root,
          );
          final store = AsmrDownloadTaskStore(
            persistTasks: false,
            persistenceSnapshot: outputs.capturePersistenceSnapshot,
          );
          final task = AsmrDownloadTaskSnapshot(
            work: work,
            destinationRoot: root.path,
            workFolderName: '作品',
            conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
            saveMetadata: false,
            automaticFileRetryCount: 1,
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
          final liveUpdates = <AsmrDownloadTaskSnapshot>[];
          final subscription = store.taskStream(work.workKey).listen((value) {
            if (value != null &&
                value.hasUnknownFileSizes &&
                value.downloadedBytes > 0) {
              liveUpdates.add(value);
            }
          });
          final service = AsmrDownloadTransferService(
            store: store,
            outputs: outputs,
            automaticFileRetryDelay: Duration.zero,
            isDisposed: () => false,
            isPaused: (_) => false,
            throwIfCancelled: (_) {},
            hlsAudioTransfer: transfer,
          );
          final reference = PlaybackMediaReference(
            streamUrl: 'http://127.0.0.1:${server.port}/stream.m3u8',
            startMs: range.$1,
            endMs: range.$2,
            downloadUrl: 'http://127.0.0.1:${server.port}/original',
          );
          final client = HttpClient();
          try {
            final result = await service.downloadItem(
              PlannedDownloadFile(
                url: reference.logicalUrl,
                relativePath: '输出 音频 ${range.$1}.flac',
                size: 0,
                mediaReference: reference,
              ),
              workId: work.workKey,
              task: task,
              workRootPath: task.workRootPath,
              conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
              client: client,
            );
            expect(result.saved, isTrue);
            expect(store[work.workKey]!.totalBytes, await output.length());
            expect(
              liveUpdates,
              isNotEmpty,
              reason: 'Real FFmpeg reports bytes before committing the output.',
            );
            expect(
              liveUpdates.any((value) => (value.progress ?? 0) > 0),
              isTrue,
            );
            if (range.$1 == 0) {
              expect(
                liveUpdates.any(
                  (value) =>
                      value.downloadedBytes > 44 &&
                      (value.progress ?? 0) > 0 &&
                      (value.progress ?? 1) < 1,
                ),
                isTrue,
                reason:
                    'Written audio bytes must grow before the chapter finishes.',
              );
            }
          } finally {
            await subscription.cancel();
            client.close(force: true);
            await store.shutdown();
          }
          final duration = await tools.readDuration(output.path);
          expect(duration, isNotNull);
          expect(
            duration!.inMilliseconds,
            closeTo(range.$2 - range.$1, 100),
            reason: 'Each saved file must contain only the selected chapter.',
          );
          final decode = await tools.start('ffmpeg', [
            '-nostdin',
            '-v',
            'error',
            '-i',
            output.path,
            '-f',
            'null',
            '-',
          ]);
          final decodeErrors = decode.stderr.drain<void>();
          final decodeOutput = decode.stdout.drain<void>();
          expect(await decode.exitCode, 0);
          await Future.wait([decodeErrors, decodeOutput]);
        }
        expect(originalRequests, 6);
      } finally {
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
    skip: unavailable
        ? 'Requires the bundled Windows FFmpeg distribution.'
        : false,
  );

  test(
    'cancellation terminates real FFmpeg while an HLS segment is stalled',
    () async {
      final root = await Directory.systemTemp.createTemp('hls_interrupt_');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final started = Completer<void>();
      var cancelled = false;
      server.listen((request) async {
        if (request.uri.path.endsWith('.m3u8')) {
          request.response.write(
            '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:10,\nstalled.ts\n#EXT-X-ENDLIST\n',
          );
          await request.response.close();
        } else {
          request.response.headers.contentType = ContentType('video', 'mp2t');
          await request.response.flush();
          if (!started.isCompleted) started.complete();
        }
      });
      try {
        final transfer = AsmrHlsAudioTransfer(
          startProcess: (args) => tools.start('ffmpeg', args),
        );
        final output = File(path.join(root.path, 'chapter.m4a.part'));
        final saving = transfer.save(
          reference: PlaybackMediaReference(
            streamUrl: 'http://127.0.0.1:${server.port}/stream.m3u8',
            endMs: 1000,
          ),
          output: output,
          isCancelled: () => cancelled,
        );
        final failed = expectLater(saving, throwsA(isA<DownloadCancelled>()));
        await started.future.timeout(const Duration(seconds: 5));
        cancelled = true;
        await failed.timeout(const Duration(seconds: 3));
        expect(await output.exists(), isFalse);
      } finally {
        cancelled = true;
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
    skip: unavailable
        ? 'Requires the bundled Windows FFmpeg distribution.'
        : false,
  );
}
