import 'dart:async';
import 'dart:convert';

import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_task_store.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_internal_models.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_serialization.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_download.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';

void main() {
  const safRoot =
      'content://com.android.externalstorage.documents/tree/primary%3AMusic';

  test(
    'download worker round trip retains ownership and pauses recovered tasks',
    () async {
      final task = _task(1).copyWith(
        downloadedBytes: 512,
        fileDownloadedBytes: const {'track.mp3': 512},
        fileRetryAttempts: const {'track.mp3': 2},
        fileEntityTags: const {'track.mp3': '"entity-a"'},
        manuallyRetryingFilePaths: const {'track.mp3'},
      );
      final payload = await compute(encodePersistedDownloadTasks, [
        PersistedDownloadTask(
          task: task,
          createdOutputPaths: const {'C:/Downloads/Work 1/track.mp3'},
          createdJsonDocuments: const {},
        ),
      ]);
      final restored = await compute(decodePersistedDownloadTasks, payload);
      expect(restored.error, isNull);
      expect(restored.tasks.single.task.status, AsmrDownloadTaskStatus.paused);
      expect(restored.tasks.single.task.message, 'paused');
      expect(restored.tasks.single.task.downloadedBytes, 512);
      expect(restored.tasks.single.task.fileDownloadedBytes, {
        'track.mp3': 512,
      });
      expect(
        restored.tasks.single.task.selectedRoots.single.relativePath,
        'track.mp3',
      );
      expect(restored.tasks.single.task.fileRetryAttempts, isEmpty);
      expect(restored.tasks.single.task.fileEntityTags, {
        'track.mp3': '"entity-a"',
      });
      expect(restored.tasks.single.task.manuallyRetryingFilePaths, isEmpty);
      expect(restored.tasks.single.createdOutputPaths, {
        'C:/Downloads/Work 1/track.mp3',
      });

      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      expect(decoded['version'], 2);
      final taskJson = (decoded['tasks'] as List).single as Map;
      taskJson['fileEntityTags'] = {
        'track.mp3': '"entity-a"',
        'weak.mp3': 'W/"entity-a"',
        'invalid.mp3': 'unquoted',
      };
      expect(
        decodePersistedDownloadTasks(
          jsonEncode(decoded),
        ).tasks.single.task.fileEntityTags,
        {'track.mp3': '"entity-a"'},
      );
      decoded['version'] = 1;
      expect(
        decodePersistedDownloadTasks(
          jsonEncode(decoded),
        ).tasks.single.task.fileEntityTags,
        isEmpty,
      );
      (decoded['tasks'] as List).add({'work': null});
      final partial = await compute(
        decodePersistedDownloadTasks,
        jsonEncode(decoded),
      );
      expect(partial.tasks, hasLength(1));
      expect(partial.error, isA<FormatException>());
      expect(partial.stackTrace, isNotNull);
    },
  );

  test(
    'queued checkpoints freeze ownership before awaiting an earlier write',
    () async {
      final firstWrite = Completer<void>();
      final firstStarted = Completer<void>();
      final writes = <String?>[];
      final manager = AsmrDownloadManager(
        persistenceWriter: (payload) async {
          writes.add(payload);
          if (writes.length == 1) {
            firstStarted.complete();
            await firstWrite.future;
          }
        },
      );
      addTearDown(manager.shutdown);
      manager.debugSetCurrentTaskForTesting(_task(1));
      final first = manager.flushPersistence();
      await firstStarted.future;
      manager.debugRecordCreatedOutputPathForTesting(1, 'first.mp3');
      manager.debugRecordDownloadChunkForTesting(1, 'track.mp3', 1, 1);
      final second = manager.flushPersistence();
      manager.debugRecordCreatedOutputPathForTesting(1, 'later.mp3');
      firstWrite.complete();
      await Future.wait([first, second]);
      final restored = decodePersistedDownloadTasks(writes[1]!);
      expect(restored.tasks.single.createdOutputPaths, {'first.mp3'});
    },
  );

  test('composable store owns snapshots and shutdown is idempotent', () async {
    final store = AsmrDownloadTaskStore(
      persistTasks: false,
      persistenceSnapshot: (task) => PersistedDownloadTask(
        task: task,
        createdOutputPaths: const {},
        createdJsonDocuments: const {},
      ),
    );
    final taskIdsDone = Completer<void>();
    final taskDone = Completer<void>();
    final buttonDone = Completer<void>();
    store.taskIdsStream.listen(null, onDone: taskIdsDone.complete);
    store.taskStream(1).listen(null, onDone: taskDone.complete);
    store.buttonViewStateStream.listen(null, onDone: buttonDone.complete);

    store[1] = _task(1);
    store.notifyTaskChanged(changedWorkIds: const <int>{1});
    expect(store.tasks, hasLength(1));
    expect(store.taskIds, <int>[1]);

    final firstShutdown = store.shutdown();
    final secondShutdown = store.shutdown();
    expect(identical(firstShutdown, secondShutdown), isTrue);
    await firstShutdown;
    await Future.wait(<Future<void>>[
      taskIdsDone.future,
      taskDone.future,
      buttonDone.future,
    ]);
    expect(store.isShutdown, isTrue);
  });

  test('persisted SAF URI reference counts update incrementally', () async {
    final operations = <AsmrDownloadStoreOperation>[];
    final manager = AsmrDownloadManager(
      persistTasks: false,
      storeOperationObserver: operations.add,
    );
    addTearDown(manager.shutdown);

    manager.debugSetCurrentTaskForTesting(_task(1, destinationRoot: safRoot));
    manager.debugSetCurrentTaskForTesting(_task(2, destinationRoot: safRoot));

    expect(manager.persistedContentUris, <String>{safRoot});
    expect(manager.persistedUriReferenceRevision, 1);

    operations.clear();
    manager.debugRemoveTaskForTesting(1);
    expect(manager.persistedContentUris, <String>{safRoot});
    expect(manager.persistedUriReferenceRevision, 1);
    expect(
      operations.where(
        (operation) =>
            operation == AsmrDownloadStoreOperation.uriReferenceVisit,
      ),
      hasLength(1),
    );

    operations.clear();
    manager.debugRemoveTaskForTesting(2);
    expect(manager.persistedContentUris, isEmpty);
    expect(manager.persistedUriReferenceRevision, 2);
    expect(
      operations.where(
        (operation) =>
            operation == AsmrDownloadStoreOperation.uriReferenceVisit,
      ),
      hasLength(1),
    );
  });

  for (final taskCount in <int>[100, 1000]) {
    test('single-task hot path is O(1) with $taskCount tasks', () async {
      final operations = <AsmrDownloadStoreOperation>[];
      final manager = AsmrDownloadManager(
        persistTasks: false,
        storeOperationObserver: operations.add,
      );
      addTearDown(manager.shutdown);
      for (var workId = 1; workId <= taskCount; workId++) {
        manager.debugSetCurrentTaskForTesting(_task(workId));
      }

      operations.clear();
      manager.debugRecordDownloadChunkForTesting(1, 'track.mp3', 1, 1);
      manager.debugFlushProgressNotificationsForTesting();

      expect(
        operations.where(
          (operation) =>
              operation == AsmrDownloadStoreOperation.liveProgressVisit,
        ),
        hasLength(1),
      );
      expect(
        operations.where(
          (operation) =>
              operation == AsmrDownloadStoreOperation.uriReferenceVisit,
        ),
        hasLength(1),
      );
      expect(
        operations,
        isNot(contains(AsmrDownloadStoreOperation.persistenceSnapshot)),
      );
    });
  }

  test('structural changes share one debounced persistence snapshot', () async {
    final writes = <String?>[];
    final manager = AsmrDownloadManager(
      persistenceWriter: (payload) async => writes.add(payload),
    );
    addTearDown(manager.shutdown);

    manager.debugSetCurrentTaskForTesting(_task(1));
    manager.debugSetCurrentTaskForTesting(_task(2));
    expect(writes, isEmpty);

    await manager.debugRunStructuralPersistenceForTesting();
    expect(writes, hasLength(1));
    final payload = jsonDecode(writes.single!) as Map<String, Object?>;
    expect(payload['version'], 2);
    expect(payload['tasks'], hasLength(2));
  });

  test('progress updates coalesce into one explicit checkpoint', () async {
    final writes = <String?>[];
    final operations = <AsmrDownloadStoreOperation>[];
    final manager = AsmrDownloadManager(
      persistenceWriter: (payload) async => writes.add(payload),
      storeOperationObserver: operations.add,
    );
    addTearDown(manager.shutdown);
    manager.debugSetCurrentTaskForTesting(_task(1));
    await manager.flushPersistence();
    writes.clear();
    operations.clear();

    for (var byte = 1; byte <= 100; byte++) {
      manager.debugRecordDownloadChunkForTesting(1, 'track.mp3', 1, byte);
    }
    manager.debugFlushProgressNotificationsForTesting();

    expect(writes, isEmpty);
    expect(
      operations,
      isNot(contains(AsmrDownloadStoreOperation.persistenceSnapshot)),
    );

    await manager.debugRunProgressCheckpointForTesting();
    expect(writes, hasLength(1));
    expect(
      operations.where(
        (operation) =>
            operation == AsmrDownloadStoreOperation.persistenceSnapshot,
      ),
      hasLength(1),
    );
    final payload = jsonDecode(writes.single!) as Map<String, Object?>;
    expect(payload['version'], 2);
    final task = (payload['tasks'] as List<Object?>).single as Map;
    expect(task['downloadedBytes'], 100);

    await manager.debugRunProgressCheckpointForTesting();
    expect(writes, hasLength(1));
  });

  test('pause and cancel force pending persistence', () async {
    final writes = <String?>[];
    final manager = AsmrDownloadManager(
      persistenceWriter: (payload) async => writes.add(payload),
    );
    addTearDown(manager.shutdown);
    manager.debugSetCurrentTaskForTesting(_task(1), queued: true);
    writes.clear();

    await manager.pauseTask(1);
    expect(writes, hasLength(1));
    expect(_persistedMessage(writes.single), 'paused');

    writes.clear();
    await manager.cancelTask(1, deleteDownloaded: false);
    expect(writes, <String?>[null]);
  });

  test('completion and shutdown force pending persistence', () async {
    final completionWrites = <String?>[];
    final completionPersisted = Completer<void>();
    final completingManager = AsmrDownloadManager(
      persistenceWriter: (payload) async {
        completionWrites.add(payload);
        if (!completionPersisted.isCompleted) completionPersisted.complete();
      },
    );
    addTearDown(completingManager.shutdown);

    await completingManager.startDownload(
      work: _work(1),
      selectedRoots: <AsmrTrackFile>[_emptyFolder(1)],
      destinationRoot: 'C:\\Downloads',
      conflictPolicy: AsmrDownloadConflictPolicy.skip,
      saveMetadata: false,
      saveCover: false,
    );
    await _waitForStatus(
      completingManager,
      1,
      AsmrDownloadTaskStatus.completed,
    );
    await completionPersisted.future;
    expect(completionWrites, isNotEmpty);
    expect(completionWrites.last, isNull);

    final shutdownWrites = <String?>[];
    final shuttingDownManager = AsmrDownloadManager(
      persistenceWriter: (payload) async => shutdownWrites.add(payload),
    );
    shuttingDownManager.debugSetCurrentTaskForTesting(_task(2));
    shuttingDownManager.debugRecordDownloadChunkForTesting(
      2,
      'track.mp3',
      64,
      64,
    );
    await shuttingDownManager.shutdown();

    expect(shutdownWrites, hasLength(1));
    expect(
      (jsonDecode(shutdownWrites.single!) as Map<String, Object?>)['version'],
      2,
    );
    await shuttingDownManager.shutdown();
    expect(shutdownWrites, hasLength(1));
  });
}

