import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_download.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/features/library/data/audio_detail_json_codec.dart';
import 'package:doujin_audio/features/settings/application/app_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as path;

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

  test(
    'SAF starts deduplicate a work and isolate different work roots',
    () async {
      final gateway = _ExistingJsonSafGateway();
      final manager = AsmrDownloadManager(
        fileCacheGateway: gateway,
        temporaryDirectoryProvider: () async => Directory.systemTemp,
        persistTasks: false,
      );
      const destinationRoot =
          'content://com.android.externalstorage.documents/tree/primary%3ADownload';

      try {
        Future<void> start() => manager.startDownload(
          work: _work(),
          selectedRoots: <AsmrTrackFile>[
            _file(downloadUrl: 'https://example.invalid/track.mp3'),
          ],
          destinationRoot: destinationRoot,
          conflictPolicy: AsmrDownloadConflictPolicy.skip,
          saveMetadata: false,
        );
        await Future.wait<void>(<Future<void>>[start(), start()]);
        await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);
        await manager.startDownload(
          work: _work(id: 2),
          selectedRoots: <AsmrTrackFile>[
            _file(downloadUrl: 'https://example.invalid/track.mp3'),
          ],
          destinationRoot: destinationRoot,
          conflictPolicy: AsmrDownloadConflictPolicy.skip,
          saveMetadata: false,
        );
        await _waitForTaskStatus(manager, 2, AsmrDownloadTaskStatus.completed);

        expect(gateway.ensureFolderCount, 2);
        expect(gateway.ensuredRelativePaths.toSet(), hasLength(2));
        expect(gateway.ensuredRelativePaths, contains(endsWith('[1]')));
        expect(gateway.ensuredRelativePaths, contains(endsWith('[2]')));
        expect(manager.getTask(2)?.workRootPath, endsWith('[2]'));
      } finally {
        manager.dispose();
      }
    },
  );

  test('work folder name follows selected field order and appends work id', () {
    final work = AsmrWork(
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
      voiceActors: const <String>['Voice A', 'Voice B', 'Voice A'],
      tags: const <String>[],
    );

    expect(
      buildAsmrDownloadWorkFolderName(work, const [
        AsmrDownloadFolderNameField.rjCode,
        AsmrDownloadFolderNameField.voiceActors,
        AsmrDownloadFolderNameField.circleName,
        AsmrDownloadFolderNameField.workTitle,
      ]),
      'RJ123456 - Voice A、Voice B - Circle - Work [1]',
    );
    expect(
      buildAsmrDownloadWorkFolderName(work, const []),
      endsWith('Work [1]'),
    );
  });

  test('sanitized duplicate titles use distinct work folders', () {
    final first = _work(title: 'Same:Title');
    final second = _work(id: 2, title: 'Same/Title');

    expect(buildAsmrDownloadWorkFolderName(first, const []), 'Same_Title [1]');
    expect(buildAsmrDownloadWorkFolderName(second, const []), 'Same_Title [2]');
  });

  test('startDownload rejects a non-positive work id', () async {
    final manager = _manager();
    addTearDown(manager.dispose);

    await expectLater(
      manager.startDownload(
        work: _work(id: 0),
        selectedRoots: <AsmrTrackFile>[
          _file(downloadUrl: 'https://example.invalid/track.mp3'),
        ],
        destinationRoot: Directory.systemTemp.path,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
      ),
      throwsArgumentError,
    );
  });

  test('task snapshot exposes a decoded destination path for SAF folders', () {
    const destinationRoot =
        'content://com.android.externalstorage.documents/tree/primary%3ADownload';
    const workFolderName = 'RJ123456 - 羊娘';
    final task = AsmrDownloadTaskSnapshot(
      work: AsmrWork(
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
        voiceActors: const <String>[],
        tags: const <String>[],
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
      manager.taskStream(1).listen((task) {
        if (task != null) notifications.add(task);
      });
      await Future<void>.delayed(Duration.zero);

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
      manager.taskStream(1).skip(1).listen((_) => notifications++);

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

  test(
    'large download chunks cannot bypass the notification interval',
    () async {
      final manager = _manager();
      final work = _work();
      manager.debugSetCurrentTaskForTesting(
        AsmrDownloadTaskSnapshot(
          work: work,
          destinationRoot: 'C:\\Downloads',
          workFolderName: 'RJ123456 - Work',
          conflictPolicy: AsmrDownloadConflictPolicy.skip,
          status: AsmrDownloadTaskStatus.downloading,
          totalFiles: 1,
          completedFiles: 0,
          skippedFiles: 0,
          failedFiles: 0,
          totalBytes: 1024 * 1024,
          downloadedBytes: 0,
          startedAt: DateTime(2026),
        ),
      );
      var notifications = 0;
      manager.taskStream(1).skip(1).listen((_) => notifications++);

      for (var index = 0; index < 4; index++) {
        manager.debugRecordDownloadChunkForTesting(
          1,
          'track.mp3',
          256 * 1024,
          (index + 1) * 256 * 1024,
        );
      }

      expect(notifications, 0);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(notifications, 1);
      expect(manager.getTask(1)?.downloadedBytes, 1024 * 1024);
      manager.dispose();
    },
  );

  test(
    'single-task progress does not notify unrelated task or task ids',
    () async {
      final manager = _manager();
      final startedAt = DateTime(2026);
      for (var workId = 1; workId <= 100; workId++) {
        manager.debugSetCurrentTaskForTesting(
          AsmrDownloadTaskSnapshot(
            work: _work(id: workId),
            destinationRoot: 'C:\\Downloads',
            workFolderName: 'Work $workId',
            conflictPolicy: AsmrDownloadConflictPolicy.skip,
            status: AsmrDownloadTaskStatus.downloading,
            totalFiles: 1,
            completedFiles: 0,
            skippedFiles: 0,
            failedFiles: 0,
            totalBytes: 1024,
            downloadedBytes: 0,
            startedAt: startedAt,
          ),
        );
      }
      var targetEvents = 0;
      var unrelatedEvents = 0;
      var taskIdEvents = 0;
      manager.taskStream(1).skip(1).listen((_) => targetEvents++);
      manager.taskStream(2).skip(1).listen((_) => unrelatedEvents++);
      manager.taskIdsStream.skip(1).listen((_) => taskIdEvents++);

      manager.debugSetCurrentTaskForTesting(
        manager.getTask(1)!.copyWith(downloadedBytes: 1),
        progressOnly: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(targetEvents, 1);
      expect(unrelatedEvents, 0);
      expect(taskIdEvents, 0);
      manager.dispose();
    },
  );

  test('download progress does not change persisted URI references', () async {
    final manager = _manager();
    manager.debugSetCurrentTaskForTesting(
      AsmrDownloadTaskSnapshot(
        work: _work(),
        destinationRoot:
            'content://com.android.externalstorage.documents/tree/primary%3AMusic',
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
      ),
    );
    final initialRevision = manager.persistedUriReferenceRevision;
    final revisions = <int>[];
    final subscription = manager.persistedUriReferenceRevisions.listen(
      revisions.add,
    );

    for (var index = 0; index < 20; index++) {
      manager.debugRecordDownloadChunkForTesting(1, 'track.mp3', 1, index + 1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(manager.persistedUriReferenceRevision, initialRevision);
    expect(revisions, isEmpty);
    await subscription.cancel();
    manager.dispose();
  });

  test('initialization emits URI readiness even when no tasks exist', () async {
    final manager = _manager();
    final revisions = <int>[];
    final subscription = manager.persistedUriReferenceRevisions.listen(
      revisions.add,
    );

    await manager.initialize();

    expect(manager.persistedUriReferencesReady, isTrue);
    expect(revisions, <int>[1]);
    await subscription.cancel();
    manager.dispose();
  });

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

  test('saves the preferred cover in the shared Cover folder', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_cover_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      server.forEach((request) async {
        if (request.uri.path == '/cover') {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.contentLength = 4;
          request.response.add(const <int>[1, 2, 3, 4]);
        } else {
          request.response.contentLength = 3;
          request.response.add(const <int>[5, 6, 7]);
        }
        await request.response.close();
      }),
    );
    final manager = _manager();
    try {
      final baseUrl = 'http://${server.address.host}:${server.port}';
      await manager.startDownload(
        work: _work(mainCoverUrl: '$baseUrl/cover'),
        selectedRoots: <AsmrTrackFile>[
          _file(downloadUrl: '$baseUrl/track.mp3', size: 3),
        ],
        destinationRoot: tempDir.path,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        saveMetadata: false,
      );
      await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

      final cover = File(path.join(tempDir.path, 'Cover', 'RJ123456.png'));
      expect(await cover.readAsBytes(), const <int>[1, 2, 3, 4]);
      expect(manager.getTask(1)?.totalFiles, 2);
      expect(manager.getTask(1)?.totalBytes, 3);
      expect(manager.getTask(1)?.downloadedBytes, 3);
      expect(manager.getTask(1)?.coverOutputPath, cover.path);

      await manager.deleteTask(1);
      expect(await cover.exists(), isFalse);
    } finally {
      manager.dispose();
      await server.close(force: true);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  });

  test(
    'failed cover marks the task failed and retry only fetches cover',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_cover_retry_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var audioRequests = 0;
      var coverRequests = 0;
      var coverSucceeds = false;
      unawaited(
        server.forEach((request) async {
          if (request.uri.path == '/cover.jpg') {
            coverRequests++;
            if (!coverSucceeds) {
              request.response.statusCode = HttpStatus.serviceUnavailable;
            } else {
              request.response.headers.contentType = ContentType(
                'image',
                'jpeg',
              );
              request.response.contentLength = 2;
              request.response.add(const <int>[8, 9]);
            }
          } else {
            audioRequests++;
            request.response.contentLength = 1;
            request.response.add(const <int>[7]);
          }
          await request.response.close();
        }),
      );
      final manager = AsmrDownloadManager(
        temporaryDirectoryProvider: () async => Directory.systemTemp,
        automaticFileRetryDelay: Duration.zero,
        persistTasks: false,
      );
      try {
        final baseUrl = 'http://${server.address.host}:${server.port}';
        await manager.startDownload(
          work: _work(mainCoverUrl: '$baseUrl/cover.jpg'),
          selectedRoots: <AsmrTrackFile>[
            _file(downloadUrl: '$baseUrl/track.mp3'),
          ],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
          saveMetadata: false,
          automaticFileRetryCount: 3,
        );
        await _waitForTaskStatus(
          manager,
          1,
          AsmrDownloadTaskStatus.failed,
          allowFailure: true,
        );
        expect(audioRequests, 1);
        expect(coverRequests, 4);
        expect(manager.getTask(1)?.failedFiles, 1);

        coverSucceeds = true;
        await manager.startDownload(
          work: _work(mainCoverUrl: '$baseUrl/cover.jpg'),
          selectedRoots: <AsmrTrackFile>[
            _file(downloadUrl: '$baseUrl/track.mp3'),
          ],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        );
        await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

        expect(audioRequests, 1);
        expect(coverRequests, 5);
        expect(
          await File(
            path.join(tempDir.path, 'Cover', 'RJ123456.jpg'),
          ).readAsBytes(),
          const <int>[8, 9],
        );
      } finally {
        manager.dispose();
        await server.close(force: true);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );

  test('rejects a non-image response even when the URL ends in jpg', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_cover_content_type_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      server.forEach((request) async {
        if (request.uri.path == '/cover.jpg') {
          request.response.headers.contentType = ContentType.html;
          request.response.contentLength = 4;
          request.response.write('oops');
        } else {
          request.response.contentLength = 1;
          request.response.add(const <int>[1]);
        }
        await request.response.close();
      }),
    );
    final manager = _manager();
    try {
      final baseUrl = 'http://${server.address.host}:${server.port}';
      await manager.startDownload(
        work: _work(mainCoverUrl: '$baseUrl/cover.jpg'),
        selectedRoots: <AsmrTrackFile>[
          _file(downloadUrl: '$baseUrl/track.mp3'),
        ],
        destinationRoot: tempDir.path,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        saveMetadata: false,
      );
      await _waitForTaskStatus(
        manager,
        1,
        AsmrDownloadTaskStatus.failed,
        allowFailure: true,
      );

      expect(manager.getTask(1)?.failedFiles, 1);
      expect(
        await File(path.join(tempDir.path, 'Cover', 'RJ123456.jpg')).exists(),
        isFalse,
      );
    } finally {
      manager.dispose();
      await server.close(force: true);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  });

  test('pauses and resumes a partial cover download', () async {
    const coverBytes = 512 * 1024;
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_cover_resume_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final firstCoverStarted = Completer<void>();
    var coverRequests = 0;
    unawaited(
      server.forEach((request) async {
        if (request.uri.path != '/cover.jpg') {
          request.response.contentLength = 1;
          request.response.add(const <int>[1]);
          await request.response.close();
          return;
        }

        coverRequests++;
        if (!firstCoverStarted.isCompleted) firstCoverStarted.complete();
        final range = request.headers.value(HttpHeaders.rangeHeader);
        final start =
            int.tryParse(
              RegExp(r'^bytes=(\d+)-$').firstMatch(range ?? '')?.group(1) ?? '',
            ) ??
            0;
        if (start > 0) {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${coverBytes - 1}/$coverBytes',
          );
        }
        request.response.headers.contentType = ContentType('image', 'jpeg');
        request.response.contentLength = coverBytes - start;
        try {
          for (var offset = start; offset < coverBytes; offset += 4096) {
            final length = (coverBytes - offset).clamp(0, 4096);
            request.response.add(List<int>.filled(length, 6));
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        } catch (_) {
          // Pausing closes the first response while preserving its staging file.
        } finally {
          await request.response.close().catchError((_) {});
        }
      }),
    );
    final manager = AsmrDownloadManager(
      temporaryDirectoryProvider: () async => Directory.systemTemp,
      automaticFileRetryDelay: Duration.zero,
      persistTasks: false,
    );
    try {
      final baseUrl = 'http://${server.address.host}:${server.port}';
      await manager.startDownload(
        work: _work(mainCoverUrl: '$baseUrl/cover.jpg'),
        selectedRoots: <AsmrTrackFile>[
          _file(downloadUrl: '$baseUrl/track.mp3'),
        ],
        destinationRoot: tempDir.path,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        saveMetadata: false,
      );
      await firstCoverStarted.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await manager.pauseTask(1);
      await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.paused);

      await manager.resumeTask(1);
      await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

      expect(coverRequests, greaterThanOrEqualTo(2));
      expect(
        await File(path.join(tempDir.path, 'Cover', 'RJ123456.jpg')).length(),
        coverBytes,
      );
    } finally {
      manager.dispose();
      await server.close(force: true);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  });

  test('saves a cover through an Android SAF destination', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      server.forEach((request) async {
        request.response.headers.contentType = request.uri.path.endsWith('.png')
            ? ContentType('image', 'png')
            : ContentType.binary;
        request.response.contentLength = 1;
        request.response.add(const <int>[1]);
        await request.response.close();
      }),
    );
    final gateway = _RecordingSafGateway();
    final manager = AsmrDownloadManager(
      fileCacheGateway: gateway,
      temporaryDirectoryProvider: () async => Directory.systemTemp,
      automaticFileRetryDelay: Duration.zero,
      persistTasks: false,
    );
    const destinationRoot =
        'content://com.android.externalstorage.documents/tree/primary%3ADownload';
    try {
      final baseUrl = 'http://${server.address.host}:${server.port}';
      await manager.startDownload(
        work: _work(mainCoverUrl: '$baseUrl/cover.png'),
        selectedRoots: <AsmrTrackFile>[
          _file(downloadUrl: '$baseUrl/track.mp3'),
        ],
        destinationRoot: destinationRoot,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        saveMetadata: false,
      );
      await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

      expect(gateway.copiedRelativePaths, contains('Track.mp3'));
      expect(gateway.copiedRelativePaths, contains('Cover/RJ123456.png'));
      expect(gateway.ensuredRelativePaths, contains('Cover'));

      await manager.deleteTask(1);
      expect(
        gateway.deletedPaths,
        contains('$destinationRoot::Cover/RJ123456.png'),
      );
    } finally {
      manager.dispose();
      await server.close(force: true);
    }
  });

  test(
    'updates concurrent work scheduling without canceling active tasks',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_work_concurrency_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      var requests = 0;
      unawaited(
        server.forEach((request) async {
          requests++;
          await release.future;
          request.response.contentLength = 1;
          request.response.add(const <int>[1]);
          await request.response.close();
        }),
      );
      final manager = AsmrDownloadManager(
        temporaryDirectoryProvider: () async => Directory.systemTemp,
        maxConcurrentDownloads: 1,
        persistTasks: false,
      );
      try {
        final baseUrl = 'http://${server.address.host}:${server.port}';
        for (var id = 1; id <= 2; id++) {
          await manager.startDownload(
            work: _work(id: id),
            selectedRoots: <AsmrTrackFile>[
              _file(downloadUrl: '$baseUrl/$id.mp3'),
            ],
            destinationRoot: tempDir.path,
            conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
            saveMetadata: false,
          );
        }
        await _waitForRequestCount(() => requests, 1);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(requests, 1);

        manager.setMaxConcurrentDownloads(2);
        await _waitForRequestCount(() => requests, 2);
        manager.setMaxConcurrentDownloads(1);
        await manager.startDownload(
          work: _work(id: 3),
          selectedRoots: <AsmrTrackFile>[_file(downloadUrl: '$baseUrl/3.mp3')],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
          saveMetadata: false,
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(requests, 2);

        release.complete();
        await _waitForRequestCount(() => requests, 3);
        final outputFiles = <File>[
          for (var id = 1; id <= 3; id++)
            File(
              path.join(
                tempDir.path,
                id == 1 ? 'Work [1]' : 'Work $id [$id]',
                'Track.mp3',
              ),
            ),
        ];
        await _waitForFiles(outputFiles);
        for (var id = 1; id <= 3; id++) {
          expect(await outputFiles[id - 1].readAsBytes(), const <int>[1]);
        }
        expect(requests, 3);
      } finally {
        if (!release.isCompleted) release.complete();
        manager.dispose();
        await server.close(force: true);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );

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
      manager.taskStream(1).skip(1).listen((task) {
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
      expect(manager.getTask(1)?.workFolderName, 'Work [1]');
      expect(
        await File(
          '${tempDir.path}${Platform.pathSeparator}Work [1]'
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
    final staging = File('${target.path}.doujin.part');
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
    expect(await File('${target.path}.doujin.bak').exists(), isFalse);
    expect(await staging.exists(), isTrue);
  });

  test(
    'skip preserves an existing wrong-sized local file without a network request',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_skip_existing_',
      );
      final workDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}Work [1]',
      );
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
        expect(await File('${target.path}.doujin.part').exists(), isFalse);
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
      final backup = File('${target.path}.doujin.bak');
      final staging = File('${target.path}.doujin.part');
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
        selectedRoots: <AsmrTrackFile>[
          AsmrTrackFile(
            hash: 'folder',
            title: 'Folder',
            type: 'folder',
            streamUrl: null,
            downloadUrl: null,
            lowQualityUrl: null,
            duration: Duration.zero,
            size: 0,
            children: const <AsmrTrackFile>[],
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
          '${tempDir.path}${Platform.pathSeparator}Work [1]'
          '${Platform.pathSeparator}doujin-audio.json';
      final detail = const AudioDetailJsonCodec().decode(
        File(backupPath).readAsBytesSync(),
        AudioDetailTarget.libraryRootFolder(
          '${tempDir.path}${Platform.pathSeparator}Work [1]',
        ),
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
    'download preserves every existing JSON file for every conflict policy',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requestCount = 0;
      server.listen((request) async {
        requestCount++;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentLength = 2
          ..write('{}');
        await request.response.close();
      });
      try {
        for (final policy in AsmrDownloadConflictPolicy.values) {
          final tempDir = await Directory.systemTemp.createTemp(
            'asmr_download_preserve_any_json_',
          );
          final manager = _manager();
          try {
            final workFolder = Directory(
              '${tempDir.path}${Platform.pathSeparator}Work [1]',
            );
            await workFolder.create();
            final jsonFile = File(
              '${workFolder.path}${Platform.pathSeparator}Metadata.JSON',
            );
            final backup = File(
              '${workFolder.path}${Platform.pathSeparator}doujin-audio.json',
            );
            const originalJson = '{\n  "external": true\n}\n';
            const originalBackup = '{"externalMetadata":true}';
            await jsonFile.writeAsString(originalJson, flush: true);
            await backup.writeAsString(originalBackup, flush: true);

            await manager.startDownload(
              work: _work(),
              selectedRoots: <AsmrTrackFile>[
                _file(
                  downloadUrl:
                      'http://${server.address.host}:${server.port}/metadata.json',
                  size: 2,
                  title: 'Metadata.JSON ',
                ),
              ],
              destinationRoot: tempDir.path,
              conflictPolicy: policy,
            );
            await _waitForTaskStatus(
              manager,
              1,
              AsmrDownloadTaskStatus.completed,
            );

            expect(await jsonFile.readAsString(), originalJson);
            expect(await backup.readAsString(), originalBackup);
            expect(manager.getTask(1)?.skippedFiles, 2);
          } finally {
            manager.dispose();
            if (await tempDir.exists()) await tempDir.delete(recursive: true);
          }
        }
        expect(requestCount, 0);
      } finally {
        await server.close(force: true);
      }
    },
  );

  test('new local JSON download commits through the document store', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_new_json_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    const payload = '{"remote":true}';
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.set(HttpHeaders.etagHeader, '"metadata"')
        ..headers.contentLength = utf8.encode(payload).length
        ..write(payload);
      await request.response.close();
    });
    final manager = _manager();
    try {
      await manager.startDownload(
        work: _work(),
        selectedRoots: <AsmrTrackFile>[
          _file(
            downloadUrl:
                'http://${server.address.host}:${server.port}/metadata.json',
            size: utf8.encode(payload).length,
            title: 'Metadata.JSON',
          ),
        ],
        destinationRoot: tempDir.path,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        saveMetadata: false,
      );
      await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

      final target = File(
        '${tempDir.path}${Platform.pathSeparator}Work [1]'
        '${Platform.pathSeparator}Metadata.JSON',
      );
      expect(await target.readAsString(), payload);
      expect(await File('${target.path}.doujin.part').exists(), isFalse);
      expect(manager.getTask(1)?.completedFiles, 1);
      expect(manager.getTask(1)?.skippedFiles, 0);
    } finally {
      manager.dispose();
      await server.close(force: true);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  });

  test('SAF download never copies over an existing JSON file', () async {
    final gateway = _ExistingJsonSafGateway();
    final manager = AsmrDownloadManager(
      fileCacheGateway: gateway,
      temporaryDirectoryProvider: () async => Directory.systemTemp,
      persistTasks: false,
    );
    const destinationRoot =
        'content://com.android.externalstorage.documents/tree/primary%3ADownload';
    try {
      await manager.startDownload(
        work: _work(),
        selectedRoots: <AsmrTrackFile>[
          _file(
            downloadUrl: 'https://example.invalid/Metadata.JSON',
            size: 128,
            title: 'Metadata.JSON',
          ),
        ],
        destinationRoot: destinationRoot,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        saveMetadata: false,
      );
      await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

      expect(manager.getTask(1)?.skippedFiles, 1);
      expect(gateway.copyCount, 0);
    } finally {
      manager.dispose();
    }
  });

  test('cancel never deletes a SAF root whose existence check failed', () async {
    final gateway = _UnknownExistingRootSafGateway();
    final manager = AsmrDownloadManager(
      fileCacheGateway: gateway,
      temporaryDirectoryProvider: () async => Directory.systemTemp,
      persistTasks: false,
    );
    const destinationRoot =
        'content://com.android.externalstorage.documents/tree/primary%3ADownload';
    try {
      await manager.startDownload(
        work: _work(),
        selectedRoots: <AsmrTrackFile>[
          _file(
            downloadUrl: 'https://example.invalid/track.mp3',
            size: 128,
            title: 'track.mp3',
          ),
        ],
        destinationRoot: destinationRoot,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        saveMetadata: false,
      );
      await _waitForTaskStatus(
        manager,
        1,
        AsmrDownloadTaskStatus.failed,
        allowFailure: true,
      );

      final workRoot = manager.getTask(1)!.workRootPath;
      await manager.cancelTask(1);

      expect(gateway.deletedPaths, isNot(contains(workRoot)));
    } finally {
      manager.dispose();
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
          selectedRoots: <AsmrTrackFile>[
            AsmrTrackFile(
              hash: 'folder',
              title: 'Folder',
              type: 'folder',
              streamUrl: null,
              downloadUrl: null,
              lowQualityUrl: null,
              duration: Duration.zero,
              size: 0,
              children: const <AsmrTrackFile>[],
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
        expect(task.workFolderName, 'RJ123456 - Work [1]');
        expect(task.saveMetadata, isFalse);
        expect(task.totalFiles, 0);
        expect(task.completedFiles, 0);
        expect(task.totalBytes, 0);
        expect(task.downloadedBytes, 0);
        expect(
          await File(
            '${tempDir.path}${Platform.pathSeparator}RJ123456 - Work [1]'
            '${Platform.pathSeparator}doujin-audio.json',
          ).exists(),
          isFalse,
        );
      } finally {
        manager.dispose();
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );

  test('removing a task entry keeps downloaded files', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_remove_entry_',
    );
    final downloadedFile = File(
      '${tempDir.path}${Platform.pathSeparator}Work'
      '${Platform.pathSeparator}Track.mp3',
    );
    await downloadedFile.create(recursive: true);
    await downloadedFile.writeAsBytes(const <int>[1, 2, 3]);
    final manager = _manager();
    manager.debugSetCurrentTaskForTesting(_failedTaskSnapshot(tempDir.path));

    try {
      await manager.cancelTask(1, deleteDownloaded: false);

      expect(manager.getTask(1), isNull);
      expect(await downloadedFile.readAsBytes(), const <int>[1, 2, 3]);
    } finally {
      manager.dispose();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  });

  test('deleting a task removes downloaded content', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_delete_task_',
    );
    final workDir = Directory('${tempDir.path}${Platform.pathSeparator}Work');
    final downloadedFile = File(
      '${workDir.path}${Platform.pathSeparator}Track.mp3',
    );
    await downloadedFile.create(recursive: true);
    await downloadedFile.writeAsBytes(const <int>[1, 2, 3]);
    final manager = _manager();
    manager.debugSetCurrentTaskForTesting(_failedTaskSnapshot(tempDir.path));

    try {
      await manager.deleteTask(1);

      expect(manager.getTask(1), isNull);
      expect(await workDir.exists(), isFalse);
    } finally {
      manager.dispose();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  });

  test(
    'canceling a paused download removes task and downloaded files',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_cancel_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(
        server.forEach((request) async {
          if (request.uri.path == '/other.mp3') {
            request.response.headers.contentLength = 3;
            request.response.add(const <int>[1, 2, 3]);
            await request.response.close();
            return;
          }
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
          work: _work(id: 2),
          selectedRoots: <AsmrTrackFile>[
            _file(
              downloadUrl:
                  'http://${server.address.host}:${server.port}/other.mp3',
              size: 3,
            ),
          ],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        );
        await _waitForTaskStatus(manager, 2, AsmrDownloadTaskStatus.completed);
        final otherFile = File(
          path.join(manager.getTask(2)!.workRootPath, 'Track.mp3'),
        );
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
        final workDirectory = Directory(
          '${tempDir.path}${Platform.pathSeparator}Work [1]',
        );
        expect(await workDirectory.exists(), isTrue);
        expect(await workDirectory.list().toList(), isEmpty);
        expect(await otherFile.readAsBytes(), const <int>[1, 2, 3]);
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
        '${tempDir.path}${Platform.pathSeparator}Work [1]',
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
            '${workDir.path}${Platform.pathSeparator}Track.mp3.doujin.part',
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
            '${tempDir.path}${Platform.pathSeparator}Work [1]'
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
          '${tempDir.path}${Platform.pathSeparator}Work [1]',
        ).exists(),
        isFalse,
      );
    } finally {
      manager.dispose();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  });

  test(
    'a transient file failure retries without blocking sibling downloads',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_file_retry_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      const bytes = <int>[1, 2, 3, 4];
      var retryRequests = 0;
      var siblingRequests = 0;
      unawaited(
        server.forEach((request) async {
          if (request.uri.path.endsWith('retry.mp3')) {
            retryRequests++;
            if (retryRequests == 1) {
              request.response.statusCode = HttpStatus.serviceUnavailable;
              await request.response.close();
              return;
            }
          } else {
            siblingRequests++;
          }
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
          await request.response.close();
        }),
      );
      final manager = _manager();
      var observedRetry = false;
      manager.taskStream(1).skip(1).listen((task) {
        observedRetry =
            observedRetry || task?.fileRetryAttempts['retry.mp3'] == 1;
      });
      try {
        final baseUrl = 'http://${server.address.host}:${server.port}';
        await manager.startDownload(
          work: _work(),
          selectedRoots: <AsmrTrackFile>[
            _file(
              title: 'retry.mp3',
              downloadUrl: '$baseUrl/retry.mp3',
              size: bytes.length,
            ),
            _file(
              title: 'sibling.mp3',
              downloadUrl: '$baseUrl/sibling.mp3',
              size: bytes.length,
            ),
          ],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        );
        await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

        expect(retryRequests, 2);
        expect(siblingRequests, 1);
        expect(observedRetry, isTrue);
        expect(manager.getTask(1)?.failedFiles, 0);
        expect(manager.getTask(1)?.fileRetryAttempts, isEmpty);
        expect(
          await File(
            '${tempDir.path}${Platform.pathSeparator}Work [1]'
            '${Platform.pathSeparator}retry.mp3',
          ).readAsBytes(),
          bytes,
        );
      } finally {
        manager.dispose();
        await server.close(force: true);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );

  test('a truncated file resumes from its partial staging file', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_truncated_retry_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bytes = List<int>.generate(1024, (index) => index % 251);
    final rangeStarts = <int>[];
    unawaited(
      server.forEach((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range == null) {
          rangeStarts.add(0);
          request.response.add(bytes.take(128).toList());
        } else {
          final start = int.parse(
            RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!,
          );
          rangeStarts.add(start);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${bytes.length - 1}/${bytes.length}',
          );
          final remaining = bytes.sublist(start);
          request.response.contentLength = remaining.length;
          request.response.add(remaining);
        }
        await request.response.close();
      }),
    );
    final manager = _manager();
    try {
      await manager.startDownload(
        work: _work(),
        selectedRoots: <AsmrTrackFile>[
          _file(
            title: 'track.mp3',
            downloadUrl:
                'http://${server.address.host}:${server.port}/track.mp3',
            size: bytes.length,
          ),
        ],
        destinationRoot: tempDir.path,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
      );
      await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

      expect(rangeStarts, <int>[0, 128]);
      expect(
        manager.getTask(1)?.downloadedBytes,
        manager.getTask(1)?.totalBytes,
      );
      expect(
        await File(
          '${tempDir.path}${Platform.pathSeparator}Work [1]'
          '${Platform.pathSeparator}track.mp3',
        ).readAsBytes(),
        bytes,
      );
    } finally {
      manager.dispose();
      await server.close(force: true);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  });

  test(
    'v0.18 resumes a changed entity without an If-Range validator',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_changed_entity_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final firstBytes = List<int>.filled(1024, 1);
      final replacementBytes = List<int>.filled(1024, 2);
      final ranges = <String?>[];
      final ifRanges = <String?>[];
      var requestCount = 0;
      unawaited(
        server.forEach((request) async {
          requestCount++;
          ranges.add(request.headers.value(HttpHeaders.rangeHeader));
          ifRanges.add(request.headers.value(HttpHeaders.ifRangeHeader));
          if (requestCount == 1) {
            request.response.headers.set(HttpHeaders.etagHeader, '"entity-a"');
            request.response.add(firstBytes.take(128).toList());
          } else if (requestCount == 2) {
            const start = 128;
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers
              ..set(HttpHeaders.etagHeader, '"entity-b"')
              ..set(
                HttpHeaders.contentRangeHeader,
                'bytes $start-${replacementBytes.length - 1}/'
                '${replacementBytes.length}',
              );
            final remaining = replacementBytes.sublist(start);
            request.response.contentLength = remaining.length;
            request.response.add(remaining);
          } else {
            request.response.headers.set(HttpHeaders.etagHeader, '"entity-b"');
            request.response.contentLength = replacementBytes.length;
            request.response.add(replacementBytes);
          }
          await request.response.close();
        }),
      );
      final manager = _manager();
      try {
        await manager.startDownload(
          work: _work(),
          selectedRoots: <AsmrTrackFile>[
            _file(
              title: 'changed.mp3',
              downloadUrl:
                  'http://${server.address.host}:${server.port}/changed.mp3',
              size: replacementBytes.length,
            ),
          ],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        );
        await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

        expect(ranges, <String?>[null, 'bytes=128-']);
        expect(ifRanges, <String?>[null, null]);
        expect(
          await File(
            '${tempDir.path}${Platform.pathSeparator}Work [1]'
            '${Platform.pathSeparator}changed.mp3',
          ).readAsBytes(),
          <int>[...firstBytes.take(128), ...replacementBytes.skip(128)],
        );
      } finally {
        manager.dispose();
        await server.close(force: true);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );

  test('a ranged request receiving 200 overwrites the partial file', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_range_200_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final oldBytes = List<int>.filled(1024, 1);
    final currentBytes = List<int>.filled(1024, 2);
    final ranges = <String?>[];
    final ifRanges = <String?>[];
    var requestCount = 0;
    unawaited(
      server.forEach((request) async {
        requestCount++;
        ranges.add(request.headers.value(HttpHeaders.rangeHeader));
        ifRanges.add(request.headers.value(HttpHeaders.ifRangeHeader));
        if (requestCount == 1) {
          request.response.headers.set(HttpHeaders.etagHeader, '"old"');
          request.response.add(oldBytes.take(128).toList());
        } else {
          request.response.headers.set(HttpHeaders.etagHeader, '"current"');
          request.response.contentLength = currentBytes.length;
          request.response.add(currentBytes);
        }
        await request.response.close();
      }),
    );
    final manager = _manager();
    try {
      await manager.startDownload(
        work: _work(),
        selectedRoots: <AsmrTrackFile>[
          _file(
            title: 'range-200.mp3',
            downloadUrl:
                'http://${server.address.host}:${server.port}/track.mp3',
            size: currentBytes.length,
          ),
        ],
        destinationRoot: tempDir.path,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
      );
      await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

      expect(ranges, <String?>[null, 'bytes=128-']);
      expect(ifRanges, <String?>[null, null]);
      expect(
        await File(
          '${tempDir.path}${Platform.pathSeparator}Work [1]'
          '${Platform.pathSeparator}range-200.mp3',
        ).readAsBytes(),
        currentBytes,
      );
    } finally {
      manager.dispose();
      await server.close(force: true);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  });

  test('a 206 response without a validator resumes in v0.18 mode', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_206_no_validator_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bytes = List<int>.generate(1024, (index) => index % 233);
    final ranges = <String?>[];
    var requestCount = 0;
    unawaited(
      server.forEach((request) async {
        requestCount++;
        ranges.add(request.headers.value(HttpHeaders.rangeHeader));
        if (requestCount == 1) {
          request.response.headers.set(HttpHeaders.etagHeader, '"first"');
          request.response.add(bytes.take(128).toList());
        } else if (requestCount == 2) {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 128-${bytes.length - 1}/${bytes.length}',
          );
          final remaining = bytes.sublist(128);
          request.response.contentLength = remaining.length;
          request.response.add(remaining);
        } else {
          request.response.headers.set(HttpHeaders.etagHeader, '"current"');
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
        }
        await request.response.close();
      }),
    );
    final manager = _manager();
    try {
      await manager.startDownload(
        work: _work(),
        selectedRoots: <AsmrTrackFile>[
          _file(
            title: 'missing-validator.mp3',
            downloadUrl:
                'http://${server.address.host}:${server.port}/track.mp3',
            size: bytes.length,
          ),
        ],
        destinationRoot: tempDir.path,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
      );
      await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

      expect(ranges, <String?>[null, 'bytes=128-']);
      expect(
        await File(
          '${tempDir.path}${Platform.pathSeparator}Work [1]'
          '${Platform.pathSeparator}missing-validator.mp3',
        ).readAsBytes(),
        bytes,
      );
    } finally {
      manager.dispose();
      await server.close(force: true);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  });

  test('v0.18 resume does not send If-Range for weak ETags', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_last_modified_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bytes = List<int>.generate(1024, (index) => index % 227);
    const lastModified = 'Wed, 21 Oct 2015 07:28:00 GMT';
    final ifRanges = <String?>[];
    var requestCount = 0;
    unawaited(
      server.forEach((request) async {
        requestCount++;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        ifRanges.add(request.headers.value(HttpHeaders.ifRangeHeader));
        request.response.headers
          ..set(HttpHeaders.etagHeader, 'W/"weak"')
          ..set(HttpHeaders.lastModifiedHeader, lastModified);
        if (requestCount == 1) {
          request.response.add(bytes.take(128).toList());
        } else {
          expect(range, 'bytes=128-');
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 128-${bytes.length - 1}/${bytes.length}',
          );
          final remaining = bytes.sublist(128);
          request.response.contentLength = remaining.length;
          request.response.add(remaining);
        }
        await request.response.close();
      }),
    );
    final manager = _manager();
    try {
      await manager.startDownload(
        work: _work(),
        selectedRoots: <AsmrTrackFile>[
          _file(
            title: 'last-modified.mp3',
            downloadUrl:
                'http://${server.address.host}:${server.port}/track.mp3',
            size: bytes.length,
          ),
        ],
        destinationRoot: tempDir.path,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
      );
      await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

      expect(ifRanges, <String?>[null, null]);
    } finally {
      manager.dispose();
      await server.close(force: true);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  });

  test(
    'partial file without a validator still sends a range request',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_no_validator_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bytes = List<int>.generate(1024, (index) => index % 239);
      final ranges = <String?>[];
      var requestCount = 0;
      unawaited(
        server.forEach((request) async {
          requestCount++;
          ranges.add(request.headers.value(HttpHeaders.rangeHeader));
          if (requestCount == 1) {
            request.response.add(bytes.take(128).toList());
          } else {
            request.response.contentLength = bytes.length;
            request.response.add(bytes);
          }
          await request.response.close();
        }),
      );
      final manager = _manager();
      try {
        await manager.startDownload(
          work: _work(),
          selectedRoots: <AsmrTrackFile>[
            _file(
              title: 'no-validator.mp3',
              downloadUrl:
                  'http://${server.address.host}:${server.port}/track.mp3',
              size: bytes.length,
            ),
          ],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        );
        await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

        expect(ranges, <String?>[null, 'bytes=128-']);
        expect(
          await File(
            '${tempDir.path}${Platform.pathSeparator}Work [1]'
            '${Platform.pathSeparator}no-validator.mp3',
          ).readAsBytes(),
          bytes,
        );
      } finally {
        manager.dispose();
        await server.close(force: true);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'v0.18 accepts a complete staging file without downloading again',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_complete_staging_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bytes = List<int>.filled(1024, 9);
      final ranges = <String?>[];
      unawaited(
        server.forEach((request) async {
          ranges.add(request.headers.value(HttpHeaders.rangeHeader));
          request.response.headers.set(HttpHeaders.etagHeader, '"fresh"');
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
          await request.response.close();
        }),
      );
      final workRoot = path.join(tempDir.path, 'Work [1]');
      final staging = File(path.join(workRoot, 'Track.mp3.doujin.part'));
      await staging.parent.create(recursive: true);
      await staging.writeAsBytes(
        List<int>.filled(bytes.length, 1),
        flush: true,
      );
      final manager = _manager();
      try {
        await manager.startDownload(
          work: _work(),
          selectedRoots: <AsmrTrackFile>[
            _file(
              downloadUrl:
                  'http://${server.address.host}:${server.port}/track.mp3',
              size: bytes.length,
            ),
          ],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        );
        await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

        expect(ranges, isEmpty);
        expect(
          await File(path.join(workRoot, 'Track.mp3')).readAsBytes(),
          List<int>.filled(bytes.length, 1),
        );
      } finally {
        manager.dispose();
        await server.close(force: true);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'transient failures exhaust configured retries and count one failure',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_retry_exhausted_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      unawaited(
        server.forEach((request) async {
          requests++;
          request.response.statusCode = HttpStatus.serviceUnavailable;
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
            ),
          ],
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
          automaticFileRetryCount: 3,
        );
        await _waitForTaskStatus(
          manager,
          1,
          AsmrDownloadTaskStatus.failed,
          allowFailure: true,
        );

        expect(requests, 4);
        expect(manager.getTask(1)?.automaticFileRetryCount, 3);
        expect(manager.getTask(1)?.failedFiles, 1);
        expect(manager.getTask(1)?.fileRetryAttempts, isEmpty);
      } finally {
        manager.dispose();
        await server.close(force: true);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );

  test('a permanent HTTP failure is not retried', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_no_retry_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    unawaited(
      server.forEach((request) async {
        requests++;
        request.response.statusCode = HttpStatus.notFound;
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

      expect(requests, 1);
      expect(manager.getTask(1)?.failedFiles, 1);
    } finally {
      manager.dispose();
      await server.close(force: true);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  });

  test('pausing during retry backoff prevents another request', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_retry_pause_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    unawaited(
      server.forEach((request) async {
        requests++;
        request.response.statusCode = HttpStatus.serviceUnavailable;
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
          ),
        ],
        destinationRoot: tempDir.path,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
      );
      await _waitForFileRetryAttempt(manager, 1, 'Track.mp3', 1);
      await manager.pauseTask(1);

      expect(requests, 1);
      expect(manager.getTask(1)?.status, AsmrDownloadTaskStatus.paused);
      expect(manager.getTask(1)?.fileRetryAttempts, isEmpty);
    } finally {
      manager.dispose();
      await server.close(force: true);
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
          '${tempDir.path}${Platform.pathSeparator}Work [1]'
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

  test('v0.18 accepts an unknown-size empty audio response', () async {
    final result = await _downloadUnknownSizeResponse(
      responseBytes: const [],
      expectedStatus: AsmrDownloadTaskStatus.completed,
    );

    expect(result.requests, 1);
    expect(result.failedFiles, 0);
    expect(result.outputExists, isTrue);
    expect(result.outputBytes, isEmpty);
    expect(result.stagingExists, isFalse);
  });

  test('unknown-size non-empty chunked audio completes', () async {
    const bytes = <int>[1, 2, 3, 4];
    final result = await _downloadUnknownSizeResponse(
      responseBytes: bytes,
      expectedStatus: AsmrDownloadTaskStatus.completed,
    );

    expect(result.outputBytes, bytes);
  });

  test('unknown-size empty non-media sidecar remains valid', () async {
    final result = await _downloadUnknownSizeResponse(
      responseBytes: const [],
      expectedStatus: AsmrDownloadTaskStatus.completed,
      title: 'empty.txt',
      type: 'text',
    );

    expect(result.outputExists, isTrue);
    expect(result.outputBytes, isEmpty);
  });

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
      final selectedRoots = <AsmrTrackFile>[
        _file(
          downloadUrl: 'http://${server.address.host}:${server.port}/fast.mp3',
          size: fastBytes,
          title: 'Fast.mp3',
        ),
        _file(
          downloadUrl: 'http://${server.address.host}:${server.port}/slow.mp3',
          size: slowBytes,
          title: 'Slow.mp3',
        ),
      ];
      try {
        await manager.startDownload(
          work: _work(),
          selectedRoots: selectedRoots,
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
          saveMetadata: false,
        );

        final workDir = Directory(
          '${tempDir.path}${Platform.pathSeparator}Work [1]',
        );
        final fastFile = File(
          '${workDir.path}${Platform.pathSeparator}Fast.mp3',
        );
        final slowPart = File(
          '${workDir.path}${Platform.pathSeparator}Slow.mp3.doujin.part',
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

        await manager.startDownload(
          work: _work(),
          selectedRoots: selectedRoots,
          destinationRoot: tempDir.path,
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
          saveMetadata: false,
        );
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
    'v0.18 redownloads a local file when completed-path state is stale',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'asmr_download_resume_completed_',
      );
      const fileBytes = 4096;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requestCount = 0;
      unawaited(
        server.forEach((request) async {
          requestCount++;
          request.response.contentLength = fileBytes;
          request.response.add(List<int>.filled(fileBytes, 9));
          await request.response.close();
        }),
      );
      final selectedRoots = <AsmrTrackFile>[
        _file(
          downloadUrl: 'http://${server.address.host}:${server.port}/track.mp3',
          size: fileBytes,
        ),
      ];
      final target = File(
        '${tempDir.path}${Platform.pathSeparator}Work [1]'
        '${Platform.pathSeparator}Track.mp3',
      );
      await target.parent.create(recursive: true);
      await target.writeAsBytes(List<int>.filled(fileBytes, 7), flush: true);
      final manager = _manager();
      manager.debugSetCurrentTaskForTesting(
        AsmrDownloadTaskSnapshot(
          work: _work(),
          destinationRoot: tempDir.path,
          workFolderName: 'Work [1]',
          conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
          saveMetadata: false,
          status: AsmrDownloadTaskStatus.paused,
          totalFiles: 1,
          completedFiles: 0,
          skippedFiles: 0,
          failedFiles: 0,
          totalBytes: fileBytes,
          downloadedBytes: fileBytes,
          startedAt: DateTime(2026),
          fileDownloadedBytes: const <String, int>{'Track.mp3': fileBytes},
          fileTotalBytes: const <String, int>{'Track.mp3': fileBytes},
          selectedRoots: selectedRoots,
        ),
      );

      try {
        await manager.resumeTask(1);
        await _waitForTaskStatus(manager, 1, AsmrDownloadTaskStatus.completed);

        expect(requestCount, 1);
        expect(manager.getTask(1)?.completedFiles, 1);
        expect(manager.getTask(1)?.skippedFiles, 0);
        expect(manager.getTask(1)?.completedFilePaths, contains('Track.mp3'));
        expect(await target.readAsBytes(), List<int>.filled(fileBytes, 9));
      } finally {
        manager.dispose();
        await server.close(force: true);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );

  test('legacy task with resume validators restores safely', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppPreferences.init();
    final payload = jsonEncode(<String, Object?>{
      'version': 1,
      'tasks': <Object?>[
        <String, Object?>{
          'work': _work().toJson(),
          'destinationRoot': Directory.systemTemp.path,
          'workFolderName': 'Work',
          'conflictPolicy': AsmrDownloadConflictPolicy.overwrite.name,
          'saveMetadata': false,
          'totalFiles': 1,
          'totalBytes': 1024,
          'downloadedBytes': 128,
          'startedAt': DateTime(2026).toIso8601String(),
          'fileDownloadedBytes': <String, int>{'Track.mp3': 128},
          'fileResumeValidators': <String, String>{
            'Track.mp3': '"legacy-etag"',
          },
          'fileTotalBytes': <String, int>{'Track.mp3': 1024},
          'completedFilePaths': <String>[],
          'selectedRoots': <Object?>[
            <String, Object?>{
              'title': 'Track.mp3',
              'type': 'audio',
              'downloadUrl': 'https://example.invalid/track.mp3',
              'size': 1024,
              'relativePath': 'Track.mp3',
              'children': <Object?>[],
            },
          ],
          'createdOutputPaths': <String>[],
          'createdJsonDocuments': <String, Object?>{},
        },
      ],
    });
    await AppPreferences.setString(
      AppPreferences.asmrDownloadTasksKey,
      payload,
    );
    final manager = AsmrDownloadManager();
    try {
      await manager.initialize();

      expect(manager.getTask(1)?.status, AsmrDownloadTaskStatus.paused);
      expect(manager.getTask(1)?.workFolderName, 'Work');
      expect(manager.getTask(1)?.saveCover, isFalse);
      expect(
        manager.getTask(1)?.automaticFileRetryCount,
        kMaxAsmrDownloadRetryCount,
      );
      expect(
        manager.getTask(1)?.workRootPath,
        path.join(Directory.systemTemp.path, 'Work'),
      );
      await manager.flushPersistence();
      final rewritten =
          jsonDecode(
                (await AppPreferences.getString(
                  AppPreferences.asmrDownloadTasksKey,
                ))!,
              )
              as Map<String, dynamic>;
      expect(
        ((rewritten['tasks'] as List).single as Map).containsKey(
          'fileResumeValidators',
        ),
        isFalse,
      );
    } finally {
      manager.dispose();
      await AppPreferences.remove(AppPreferences.asmrDownloadTasksKey);
    }
  });

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
          '${tempDir.path}${Platform.pathSeparator}Work [1]'
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
          '${tempDir.path}${Platform.pathSeparator}Work [1]'
          '${Platform.pathSeparator}Track.mp3.doujin.part',
        );
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while ((!await part.exists() || await part.length() < 32768) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await firstManager.pauseAllTasks();
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
      manager.taskIdsStream.skip(1).listen((_) => notificationCount++);
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

Future<
  ({
    int requests,
    int? failedFiles,
    bool outputExists,
    bool stagingExists,
    List<int> outputBytes,
  })
>
_downloadUnknownSizeResponse({
  required List<int> responseBytes,
  required AsmrDownloadTaskStatus expectedStatus,
  String title = 'Track.mp3',
  String type = 'audio',
}) async {
  final tempDir = await Directory.systemTemp.createTemp(
    'asmr_download_unknown_size_',
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var requests = 0;
  unawaited(
    server.forEach((request) async {
      requests++;
      request.response.headers.chunkedTransferEncoding = true;
      request.response.add(responseBytes);
      await request.response.close();
    }),
  );
  final manager = AsmrDownloadManager(
    temporaryDirectoryProvider: () async => Directory.systemTemp,
    automaticFileRetryDelay: Duration.zero,
    persistTasks: false,
  );
  try {
    await manager.startDownload(
      work: _work(),
      selectedRoots: <AsmrTrackFile>[
        _file(
          downloadUrl: 'http://${server.address.host}:${server.port}/$title',
          size: 0,
          title: title,
          type: type,
        ),
      ],
      destinationRoot: tempDir.path,
      conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
    );
    await _waitForTaskStatus(
      manager,
      1,
      expectedStatus,
      allowFailure: expectedStatus == AsmrDownloadTaskStatus.failed,
    );

    final output = File(path.join(tempDir.path, 'Work [1]', title));
    final outputExists = await output.exists();
    return (
      requests: requests,
      failedFiles: manager.getTask(1)?.failedFiles,
      outputExists: outputExists,
      stagingExists: await File('${output.path}.doujin.part').exists(),
      outputBytes: outputExists ? await output.readAsBytes() : const <int>[],
    );
  } finally {
    manager.dispose();
    await server.close(force: true);
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  }
}

AsmrDownloadManager _manager() {
  return AsmrDownloadManager(
    temporaryDirectoryProvider: () async => Directory.systemTemp,
    automaticFileRetryDelay: const Duration(milliseconds: 200),
    persistTasks: false,
  );
}

AsmrDownloadTaskSnapshot _failedTaskSnapshot(String destinationRoot) {
  return AsmrDownloadTaskSnapshot(
    work: _work(),
    destinationRoot: destinationRoot,
    workFolderName: 'Work',
    conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
    status: AsmrDownloadTaskStatus.failed,
    totalFiles: 1,
    completedFiles: 1,
    skippedFiles: 0,
    failedFiles: 1,
    totalBytes: 3,
    downloadedBytes: 3,
    startedAt: DateTime(2026),
  );
}

final class _ExistingJsonSafGateway extends FileCachePlatformGateway {
  _ExistingJsonSafGateway() : super(isAndroid: () => true);

  int copyCount = 0;
  int ensureFolderCount = 0;
  final List<String> ensuredRelativePaths = <String>[];

  @override
  Future<bool> documentPathExists(String path) async => true;

  @override
  Future<bool?> documentPathExistence(String path) async => true;

  @override
  Future<bool> ensureFolderPath({
    required String folder,
    required String relativePath,
    required bool overwrite,
  }) async {
    ensureFolderCount++;
    ensuredRelativePaths.add(relativePath);
    return true;
  }

  @override
  Future<bool> copyFileToFolder({
    required String sourcePath,
    required String folder,
    required String relativePath,
    required bool overwrite,
  }) async {
    copyCount++;
    return false;
  }
}

final class _RecordingSafGateway extends FileCachePlatformGateway {
  _RecordingSafGateway() : super(isAndroid: () => true);

  final List<String> ensuredRelativePaths = <String>[];
  final List<String> copiedRelativePaths = <String>[];
  final List<String> deletedPaths = <String>[];

  @override
  Future<bool> documentPathExists(String path) async => false;

  @override
  Future<bool> ensureFolderPath({
    required String folder,
    required String relativePath,
    required bool overwrite,
  }) async {
    ensuredRelativePaths.add(relativePath);
    return true;
  }

  @override
  Future<bool> copyFileToFolder({
    required String sourcePath,
    required String folder,
    required String relativePath,
    required bool overwrite,
  }) async {
    copiedRelativePaths.add(relativePath);
    return true;
  }

  @override
  Future<bool> deleteDocumentPath(String path) async {
    deletedPaths.add(path);
    return true;
  }
}

final class _UnknownExistingRootSafGateway extends FileCachePlatformGateway {
  _UnknownExistingRootSafGateway() : super(isAndroid: () => true);

  final List<String> deletedPaths = <String>[];

  @override
  Future<bool> documentPathExists(String path) =>
      Future<bool>.error(const FileSystemException('query failed'));

  @override
  Future<bool?> documentPathExistence(String path) async => null;

  @override
  Future<bool> ensureFolderPath({
    required String folder,
    required String relativePath,
    required bool overwrite,
  }) async => true;

  @override
  Future<bool> deleteDocumentPath(String path) async {
    deletedPaths.add(path);
    return true;
  }
}

Future<void> _waitForLiveTask(AsmrDownloadManager manager) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (manager.hasLiveTask) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Timed out waiting for a live download task');
}

Future<void> _waitForRequestCount(int Function() readCount, int count) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (readCount() >= count) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Timed out waiting for $count download requests.');
}

Future<void> _waitForFiles(Iterable<File> files) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if ((await Future.wait(
      files.map((file) => file.exists()),
    )).every((exists) => exists)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Timed out waiting for downloaded files.');
}

Future<void> _waitForFileRetryAttempt(
  AsmrDownloadManager manager,
  int workId,
  String relativePath,
  int attempt,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (manager.getTask(workId)?.fileRetryAttempts[relativePath] == attempt) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final task = manager.getTask(workId);
  fail(
    'Timed out waiting for retry $attempt of $relativePath; '
    'status=${task?.status} retries=${task?.fileRetryAttempts} '
    'message=${task?.message} error=${task?.error}',
  );
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
  String? title,
  String? sourceId,
  String coverUrl = '',
  String thumbnailUrl = '',
  String mainCoverUrl = '',
  DateTime? releaseDate,
  Duration duration = Duration.zero,
  int dlCount = 0,
  double rating = 0,
}) {
  return AsmrWork(
    id: id,
    title: title ?? (id == 1 ? 'Work' : 'Work $id'),
    circleName: 'Circle',
    sourceId: sourceId ?? (id == 1 ? 'RJ123456' : 'RJ12345$id'),
    sourceType: 'asmr',
    sourceUrl: '',
    coverUrl: coverUrl,
    thumbnailUrl: thumbnailUrl,
    mainCoverUrl: mainCoverUrl,
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
  String type = 'audio',
}) {
  return AsmrTrackFile(
    hash: title,
    title: title,
    type: type,
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
