import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/asmr/domain/asmr_download.dart';
import 'package:nameless_audio/core/media/audio_detail.dart';
import 'package:nameless_audio/features/asmr/domain/asmr_models.dart';
import 'package:nameless_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:nameless_audio/features/settings/application/app_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  test('partial download response must match the requested byte range', () {
    expect(
      isValidDownloadContentRange(
        'bytes 128-255/256',
        expectedStart: 128,
        responseLength: 128,
        expectedTotal: 256,
      ),
      isTrue,
    );
    for (final invalid in <String?>[
      null,
      'bytes 0-127/256',
      'bytes 128-255/512',
      'bytes 128-200/256',
    ]) {
      expect(
        isValidDownloadContentRange(
          invalid,
          expectedStart: 128,
          responseLength: 128,
          expectedTotal: 256,
        ),
        isFalse,
        reason: '$invalid',
      );
    }
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

  test('work folder name follows selected field order', () {
    const work = AsmrWork(
      id: 1,
      title: 'Work',
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
      voiceActors: <String>['Voice A', 'Voice B', 'Voice A'],
      tags: <String>[],
    );

    expect(
      buildAsmrDownloadWorkFolderName(work, const [
        AsmrDownloadFolderNameField.rjCode,
        AsmrDownloadFolderNameField.voiceActors,
        AsmrDownloadFolderNameField.circleName,
        AsmrDownloadFolderNameField.workTitle,
      ]),
      'RJ123456 - Voice A、Voice B - Circle - Work',
    );
    expect(buildAsmrDownloadWorkFolderName(work, const []), 'Work');
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
      expect(manager.getTask(1)?.status, AsmrDownloadTaskStatus.completed);
      expect(manager.taskIds, isEmpty);
      expect(manager.buttonViewState.visible, isFalse);
      expect(manager.taskShellViewState.hasTask, isFalse);
      manager.dispose();
    },
  );

  test('completed task bytes remain in aggregate progress while active', () {
    final manager = _manager();
    final startedAt = DateTime(2026);
    manager.debugSetCurrentTaskForTesting(
      AsmrDownloadTaskSnapshot(
        work: _work(),
        destinationRoot: 'C:\\Downloads',
        workFolderName: 'Work',
        conflictPolicy: AsmrDownloadConflictPolicy.skip,
        status: AsmrDownloadTaskStatus.completed,
        totalFiles: 1,
        completedFiles: 1,
        skippedFiles: 0,
        failedFiles: 0,
        totalBytes: 1024,
        downloadedBytes: 1024,
        startedAt: startedAt,
      ),
    );
    manager.debugSetCurrentTaskForTesting(
      AsmrDownloadTaskSnapshot(
        work: _work(id: 2),
        destinationRoot: 'C:\\Downloads',
        workFolderName: 'Work 2',
        conflictPolicy: AsmrDownloadConflictPolicy.skip,
        status: AsmrDownloadTaskStatus.downloading,
        totalFiles: 1,
        completedFiles: 0,
        skippedFiles: 0,
        failedFiles: 0,
        totalBytes: 2048,
        downloadedBytes: 512,
        startedAt: startedAt,
      ),
    );

    expect(manager.taskIds, <int>[2]);
    expect(manager.buttonViewState.visible, isTrue);
    expect(manager.buttonViewState.progress, 0.5);
    expect(manager.taskShellViewState.hasTask, isTrue);
    manager.dispose();
  });

  test('only the latest completed task snapshot is retained', () {
    final manager = _manager();
    final startedAt = DateTime(2026);

    AsmrDownloadTaskSnapshot completedTask(int workId) {
      return AsmrDownloadTaskSnapshot(
        work: _work(id: workId),
        destinationRoot: 'C:\\Downloads',
        workFolderName: 'Work $workId',
        conflictPolicy: AsmrDownloadConflictPolicy.skip,
        status: AsmrDownloadTaskStatus.completed,
        totalFiles: 1,
        completedFiles: 1,
        skippedFiles: 0,
        failedFiles: 0,
        totalBytes: 1024,
        downloadedBytes: 1024,
        startedAt: startedAt,
      );
    }

    manager.debugSetCurrentTaskForTesting(completedTask(1));
    manager.debugSetCurrentTaskForTesting(completedTask(2));

    expect(manager.getTask(1), isNull);
    expect(manager.getTask(2)?.status, AsmrDownloadTaskStatus.completed);
    expect(manager.tasks, hasLength(1));
    expect(manager.taskIds, isEmpty);
    manager.dispose();
  });

  test('all non-completed task statuses remain visible', () {
    const visibleStatuses = <AsmrDownloadTaskStatus>[
      AsmrDownloadTaskStatus.idle,
      AsmrDownloadTaskStatus.preparing,
      AsmrDownloadTaskStatus.downloading,
      AsmrDownloadTaskStatus.paused,
      AsmrDownloadTaskStatus.failed,
    ];

    for (final status in visibleStatuses) {
      final manager = _manager();
      manager.debugSetCurrentTaskForTesting(
        AsmrDownloadTaskSnapshot(
          work: _work(),
          destinationRoot: 'C:\\Downloads',
          workFolderName: 'Work',
          conflictPolicy: AsmrDownloadConflictPolicy.skip,
          status: status,
          totalFiles: 1,
          completedFiles: 0,
          skippedFiles: 0,
          failedFiles: status == AsmrDownloadTaskStatus.failed ? 1 : 0,
          totalBytes: 1024,
          downloadedBytes: 0,
          startedAt: DateTime(2026),
        ),
      );

      expect(manager.taskIds, <int>[1], reason: '$status');
      expect(manager.buttonViewState.visible, isTrue, reason: '$status');
      expect(manager.taskShellViewState.hasTask, isTrue, reason: '$status');
      manager.dispose();
    }
  });

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

  test(
    'parallel file completion does not reset aggregate byte progress',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_parallel_progress_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(
        server.forEach((request) async {
          request.response.headers.contentLength = 1024;
          for (var chunk = 0; chunk < 4; chunk++) {
            request.response.add(List<int>.filled(256, chunk));
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 8));
          }
          await request.response.close();
        }),
      );
      final manager = _manager();
      final observed = <int>[];
      manager.addListener(() {
        final task = manager.getTask(1);
        if (task != null && task.status == AsmrDownloadTaskStatus.downloading) {
          observed.add(task.downloadedBytes);
        }
      });
      try {
        await manager.startDownload(
          work: _work(),
          selectedRoots: <AsmrTrackFile>[
            for (var index = 0; index < 3; index++)
              _file(
                title: 'Track $index.mp3',
                downloadUrl:
                    'http://${server.address.host}:${server.port}/track-$index.mp3',
                size: 1024,
              ),
          ],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
          saveMetadata: false,
        );
        await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

        expect(observed, isNotEmpty);
        for (var index = 1; index < observed.length; index++) {
          expect(
            observed[index],
            greaterThanOrEqualTo(observed[index - 1]),
            reason: 'aggregate progress regressed: $observed',
          );
        }
        expect(manager.getTask(1)?.downloadedBytes, 3072);
      } finally {
        manager.dispose();
        await server.close(force: true);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );

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
      persistTasks: false,
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
      expect(manager.getTask(1)?.workFolderName, 'Work');
      expect(
        await File(
          '${tempDir.path}${Platform.pathSeparator}Work'
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

  test('failed local replacement restores the previous file', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_replace_failure_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });
    final target = File('${tempDir.path}${Platform.pathSeparator}track.mp3');
    final staging = File('${target.path}.nameless.part');
    await target.writeAsBytes(<int>[1, 2, 3], flush: true);
    await staging.writeAsBytes(<int>[7, 8, 9], flush: true);
    var renameCount = 0;

    await expectLater(
      commitLocalDownloadedFile(
        staging: staging,
        target: target,
        rename: (file, destination) async {
          renameCount++;
          if (renameCount == 2) {
            throw const FileSystemException('injected commit failure');
          }
          return file.rename(destination);
        },
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await target.readAsBytes(), <int>[1, 2, 3]);
    expect(await File('${target.path}.nameless.bak').exists(), isFalse);
    expect(await staging.exists(), isTrue);
  });

  test(
    'skip preserves an existing wrong-sized local file without a network request',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_skip_existing_',
      );
      final workDir = Directory('${tempDir.path}${Platform.pathSeparator}Work');
      await workDir.create(recursive: true);
      final target = File('${workDir.path}${Platform.pathSeparator}Track.mp3');
      await target.writeAsBytes(<int>[1, 2, 3], flush: true);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requestCount = 0;
      unawaited(
        server.forEach((request) async {
          requestCount++;
          request.response.add(List<int>.filled(256, 7));
          await request.response.close();
        }),
      );
      final manager = _manager();
      try {
        await manager.startDownload(
          work: _work(),
          selectedRoots: <AsmrTrackFile>[
            _file(
              size: 256,
              downloadUrl:
                  'http://${server.address.host}:${server.port}/track.mp3',
            ),
          ],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.skip,
        );
        await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

        final task = manager.getTask(1);
        expect(requestCount, 0);
        expect(await target.readAsBytes(), <int>[1, 2, 3]);
        expect(await File('${target.path}.nameless.part').exists(), isFalse);
        expect(task?.skippedFiles, 1);
        expect(task?.fileDownloadedBytes['Track.mp3'], 256);
        expect(task?.downloadedBytes, task?.totalBytes);
      } finally {
        manager.dispose();
        await server.close(force: true);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'local replacement recovers an interrupted backup and cleans artifacts',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_replace_recovery_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final target = File('${tempDir.path}${Platform.pathSeparator}track.mp3');
      final backup = File('${target.path}.nameless.bak');
      final staging = File('${target.path}.nameless.part');
      await backup.writeAsBytes(<int>[1, 2, 3], flush: true);
      await staging.writeAsBytes(<int>[7, 8, 9], flush: true);

      await commitLocalDownloadedFile(staging: staging, target: target);

      expect(await target.readAsBytes(), <int>[7, 8, 9]);
      expect(await backup.exists(), isFalse);
      expect(await staging.exists(), isFalse);
    },
  );

  test('download backup includes ASMR.ONE extended metadata', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_backup_',
    );
    final manager = _manager();
    final work = _work(
      releaseDate: DateTime(2024, 5, 6),
      duration: const Duration(hours: 1, minutes: 2, seconds: 3),
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
          '${tempDir.path}${Platform.pathSeparator}Work'
          '${Platform.pathSeparator}nameless-audio.json';
      final backup = await File(backupPath).readAsString();
      final detail = AudioDetail.fromBackupJson(
        AudioDetailTarget.libraryRootFolder(
          '${tempDir.path}${Platform.pathSeparator}Work',
        ),
        Map<String, dynamic>.from(jsonDecode(backup) as Map),
      );
      expect(detail.releaseDate, DateTime(2024, 5, 6));
      expect(detail.duration, const Duration(hours: 1, minutes: 2, seconds: 3));
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
    'metadata backup can be disabled without affecting file totals',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_without_metadata_',
      );
      final manager = _manager();
      try {
        await manager.startDownload(
          work: _work(),
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
          saveMetadata: false,
          folderNameFields: const [
            AsmrDownloadFolderNameField.rjCode,
            AsmrDownloadFolderNameField.workTitle,
          ],
        );
        await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

        final task = manager.getTask(1)!;
        expect(task.workFolderName, 'RJ123456 - Work');
        expect(task.saveMetadata, isFalse);
        expect(task.totalFiles, 0);
        expect(task.completedFiles, 0);
        expect(task.totalBytes, 0);
        expect(task.downloadedBytes, 0);
        expect(
          await File(
            '${tempDir.path}${Platform.pathSeparator}RJ123456 - Work'
            '${Platform.pathSeparator}nameless-audio.json',
          ).exists(),
          isFalse,
        );
      } finally {
        manager.dispose();
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'canceling a paused download removes task and downloaded files',
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
        await manager.pauseTask(1);
        await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.paused);
        await manager.cancelTask(1).timeout(const Duration(seconds: 5));

        expect(manager.getTask(1), isNull);
        expect(
          await Directory(
            '${tempDir.path}${Platform.pathSeparator}Work',
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
      final workDir = Directory('${tempDir.path}${Platform.pathSeparator}Work');
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
            '${tempDir.path}${Platform.pathSeparator}Work'
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
          '${tempDir.path}${Platform.pathSeparator}Work',
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
          '${tempDir.path}${Platform.pathSeparator}Work'
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

  test(
    'pausing preserves completed files and their recorded progress',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_pause_progress_',
      );
      const fastBytes = 1024;
      const slowBytes = 256 * 1024;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var fastRequests = 0;
      unawaited(
        server.forEach((request) async {
          final isFast = request.uri.path.endsWith('/fast.mp3');
          if (isFast) {
            fastRequests++;
            request.response.contentLength = fastBytes;
            request.response.add(List<int>.filled(fastBytes, 3));
            await request.response.close();
            return;
          }

          final range = request.headers.value(HttpHeaders.rangeHeader);
          final start = range == null
              ? 0
              : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
          if (start > 0) {
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-${slowBytes - 1}/$slowBytes',
            );
          }
          request.response.contentLength = slowBytes - start;
          try {
            for (var offset = start; offset < slowBytes; offset += 8192) {
              final length = (slowBytes - offset).clamp(0, 8192);
              request.response.add(List<int>.filled(length, 7));
              await request.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 4));
            }
          } catch (_) {
            // Pausing closes the active response while retaining its progress.
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
                  'http://${server.address.host}:${server.port}/fast.mp3',
              size: fastBytes,
              title: 'Fast.mp3',
            ),
            _file(
              downloadUrl:
                  'http://${server.address.host}:${server.port}/slow.mp3',
              size: slowBytes,
              title: 'Slow.mp3',
            ),
          ],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
          saveMetadata: false,
        );

        final workDir = Directory(
          '${tempDir.path}${Platform.pathSeparator}Work',
        );
        final fastFile = File(
          '${workDir.path}${Platform.pathSeparator}Fast.mp3',
        );
        final slowPart = File(
          '${workDir.path}${Platform.pathSeparator}Slow.mp3.nameless.part',
        );
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while ((!await fastFile.exists() ||
                !await slowPart.exists() ||
                await slowPart.length() < 32768) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        await manager.pauseTask(1);
        final paused = manager.getTask(1);
        expect(paused?.status, AsmrDownloadTaskStatus.paused);
        expect(paused?.completedFiles, 1);
        expect(paused?.completedFilePaths, contains('Fast.mp3'));
        expect(paused?.fileDownloadedBytes['Fast.mp3'], fastBytes);
        expect(paused?.downloadedBytes, greaterThan(fastBytes));
        expect(await fastFile.length(), fastBytes);

        await manager.resumeTask(1);
        await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);
        final completed = manager.getTask(1);
        expect(completed?.completedFiles, 2);
        expect(completed?.skippedFiles, 0);
        expect(fastRequests, 1);
      } finally {
        manager.dispose();
        await server.close(force: true);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'paused download survives restart and resumes its partial file',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await AppPreferences.init();
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_resume_',
      );
      const totalBytes = 512 * 1024;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final rangeStarts = <int>[];
      var rejectedRange = false;
      unawaited(
        server.forEach((request) async {
          final range = request.headers.value(HttpHeaders.rangeHeader);
          final start = range == null
              ? 0
              : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
          rangeStarts.add(start);
          if (start > 0 && !rejectedRange) {
            rejectedRange = true;
            request.response.statusCode =
                HttpStatus.requestedRangeNotSatisfiable;
            request.response.contentLength = 0;
            await request.response.close();
            return;
          }
          if (start > 0) {
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-${totalBytes - 1}/$totalBytes',
            );
          }
          request.response.contentLength = totalBytes - start;
          try {
            for (var offset = start; offset < totalBytes; offset += 8192) {
              final length = (totalBytes - offset).clamp(0, 8192);
              request.response.add(List<int>.filled(length, 7));
              await request.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 4));
            }
          } catch (_) {
            // Pausing closes the first request while retaining its staging file.
          } finally {
            await request.response.close().catchError((_) {});
          }
        }),
      );

      final firstManager = AsmrDownloadManager(
        temporaryDirectoryProvider: () async => Directory.systemTemp,
      );
      AsmrDownloadManager? restoredManager;
      try {
        final target = File(
          '${tempDir.path}${Platform.pathSeparator}Work'
          '${Platform.pathSeparator}Track.mp3',
        );
        await target.parent.create(recursive: true);
        await target.writeAsBytes(const <int>[1, 2, 3], flush: true);
        await firstManager.startDownload(
          work: _work(),
          selectedRoots: <AsmrTrackFile>[
            _file(
              downloadUrl:
                  'http://${server.address.host}:${server.port}/track.mp3',
              size: totalBytes,
            ),
          ],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        );
        final part = File(
          '${tempDir.path}${Platform.pathSeparator}Work'
          '${Platform.pathSeparator}Track.mp3.nameless.part',
        );
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while ((!await part.exists() || await part.length() < 32768) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await firstManager.pauseTask(1);
        await _waitForTaskStatus(
          firstManager,
          1,
          AsmrDownloadTaskStatus.paused,
        );
        final pausedBytes = await part.length();
        expect(pausedBytes, greaterThan(0));
        expect(pausedBytes, lessThan(totalBytes));

        final persistDeadline = DateTime.now().add(const Duration(seconds: 5));
        while ((await AppPreferences.getString(
                  AppPreferences.asmrDownloadTasksKey,
                )) ==
                null &&
            DateTime.now().isBefore(persistDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        firstManager.dispose();

        restoredManager = AsmrDownloadManager(
          temporaryDirectoryProvider: () async => Directory.systemTemp,
        );
        await restoredManager.initialize();
        final restoredTask = restoredManager.getTask(1);
        expect(restoredTask?.status, AsmrDownloadTaskStatus.paused);
        expect(restoredManager.taskIds, <int>[1]);
        expect(restoredManager.buttonViewState.visible, isTrue);
        expect(
          restoredTask?.fileDownloadedBytes['Track.mp3'],
          greaterThanOrEqualTo(pausedBytes),
        );

        await restoredManager.resumeTask(1);
        await _waitForTaskStatus(
          restoredManager,
          1,
          AsmrDownloadTaskStatus.completed,
        );
        expect(rangeStarts, contains(pausedBytes));
        expect(rangeStarts.last, 0);
        expect(await target.length(), totalBytes);
        expect(
          restoredManager.getTask(1)?.downloadedBytes,
          restoredManager.getTask(1)?.totalBytes,
        );
      } finally {
        firstManager.dispose();
        restoredManager?.dispose();
        await server.close(force: true);
        await AppPreferences.remove(AppPreferences.asmrDownloadTasksKey);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'dispose cancels active downloads and does not start queued work',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_dispose_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final releaseResponses = Completer<void>();
      var requestCount = 0;
      unawaited(
        server.forEach((request) async {
          requestCount++;
          request.response.contentLength = 1024;
          request.response.add(List<int>.filled(128, requestCount));
          try {
            await releaseResponses.future;
            await request.response.close();
          } catch (_) {
            // Forced client shutdown is the behavior under test.
          }
        }),
      );
      final manager = _manager();
      var notificationCount = 0;
      manager.addListener(() => notificationCount++);
      try {
        final downloadUrl =
            'http://${server.address.host}:${server.port}/track.mp3';
        for (var workId = 1; workId <= 4; workId++) {
          await manager.startDownload(
            work: _work(id: workId),
            selectedRoots: <AsmrTrackFile>[
              _file(downloadUrl: downloadUrl, size: 1024),
            ],
            destinationRoot: tempDir.path,
            conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
          );
        }
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (requestCount < 3 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(requestCount, 3);

        manager.dispose();
        final notificationsAtDispose = notificationCount;
        releaseResponses.complete();
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(requestCount, 3);
        expect(notificationCount, notificationsAtDispose);
        for (var workId = 1; workId <= 4; workId++) {
          final title = workId == 1 ? 'Work' : 'Work $workId';
          final output = File(
            '${tempDir.path}${Platform.pathSeparator}$title'
            '${Platform.pathSeparator}track.mp3',
          );
          expect(await output.exists(), isFalse);
        }
      } finally {
        if (!releaseResponses.isCompleted) releaseResponses.complete();
        await server.close(force: true);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );
}

AsmrDownloadManager _manager() {
  return AsmrDownloadManager(
    temporaryDirectoryProvider: () async => Directory.systemTemp,
    persistTasks: false,
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

AsmrWork _work({
  int id = 1,
  DateTime? releaseDate,
  Duration duration = Duration.zero,
  int dlCount = 0,
  double rating = 0,
}) {
  return AsmrWork(
    id: id,
    title: id == 1 ? 'Work' : 'Work $id',
    circleName: 'Circle',
    sourceId: id == 1 ? 'RJ123456' : 'RJ12345$id',
    sourceType: 'asmr',
    sourceUrl: '',
    coverUrl: '',
    thumbnailUrl: '',
    mainCoverUrl: '',
    releaseDate: releaseDate,
    createDate: null,
    duration: duration,
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