String? _persistedMessage(String? payload) {
  final decoded = jsonDecode(payload!) as Map<String, Object?>;
  final task = (decoded['tasks'] as List<Object?>).single as Map;
  return task['message'] as String?;
}

AsmrDownloadTaskSnapshot _task(
  int workId, {
  String destinationRoot = 'C:\\Downloads',
}) => AsmrDownloadTaskSnapshot(
  work: _work(workId),
  destinationRoot: destinationRoot,
  workFolderName: 'Work $workId',
  conflictPolicy: AsmrDownloadConflictPolicy.skip,
  status: AsmrDownloadTaskStatus.downloading,
  totalFiles: 1,
  completedFiles: 0,
  skippedFiles: 0,
  failedFiles: 0,
  totalBytes: 1024,
  downloadedBytes: 0,
  startedAt: DateTime(2026),
  message: 'downloading',
  fileTotalBytes: const <String, int>{'track.mp3': 1024},
  selectedRoots: <AsmrTrackFile>[
    AsmrTrackFile(
      hash: '$workId',
      title: 'track.mp3',
      type: 'audio',
      streamUrl: null,
      downloadUrl: 'https://example.invalid/track.mp3',
      lowQualityUrl: null,
      duration: Duration.zero,
      size: 1024,
      children: const <AsmrTrackFile>[],
      workId: workId,
      workTitle: 'Work $workId',
      sourceId: 'RJ$workId',
      relativePath: 'track.mp3',
    ),
  ],
);

AsmrTrackFile _emptyFolder(int workId) => AsmrTrackFile(
  hash: 'folder',
  title: 'folder',
  type: 'folder',
  streamUrl: null,
  downloadUrl: null,
  lowQualityUrl: null,
  duration: Duration.zero,
  size: 0,
  children: const <AsmrTrackFile>[],
  workId: workId,
  workTitle: 'Work $workId',
  sourceId: 'RJ$workId',
  relativePath: 'folder',
);

AsmrWork _work(int id) => AsmrWork(
  id: id,
  title: 'Work $id',
  circleName: 'Circle',
  sourceId: 'RJ$id',
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
);

Future<void> _waitForStatus(
  AsmrDownloadManager manager,
  int workId,
  AsmrDownloadTaskStatus status,
) async {
  await manager.taskStream(workId).firstWhere((task) => task?.status == status);
}
