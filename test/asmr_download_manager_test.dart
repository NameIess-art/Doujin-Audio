import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/asmr_download.dart';
import 'package:nameless_audio/models/audio_detail.dart';
import 'package:nameless_audio/models/asmr_models.dart';
import 'package:nameless_audio/services/asmr_download_manager.dart';

void main() {
  test('ASMR media requests include the scoped gateway language header', () {
    final headers = asmrMediaRequestHeadersForUrl(
      'https://raw.kiko-play-niptan.one/media/stream/work/track.mp3',
    );

    expect(
      headers[HttpHeaders.acceptLanguageHeader],
      'zh-CN,zh;q=0.9,en;q=0.8',
    );
    expect(
      asmrMediaRequestHeadersForUrl('https://example.com/track.mp3'),
      isEmpty,
    );
  });

  test('destinationExists checks local download folders', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_destination_',
    );
    final manager = _manager();
    try {
      expect(await manager.destinationExists(tempDir.path), isTrue);
      await tempDir.delete(recursive: true);
      expect(await manager.destinationExists(tempDir.path), isFalse);
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });

  test('task snapshot exposes a decoded destination path for SAF folders', () {
    const destinationRoot =
        'content://com.android.externalstorage.documents/tree/primary%3ADownload';
    const workFolderName = 'RJ123456 - 羊娘';
    final task = AsmrDownloadTaskSnapshot(
      work: const AsmrWork(
        id: 1,
        title: '羊娘',
        circleName: 'Circle',
        sourceId: 'RJ123456',
        sourceType: 'asmr',
        sourceUrl: '',
        coverUrl: '',
        thumbnailUrl: '',
        mainCoverUrl: '',
        releaseDate: null,
        createDate: null,
        duration: Duration.zero,
        dlCount: 0,
        reviewCount: 0,
        rating: 0,
        voiceActors: <String>[],
        tags: <String>[],
      ),
      destinationRoot: destinationRoot,
      workFolderName: workFolderName,
      conflictPolicy: AsmrDownloadConflictPolicy.skip,
      status: AsmrDownloadTaskStatus.downloading,
      totalFiles: 1,
      completedFiles: 0,
      skippedFiles: 0,
      failedFiles: 0,
      totalBytes: 0,
      downloadedBytes: 0,
      startedAt: DateTime(2026),
    );

    expect(task.workRootPath, '$destinationRoot::$workFolderName');
    expect(task.displayDestinationPath, 'Download/$workFolderName');
  });

  test(
    'download progress notifications are throttled but completion is immediate',
    () async {
      final manager = _manager();
      final notifications = <AsmrDownloadTaskSnapshot?>[];
      manager.addListener(() {
        notifications.add(manager.getTask(1));
      });

      final startedAt = DateTime(2026);
      final work = _work();
      manager.debugSetCurrentTaskForTesting(
        AsmrDownloadTaskSnapshot(
          work: work,
          destinationRoot: 'C:\\Downloads',
          workFolderName: 'RJ123456 - Work',
          conflictPolicy: AsmrDownloadConflictPolicy.skip,
          status: AsmrDownloadTaskStatus.downloading,
          totalFiles: 2,
          completedFiles: 0,
          skippedFiles: 0,
          failedFiles: 0,
          totalBytes: 1024,
          downloadedBytes: 0,
          startedAt: startedAt,
        ),
      );

      manager.debugSetCurrentTaskForTesting(
        AsmrDownloadTaskSnapshot(
          work: work,
          destinationRoot: 'C:\\Downloads',
          workFolderName: 'RJ123456 - Work',
          conflictPolicy: AsmrDownloadConflictPolicy.skip,
          status: AsmrDownloadTaskStatus.downloading,
          totalFiles: 2,
          completedFiles: 0,
          skippedFiles: 0,
          failedFiles: 0,
          totalBytes: 1024,
          downloadedBytes: 1,
          startedAt: startedAt,
        ),
        progressOnly: true,
      );

      expect(notifications, hasLength(1));

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(notifications, hasLength(2));
      expect(notifications.last?.downloadedBytes, 1);

      manager.debugSetCurrentTaskForTesting(
        AsmrDownloadTaskSnapshot(
          work: work,
          destinationRoot: 'C:\\Downloads',
          workFolderName: 'RJ123456 - Work',
          conflictPolicy: AsmrDownloadConflictPolicy.skip,
          status: AsmrDownloadTaskStatus.completed,
          totalFiles: 2,
          completedFiles: 2,
          skippedFiles: 0,
          failedFiles: 0,
          totalBytes: 1024,
          downloadedBytes: 1024,
          startedAt: startedAt,
        ),
      );

      expect(notifications, hasLength(3));
      expect(notifications.last?.status, AsmrDownloadTaskStatus.completed);
      manager.dispose();
    },
  );

  test(
    'download chunks only publish immutable snapshots at the throttle',
    () async {
      final manager = _manager();
      final work = _work();
      final initial = AsmrDownloadTaskSnapshot(
        work: work,
        destinationRoot: 'C:\\Downloads',
        workFolderName: 'RJ123456 - Work',
        conflictPolicy: AsmrDownloadConflictPolicy.skip,
        status: AsmrDownloadTaskStatus.downloading,
        totalFiles: 1,
        completedFiles: 0,
        skippedFiles: 0,
        failedFiles: 0,
        totalBytes: 1024,
        downloadedBytes: 0,
        startedAt: DateTime(2026),
      );
      manager.debugSetCurrentTaskForTesting(initial);
      var notifications = 0;
      manager.addListener(() => notifications++);

      for (var index = 0; index < 20; index++) {
        manager.debugRecordDownloadChunkForTesting(
          1,
          'track.mp3',
          1,
          index + 1,
        );
      }

      expect(identical(manager.getTask(1), initial), isTrue);
      expect(notifications, 0);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(notifications, 1);
      expect(manager.getTask(1)?.downloadedBytes, 20);
      expect(manager.getTask(1)?.fileDownloadedBytes['track.mp3'], 20);
      manager.dispose();
    },
  );

  test('downloads files from one work with bounded concurrency', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_parallel_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final allRequestsStarted = Completer<void>();
    var requestCount = 0;
    var activeRequests = 0;
    var maxActiveRequests = 0;
    unawaited(
      server.forEach((request) async {
        requestCount++;
        activeRequests++;
        if (activeRequests > maxActiveRequests) {
          maxActiveRequests = activeRequests;
        }
        if (requestCount == 3 && !allRequestsStarted.isCompleted) {
          allRequestsStarted.complete();
        }
        try {
          await allRequestsStarted.future.timeout(
            const Duration(milliseconds: 500),
          );
        } on TimeoutException {
          // A serial downloader reaches this timeout before starting the next file.
        }
        request.response.headers.contentLength = 256;
        request.response.add(List<int>.filled(256, requestCount));
        await request.response.close();
        activeRequests--;
      }),
    );
    final manager = _manager();
    try {
      await manager.startDownload(
        work: _work(),
        selectedRoots: <AsmrTrackFile>[
          for (var index = 0; index < 3; index++)
            _file(
              title: 'Track $index.mp3',
              downloadUrl:
                  'http://${server.address.host}:${server.port}/track-$index.mp3',
              size: 256,
            ),
        ],
        destinationRoot: tempDir.path,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
      );
      await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

      expect(requestCount, 3);
      expect(maxActiveRequests, greaterThanOrEqualTo(2));
    } finally {
      manager.dispose();
      await server.close(force: true);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  });

  test('local downloads stage beside the target without using cache', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_local_stage_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      server.forEach((request) async {
        request.response.headers.contentLength = 256;
        request.response.add(List<int>.filled(256, 7));
        await request.response.close();
      }),
    );
    var cacheDirectoryRequests = 0;
    final manager = AsmrDownloadManager(
      temporaryDirectoryProvider: () async {
        cacheDirectoryRequests++;
        return Directory.systemTemp;
      },
    );
    try {
      await manager.startDownload(
        work: _work(),
        selectedRoots: <AsmrTrackFile>[
          _file(
            downloadUrl:
                'http://${server.address.host}:${server.port}/track.mp3',
            size: 256,
          ),
        ],
        destinationRoot: tempDir.path,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
      );
      await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

      expect(cacheDirectoryRequests, 0);
      expect(
        await File(
          '${tempDir.path}${Platform.pathSeparator}RJ123456 - Work'
          '${Platform.pathSeparator}Track.mp3',
        ).length(),
        256,
      );
      expect(manager.getTask(1)?.progress, 1);
    } finally {
      manager.dispose();
      await server.close(force: true);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  });

  test('download backup includes ASMR.ONE extended metadata', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_backup_',
    );
    final manager = _manager();
    final work = _work(
      releaseDate: DateTime(2024, 5, 6),
      dlCount: 1234,
      rating: 4.5,
    );
    try {
      await manager.startDownload(
        work: work,
        selectedRoots: const <AsmrTrackFile>[
          AsmrTrackFile(
            hash: 'folder',
            title: 'Folder',
            type: 'folder',
            streamUrl: null,
            downloadUrl: null,
            lowQualityUrl: null,
            duration: Duration.zero,
            size: 0,
            children: <AsmrTrackFile>[],
            workId: 1,
            workTitle: 'Work',
            sourceId: 'RJ123456',
            relativePath: 'Folder',
          ),
        ],
        destinationRoot: tempDir.path,
        conflictPolicy: AsmrDownloadConflictPolicy.skip,
      );
      await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

      final backupPath =
          '${tempDir.path}${Platform.pathSeparator}RJ123456 - Work'
          '${Platform.pathSeparator}nameless-audio.json';
      final backup = await File(backupPath).readAsString();
      final detail = AudioDetail.fromBackupJson(
        AudioDetailTarget.libraryRootFolder(
          '${tempDir.path}${Platform.pathSeparator}RJ123456 - Work',
        ),
        Map<String, dynamic>.from(jsonDecode(backup) as Map),
      );
      expect(detail.releaseDate, DateTime(2024, 5, 6));
      expect(detail.salesCount, 1234);
      expect(detail.rating, 4.5);
    } finally {
      manager.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });

  test(
    'canceling an active download removes task and downloaded files',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_cancel_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(
        server.forEach((request) async {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentLength = 1024 * 1024;
          final chunk = List<int>.filled(16 * 1024, 7);
          try {
            for (var i = 0; i < 64; i++) {
              request.response.add(chunk);
              await request.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          } catch (_) {
            // The downloader closes the socket when cancellation is requested.
          } finally {
            await request.response.close().catchError((_) {});
          }
        }),
      );
      final manager = _manager();
      try {
        await manager.startDownload(
          work: _work(),
          selectedRoots: <AsmrTrackFile>[
            _file(
              downloadUrl:
                  'http://${server.address.host}:${server.port}/track.mp3',
              size: 1024 * 1024,
            ),
          ],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        );

        await _waitForLiveTask(manager);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await manager.cancelTask(1).timeout(const Duration(seconds: 5));

        expect(manager.getTask(1), isNull);
        expect(
          await Directory(
            '${tempDir.path}${Platform.pathSeparator}RJ123456 - Work',
          ).exists(),
          isFalse,
        );
      } finally {
        manager.dispose();
        await server.close(force: true);
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    },
  );

  test(
    'canceling preserves a work directory that existed before the task',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_existing_',
      );
      final workDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}RJ123456 - Work',
      );
      await workDir.create(recursive: true);
      final sentinel = File('${workDir.path}${Platform.pathSeparator}keep.txt');
      await sentinel.writeAsString('keep');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(
        server.forEach((request) async {
          request.response.headers.contentLength = 1024 * 1024;
          final chunk = List<int>.filled(16 * 1024, 7);
          try {
            for (var i = 0; i < 64; i++) {
              request.response.add(chunk);
              await request.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          } finally {
            await request.response.close().catchError((_) {});
          }
        }),
      );
      final manager = _manager();
      try {
        await manager.startDownload(
          work: _work(),
          selectedRoots: <AsmrTrackFile>[
            _file(
              downloadUrl:
                  'http://${server.address.host}:${server.port}/track.mp3',
              size: 1024 * 1024,
            ),
          ],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        );
        await _waitForLiveTask(manager);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await manager.cancelTask(1).timeout(const Duration(seconds: 5));

        expect(await sentinel.readAsString(), 'keep');
        expect(
          await File(
            '${workDir.path}${Platform.pathSeparator}Track.mp3.nameless.part',
          ).exists(),
          isFalse,
        );
      } finally {
        manager.dispose();
        await server.close(force: true);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'cancel completion allows an immediate retry of the same work',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_retry_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requestCount = 0;
      final firstRequestStarted = Completer<void>();
      unawaited(
        server.forEach((request) async {
          requestCount++;
          if (requestCount == 1 && !firstRequestStarted.isCompleted) {
            firstRequestStarted.complete();
          }
          const chunks = 64;
          request.response.headers.contentLength = 1024 * 1024;
          try {
            for (var i = 0; i < chunks; i++) {
              request.response.add(List<int>.filled(16 * 1024, 7));
              await request.response.flush();
              if (requestCount == 1) {
                await Future<void>.delayed(const Duration(milliseconds: 10));
              }
            }
          } catch (_) {
            // The first request is expected to be closed by cancellation.
          } finally {
            await request.response.close().catchError((_) {});
          }
        }),
      );
      final manager = _manager();
      try {
        final file = _file(
          downloadUrl: 'http://${server.address.host}:${server.port}/track.mp3',
          size: 1024 * 1024,
        );
        await manager.startDownload(
          work: _work(),
          selectedRoots: <AsmrTrackFile>[file],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        );
        await _waitForTaskStatus(
          manager,
          1,
          AsmrDownloadTaskStatus.downloading,
        );
        await firstRequestStarted.future.timeout(const Duration(seconds: 5));
        await manager.cancelTask(1);

        await manager.startDownload(
          work: _work(),
          selectedRoots: <AsmrTrackFile>[file],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        );
        await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

        expect(requestCount, 2);
        expect(
          await File(
            '${tempDir.path}${Platform.pathSeparator}RJ123456 - Work'
            '${Platform.pathSeparator}Track.mp3',
          ).length(),
          1024 * 1024,
        );
      } finally {
        manager.dispose();
        await server.close(force: true);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );

  test('rejects download paths that can escape the work directory', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_invalid_path_',
    );
    final manager = _manager();
    try {
      for (final invalidPath in <String>[
        '../outside.mp3',
        r'..\outside.mp3',
        '/absolute.mp3',
        r'C:\absolute.mp3',
        '//server/share.mp3',
        'folder//track.mp3',
        './track.mp3',
      ]) {
        await expectLater(
          manager.startDownload(
            work: _work(),
            selectedRoots: <AsmrTrackFile>[
              _file(title: invalidPath, downloadUrl: 'http://localhost/file'),
            ],
            destinationRoot: tempDir.path,
            conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
          ),
          throwsFormatException,
          reason: invalidPath,
        );
      }

      expect(
        await Directory(
          '${tempDir.path}${Platform.pathSeparator}RJ123456 - Work',
        ).exists(),
        isFalse,
      );
    } finally {
      manager.dispose();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  });

  test(
    'truncated responses fail without committing the final media file',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_truncated_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(
        server.forEach((request) async {
          request.response.add(List<int>.filled(128, 3));
          await request.response.close();
        }),
      );
      final manager = _manager();
      try {
        await manager.startDownload(
          work: _work(),
          selectedRoots: <AsmrTrackFile>[
            _file(
              downloadUrl:
                  'http://${server.address.host}:${server.port}/track.mp3',
              size: 1024,
            ),
          ],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        );
        await _waitForTaskStatus(
          manager,
          1,
          AsmrDownloadTaskStatus.failed,
          allowFailure: true,
        );

        final output = File(
          '${tempDir.path}${Platform.pathSeparator}RJ123456 - Work'
          '${Platform.pathSeparator}track.mp3',
        );
        expect(await output.exists(), isFalse);
        final task = manager.getTask(1);
        expect(task?.failedFiles, 1);
        expect(task?.downloadedBytes, lessThan(task!.totalBytes));
        expect(task.progress, lessThan(1));
      } finally {
        manager.dispose();
        await server.close(force: true);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );
}

AsmrDownloadManager _manager() {
  return AsmrDownloadManager(
    temporaryDirectoryProvider: () async => Directory.systemTemp,
  );
}

Future<void> _waitForLiveTask(AsmrDownloadManager manager) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (manager.hasLiveTask) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Timed out waiting for a live download task');
}

