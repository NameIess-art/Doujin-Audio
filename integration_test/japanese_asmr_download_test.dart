import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/platform/windows_media_tools.dart';
import 'package:doujin_audio/core/persistence/json_document_store.dart';
import 'package:doujin_audio/core/media/playback_media_reference.dart';
import 'package:doujin_audio/features/asmr/application/japanese_asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_internal_models.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_media_transfer.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_transfer_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_models.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_task_store.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_cleanup.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_download.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android HLS reports bytes and fractions during transfer',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('hls_progress_');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      try {
        final generation = await FFmpegKit.executeWithArguments([
          '-nostdin',
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:sample_rate=48000',
          '-t',
          '8',
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
          '${root.path}/stream.m3u8',
        ]);
        expect((await generation.getReturnCode())?.getValue(), 0);
        server.listen((request) async {
          if (request.uri.path.endsWith('.ts')) {
            await Future<void>.delayed(const Duration(milliseconds: 450));
          }
          final file = File('${root.path}/${request.uri.pathSegments.last}');
          request.response.add(await file.readAsBytes());
          await request.response.close();
        });
        final fractions = <double>[];
        final sizes = <int>[];
        await AsmrHlsAudioTransfer().save(
          reference: PlaybackMediaReference(
            streamUrl: 'http://127.0.0.1:${server.port}/stream.m3u8',
            endMs: 6000,
          ),
          output: File('${root.path}/chapter.m4a'),
          isCancelled: () => false,
          onProgress: fractions.add,
          onBytes: sizes.add,
        );
        expect(
          fractions.any((value) => value > 0 && value < 1),
          isTrue,
          reason: 'Native FFmpeg must report a chapter before it finishes.',
        );
        expect(sizes.where((value) => value > 0).length, greaterThan(1));
        expect(
          sizes.any((value) => value > 44 && value < sizes.last),
          isTrue,
          reason:
              'Audio bytes must grow during the download, beyond the M4A header.',
        );
        debugPrint('Native live progress: fractions=$fractions; bytes=$sizes');
      } finally {
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isAndroid,
  );
  testWidgets(
    'Japanese ASMR actual download produces a decodable chapter',
    (tester) async {
      final api = JapaneseAsmrApiService();
      final work = AsmrWork.fromJson(const {
        'id': 151657,
        'title': 'Live transport test',
        'sourceId': 'RJ01741555',
        'resources': [
          {
            'source': 'japaneseAsmr',
            'id': 151657,
            'code': 'RJ01741555',
            'pageUrl': '',
          },
        ],
      });
      final root = await Directory.systemTemp.createTemp('jp_pipeline_');
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      final tools = WindowsMediaTools();
      final outputs = AsmrDownloadOutputStore(
        fileCacheGateway: FileCachePlatformGateway.instance,
        jsonDocumentStore: DefaultJsonDocumentStore(),
        stagingDirectoryProvider: () async => root,
      );
      final store = AsmrDownloadTaskStore(
        persistTasks: false,
        persistenceSnapshot: outputs.capturePersistenceSnapshot,
      );
      try {
        final roots = await api.fetchTrackTree(work);
        final original = PlaybackMediaReference.parse(
          roots.single.children.first.streamUrl!,
        );
        final reference = PlaybackMediaReference(
          streamUrl: original.streamUrl,
          endMs: 2000,
          downloadUrl: original.downloadUrl,
          httpHeaders: original.httpHeaders,
        );
        final task = AsmrDownloadTaskSnapshot(
          work: work,
          destinationRoot: root.path,
          workFolderName: '作品 空格',
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
          saveMetadata: false,
          automaticFileRetryCount: 0,
          status: AsmrDownloadTaskStatus.downloading,
          totalFiles: 1,
          completedFiles: 0,
          skippedFiles: 0,
          failedFiles: 0,
          totalBytes: 0,
          downloadedBytes: 0,
          startedAt: DateTime.now(),
        );
        store[work.workKey] = task;
        final service = AsmrDownloadTransferService(
          store: store,
          outputs: outputs,
          automaticFileRetryDelay: Duration.zero,
          isDisposed: () => false,
          isPaused: (_) => false,
          throwIfCancelled: (_) {},
          hlsAudioTransfer: AsmrHlsAudioTransfer(),
        );
        final result = await service.downloadItem(
          PlannedDownloadFile(
            url: reference.logicalUrl,
            relativePath: '音频.flac',
            size: 0,
            mediaReference: reference,
          ),
          workId: work.workKey,
          task: task,
          workRootPath: task.workRootPath,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
          client: client,
        );
        if (!result.saved && Platform.isAndroid) {
          for (final session in await FFmpegKit.listSessions()) {
            debugPrint(
              'FFmpeg exit=${await session.getReturnCode()} '
              'output=${await session.getAllLogsAsString()} '
              'failure=${await session.getFailStackTrace()}',
            );
          }
        }
        expect(result.saved, isTrue);
        final saved = File('${task.workRootPath}/音频.m4a');
        final int durationMs;
        if (Platform.isAndroid) {
          final information = await FFprobeKit.getMediaInformation(saved.path);
          durationMs =
              (double.parse(information.getMediaInformation()!.getDuration()!) *
                      1000)
                  .round();
        } else {
          durationMs = (await tools.readDuration(saved.path))!.inMilliseconds;
        }
        expect(durationMs, closeTo(2000, 100));
        expect(store[work.workKey]!.actualOutputPaths['音频.flac'], '音频.m4a');
        debugPrint(
          'Actual pipeline saved ${await saved.length()} bytes; duration=$durationMs ms',
        );
      } finally {
        api.close();
        client.close(force: true);
        await store.shutdown();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