Future<void> _waitForTaskStatus(
  AsmrDownloadManager manager,
  int workId,
  AsmrDownloadTaskStatus status, {
  bool allowFailure = false,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    final task = manager.getTask(workId);
    if (task?.status == status) return;
    if (!allowFailure && task?.status == AsmrDownloadTaskStatus.failed) {
      fail('Download task failed: ${task?.error ?? task?.message}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Timed out waiting for task $workId to reach $status');
}

AsmrWork _work({DateTime? releaseDate, int dlCount = 0, double rating = 0}) {
  return AsmrWork(
    id: 1,
    title: 'Work',
    circleName: 'Circle',
    sourceId: 'RJ123456',
    sourceType: 'asmr',
    sourceUrl: '',
    coverUrl: '',
    thumbnailUrl: '',
    mainCoverUrl: '',
    releaseDate: releaseDate,
    createDate: null,
    duration: Duration.zero,
    dlCount: dlCount,
    reviewCount: 0,
    rating: rating,
    voiceActors: const <String>[],
    tags: const <String>[],
  );
}

AsmrTrackFile _file({
  required String downloadUrl,
  int size = 1,
  String title = 'Track.mp3',
}) {
  return AsmrTrackFile(
    hash: title,
    title: title,
    type: 'audio',
    streamUrl: null,
    downloadUrl: downloadUrl,
    lowQualityUrl: null,
    duration: Duration.zero,
    size: size,
    children: const <AsmrTrackFile>[],
    workId: 1,
    workTitle: 'Work',
    sourceId: 'RJ123456',
    relativePath: title,
  );
}
