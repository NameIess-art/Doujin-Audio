import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_task_store.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_internal_models.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_serialization.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_download.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const safRoot =
      'content://com.android.externalstorage.documents/tree/primary%3AMusic';

  test(
    'HLS size estimates preserve unknown-size accounting and need progress',
    () {
      final task = _task(1).copyWith(
        totalBytes: 100,
        downloadedBytes: 300,
        fileTotalBytes: const {'known.mp3': 100, 'chapter.flac': 0},
        fileDownloadedBytes: const {'known.mp3': 100, 'chapter.flac': 200},
        fileProgressFractions: const {'chapter.flac': 0.4},
      );
      expect(task.estimateFileTotalBytes('chapter.flac'), 500);
      expect(task.estimatedTotalBytes, 600);
      expect(task.hasUnknownFileSizes, isTrue);
      expect(task.totalBytes, 100);
      for (final fraction in [0.0, double.nan, double.infinity]) {
        expect(
          task
              .copyWith(fileProgressFractions: {'chapter.flac': fraction})
              .estimatedTotalBytes,
          isNull,
        );
      }
      expect(
        task.copyWith(fileProgressFractions: {}).estimatedTotalBytes,
        isNull,
      );
      expect(
        task.copyWith(fileDownloadedBytes: {}).estimatedTotalBytes,
        isNull,
      );
      expect(
        task
            .copyWith(fileTotalBytes: {...task.fileTotalBytes, 'next.flac': 0})
            .estimatedTotalBytes,
        isNull,
      );
      expect(
        task
            .copyWith(fileProgressFractions: {'chapter.flac': 0.8})
            .estimatedTotalBytes,
        350,
      );
    },
  );

  test('unknown file sizes follow immutable snapshot replacements', () async {
    final sizes = <String, int>{for (var i = 0; i < 10000; i++) '$i.mp3': 10};
    final known = _task(1).copyWith(
      totalBytes: 100000,
      totalFiles: sizes.length,
      fileTotalBytes: sizes,
    );
    expect(known.hasUnknownFileSizes, isFalse);
    sizes['0.mp3'] = 0;
    expect(known.hasUnknownFileSizes, isFalse);
    final unknown = known.copyWith(fileTotalBytes: sizes);
    expect(unknown.hasUnknownFileSizes, isTrue);
    expect(unknown.copyWith(downloadedBytes: 1).hasUnknownFileSizes, isTrue);

    final store = AsmrDownloadTaskStore(
      persistTasks: false,
      persistenceSnapshot: (task) => PersistedDownloadTask(
        task: task,
        createdOutputPaths: const {},
        createdJsonDocuments: const {},
      ),
    );
    addTearDown(store.shutdown);
    store[_key(1)] = unknown;
    store.recordDownloadChunk(_key(1), '0.mp3', 100001, 100001);
    expect(store.liveDownloadedBytes(_key(1)), 100001);
    store[_key(1)] = known;
    store.setLiveDownloadedBytes(_key(1), 0);
    store.recordDownloadChunk(_key(1), '0.mp3', 100001, 100001);
    expect(store.liveDownloadedBytes(_key(1)), 100000);
  });

  for (final restoreSucceeded in [false, true]) {
    test(
      'store preserves records until restoration succeeds: $restoreSucceeded',
      () async {
        final writes = <String?>[];
        final store = AsmrDownloadTaskStore(
          persistTasks: true,
          persistenceReady: false,
          persistenceWriter: (payload) async => writes.add(payload),
          persistenceSnapshot: (task) => PersistedDownloadTask(
            task: task,
            createdOutputPaths: const {},
            createdJsonDocuments: const {},
          ),
        );
        addTearDown(store.shutdown);
        store[_key(1)] = _task(1);
        store.notifyTaskChanged();
        await store.runStructuralPersistenceForTesting();
        await store.flushPersistence();
        expect(writes, isEmpty);
        if (restoreSucceeded) {
          store.markPersistenceReady();
          await store.flushPersistence();
          expect(
            decodePersistedDownloadTasks(writes.single!).tasks,
            hasLength(1),
          );
        }
        await store.shutdown();
        expect(writes, hasLength(restoreSucceeded ? 2 : 0));
      },
    );
  }

  test(
    'download worker round trip retains ownership and pauses recovered tasks',
    () async {
      final task = _task(1).copyWith(
        downloadedBytes: 512,
        fileDownloadedBytes: const {'track.mp3': 512},
        fileRetryAttempts: const {'track.mp3': 2},
        fileProgressFractions: const {'track.mp3': 0.5},
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
      expect(restored.tasks.single.task.fileProgressFractions, isEmpty);
      expect(restored.tasks.single.task.fileEntityTags, {
        'track.mp3': '"entity-a"',
      });
      expect(restored.tasks.single.task.manuallyRetryingFilePaths, isEmpty);
      expect(restored.tasks.single.createdOutputPaths, {
        'C:/Downloads/Work 1/track.mp3',
      });

      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      expect(decoded['version'], 3);
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
    'queued checkpoints include ownership added before the shared write starts',
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
      manager.debugRecordCreatedOutputPathForTesting(_key(1), 'first.mp3');
      manager.debugRecordDownloadChunkForTesting(_key(1), 'track.mp3', 1, 1);
      final second = manager.flushPersistence();
      manager.debugRecordCreatedOutputPathForTesting(_key(1), 'later.mp3');
      firstWrite.complete();
      await Future.wait([first, second]);
      final restored = decodePersistedDownloadTasks(writes[1]!);
      expect(restored.tasks.single.createdOutputPaths, {
        'first.mp3',
        'later.mp3',
      });
    },
  );

  test(
    'concurrent barriers share one queued snapshot and await its commit',
    () async {
      final started = [Completer<void>(), Completer<void>()];
      final release = [Completer<void>(), Completer<void>()];
      final writes = <String?>[];
      final ownedPaths = <String>{};
      final store = AsmrDownloadTaskStore(
        persistTasks: true,
        persistenceSnapshot: (task) => PersistedDownloadTask(
          task: task,
          createdOutputPaths: ownedPaths,
          createdJsonDocuments: const {},
        ),
        persistenceWriter: (payload) async {
          final index = writes.length;
          writes.add(payload);
          if (index < 2) {
            started[index].complete();
            await release[index].future;
          }
        },
      );
      addTearDown(store.shutdown);
      store.restoreTask(_task(1));
      expect(store.isFileEntityTagDurable(_key(1), 'a.mp3', null), isTrue);
      final first = store.flushPersistence();
      await started[0].future;
      store[_key(1)] = _task(1).copyWith(fileEntityTags: {'a.mp3': '"a"'});
      ownedPaths.add('a.mp3');
      var committed = false;
      final second = store.flushPersistence().then((_) => committed = true);
      store[_key(1)] = store[_key(1)]!.copyWith(
        fileEntityTags: {'a.mp3': '"a"', 'b.mp3': '"b"'},
      );
      ownedPaths.add('b.mp3');
      final third = store.flushPersistence();
      release[0].complete();
      await first;
      await started[1].future;
      expect(committed, isFalse);
      expect(store.isFileEntityTagDurable(_key(1), 'a.mp3', null), isFalse);
      expect(store.isFileEntityTagDurable(_key(1), 'a.mp3', '"a"'), isFalse);
      expect(writes, hasLength(2));
      final captured = decodePersistedDownloadTasks(writes.last!).tasks.single;
      expect(captured.task.fileEntityTags, {'a.mp3': '"a"', 'b.mp3': '"b"'});
      expect(captured.createdOutputPaths, {'a.mp3', 'b.mp3'});
      // Work added after capture still needs its own committed barrier.
      ownedPaths.add('c.mp3');
      final fourth = store.flushPersistence();
      release[1].complete();
      await Future.wait([second, third, fourth]);
      expect(store.isFileEntityTagDurable(_key(1), 'a.mp3', '"a"'), isTrue);
      expect(writes, hasLength(3));
      expect(
        decodePersistedDownloadTasks(
          writes.last!,
        ).tasks.single.createdOutputPaths,
        {'a.mp3', 'b.mp3', 'c.mp3'},
      );
    },
  );

  test(
    'shared barrier failures reach every waiter and a later flush retries',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      var fail = true;
      var writes = 0;
      final store = AsmrDownloadTaskStore(
        persistTasks: true,
        persistenceSnapshot: (task) => PersistedDownloadTask(
          task: task,
          createdOutputPaths: const {},
          createdJsonDocuments: const {},
        ),
        persistenceWriter: (_) async {
          writes++;
          if (writes == 1) {
            started.complete();
            await release.future;
          } else if (fail) {
            throw StateError('disk unavailable');
          }
        },
      );
      addTearDown(store.shutdown);
      store[_key(1)] = _task(1);
      final first = store.flushPersistence();
      await started.future;
      final second = expectLater(store.flushPersistence(), throwsStateError);
      final third = expectLater(store.flushPersistence(), throwsStateError);
      release.complete();
      await Future.wait([first, second, third]);
      expect(writes, 2);
      fail = false;
      await store.flushPersistence();
      expect(writes, 3);
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
    store.taskStream(_key(1)).listen(null, onDone: taskDone.complete);
    store.buttonViewStateStream.listen(null, onDone: buttonDone.complete);

    store[_key(1)] = _task(1);
    store.notifyTaskChanged(changedWorkIds: {_key(1)});
    expect(store.tasks, hasLength(1));
    expect(store.taskIds, [_key(1)]);

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
    manager.debugRemoveTaskForTesting(_key(1));
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
    manager.debugRemoveTaskForTesting(_key(2));
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
      manager.debugRecordDownloadChunkForTesting(_key(1), 'track.mp3', 1, 1);
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
    expect(payload['version'], 3);
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
      manager.debugRecordDownloadChunkForTesting(_key(1), 'track.mp3', 1, byte);
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
    expect(payload['version'], 3);
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

    await manager.pauseTask(_key(1));
    expect(writes, hasLength(1));
    expect(_persistedMessage(writes.single), 'paused');

    writes.clear();
    await manager.cancelTask(_key(1), deleteDownloaded: false);
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
      _key(2),
      'track.mp3',
      64,
      64,
    );
    await shuttingDownManager.shutdown();

    expect(shutdownWrites, hasLength(1));
    expect(
      (jsonDecode(shutdownWrites.single!) as Map<String, Object?>)['version'],
      3,
    );
    await shuttingDownManager.shutdown();
    expect(shutdownWrites, hasLength(1));
  });

  test(
    'removing a task invalidates committed and in-flight durability metadata before recreation',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      var writes = 0;
      final store = AsmrDownloadTaskStore(
        persistTasks: true,
        persistenceSnapshot: (task) => PersistedDownloadTask(
          task: task,
          createdOutputPaths: const {},
          createdJsonDocuments: const {},
        ),
        persistenceWriter: (_) async {
          writes++;
          if (writes == 2) {
            started.complete();
            await release.future;
          }
        },
      );
      addTearDown(store.shutdown);

      final initial = _task(1).copyWith(
        fileEntityTags: const {'track.mp3': '"v1"'},
        actualOutputPaths: const {'track.mp3': 'Work 1/track.mp3'},
      );
      store[_key(1)] = initial;
      await store.flushPersistence();
      expect(store.isFileEntityTagDurable(_key(1), 'track.mp3', '"v1"'), isTrue);
      expect(
        store.isFileOutputPathDurable(_key(1), 'track.mp3', 'Work 1/track.mp3'),
        isTrue,
      );

      // Start a write that captures task 1, then remove and recreate before commit.
      final inflight = store.flushPersistence();
      await started.future;
      store.remove(_key(1));
      store[_key(1)] = initial;
      expect(
        store.isFileEntityTagDurable(_key(1), 'track.mp3', '"v1"'),
        isFalse,
      );
      expect(store.isFileEntityTagDurable(_key(1), 'track.mp3', null), isFalse);
      expect(
        store.isFileOutputPathDurable(_key(1), 'track.mp3', 'Work 1/track.mp3'),
        isFalse,
      );

      release.complete();
      await inflight;
      // The completed pre-removal write must not resurrect stale metadata.
      expect(
        store.isFileEntityTagDurable(_key(1), 'track.mp3', '"v1"'),
        isFalse,
      );
      expect(
        store.isFileOutputPathDurable(_key(1), 'track.mp3', 'Work 1/track.mp3'),
        isFalse,
      );

      await store.flushPersistence();
      expect(store.isFileEntityTagDurable(_key(1), 'track.mp3', '"v1"'), isTrue);
      expect(
        store.isFileOutputPathDurable(_key(1), 'track.mp3', 'Work 1/track.mp3'),
        isTrue,
      );
    },
  );

  test(
    'dedicated JSON file migrates legacy SharedPreferences record and uses lightweight progress checkpoints',
    () async {
      final supportDir = await Directory.systemTemp.createTemp(
        'asmr_download_store_file_',
      );
      addTearDown(() async {
        if (await supportDir.exists()) {
          await supportDir.delete(recursive: true);
        }
      });

      final legacyPayload = encodePersistedDownloadTasks(<PersistedDownloadTask>[
        PersistedDownloadTask(
          task: _task(1).copyWith(downloadedBytes: 64),
          createdOutputPaths: const {},
          createdJsonDocuments: const {},
        ),
      ]);
      SharedPreferences.setMockInitialValues(<String, Object>{
        AppPreferences.asmrDownloadTasksKey: legacyPayload,
      });

      final operations = <AsmrDownloadStoreOperation>[];
      final manager = AsmrDownloadManager(
        persistenceDirectoryProvider: () async => supportDir,
        storeOperationObserver: operations.add,
      );
      addTearDown(manager.shutdown);
      await manager.initialize();

      // Legacy SharedPreferences key is migrated to dedicated JSON file and cleared.
      final tasksFile = File(
        path.join(supportDir.path, AsmrDownloadTaskStore.tasksFileName),
      );
      final progressFile = File(
        path.join(supportDir.path, AsmrDownloadTaskStore.progressFileName),
      );
      expect(await tasksFile.exists(), isTrue);
      expect(
        await AppPreferences.getString(AppPreferences.asmrDownloadTasksKey),
        isNull,
      );
      expect(manager.getTask(_key(1))?.downloadedBytes, 64);

      // Flush initial post-init notification, then record pure progress chunks.
      await manager.flushPersistence();
      operations.clear();
      final tasksContentBeforeProgress = await tasksFile.readAsString();

      manager.debugRecordDownloadChunkForTesting(_key(1), 'track.mp3', 200, 264);
      manager.debugFlushProgressNotificationsForTesting();
      await manager.debugRunProgressCheckpointForTesting();

      // Progress checkpoint writes lightweight progress sidecar without re-encoding tasks file.
      expect(
        operations.where(
          (op) => op == AsmrDownloadStoreOperation.persistenceSnapshot,
        ),
        isEmpty,
      );
      expect(await progressFile.exists(), isTrue);
      expect(await tasksFile.readAsString(), tasksContentBeforeProgress);

      // Restarting merges the lightweight progress checkpoint offsets.
      final restored = AsmrDownloadManager(
        persistenceDirectoryProvider: () async => supportDir,
      );
      addTearDown(restored.shutdown);
      await restored.initialize();
      expect(restored.getTask(_key(1))?.downloadedBytes, 264);
      expect(restored.getTask(_key(1))?.fileDownloadedBytes['track.mp3'], 264);
    },
  );

  test(
    'buttonViewState quantizes sub-step progress deltas to avoid redundant header repaints',
    () async {
      final store = AsmrDownloadTaskStore(
        persistTasks: false,
        persistenceSnapshot: (task) => PersistedDownloadTask(
          task: task,
          createdOutputPaths: const {},
          createdJsonDocuments: const {},
        ),
      );
      addTearDown(store.shutdown);
      final emitted = <AsmrDownloadButtonViewState>[];
      final sub = store.buttonViewStateStream.listen(emitted.add);
      addTearDown(sub.cancel);

      store[_key(1)] = _task(1).copyWith(
        totalBytes: 100000,
        fileTotalBytes: const {'track.mp3': 100000},
      );
      store.notifyTaskChanged(changedWorkIds: {_key(1)});
      await Future<void>.delayed(Duration.zero);
      emitted.clear();

      // Small increments (< 0.25% each) stay in the same 0.5% bucket -> no extra emissions.
      store.recordDownloadChunk(_key(1), 'track.mp3', 100, 100);
      store.flushPendingProgressNotifications();
      store.recordDownloadChunk(_key(1), 'track.mp3', 100, 200);
      store.flushPendingProgressNotifications();
      await Future<void>.delayed(Duration.zero);
      expect(emitted, isEmpty);

      // Crossing 0.5% emits once with quantized 0.005 progress.
      store.recordDownloadChunk(_key(1), 'track.mp3', 300, 500);
      store.flushPendingProgressNotifications();
      await Future<void>.delayed(Duration.zero);
      expect(emitted, hasLength(1));
      expect(emitted.single.progress, 0.005);
    },
  );

  test(
    'H23 shutdown pauses only non-terminal tasks and preserves completed and failed states',
    () async {
      final writes = <String?>[];
      final store = AsmrDownloadTaskStore(
        persistTasks: true,
        persistenceWriter: (payload) async => writes.add(payload),
        persistenceSnapshot: (task) => PersistedDownloadTask(
          task: task,
          createdOutputPaths: const {},
          createdJsonDocuments: const {},
        ),
      );
      store[_key(1)] = _task(1).copyWith(
        status: AsmrDownloadTaskStatus.idle,
        message: 'queued',
      );
      store[_key(2)] = _task(2).copyWith(
        status: AsmrDownloadTaskStatus.downloading,
        message: 'downloading',
      );
      store[_key(3)] = _task(3).copyWith(
        status: AsmrDownloadTaskStatus.completed,
        message: 'completed',
      );
      store[_key(4)] = _task(4).copyWith(
        status: AsmrDownloadTaskStatus.failed,
        message: 'completed_with_failures',
        error: 'http 500',
      );

      await store.shutdown(
        pauseWorkIds: [_key(1), _key(2), _key(3), _key(4)],
      );

      expect(store[_key(1)]!.status, AsmrDownloadTaskStatus.paused);
      expect(store[_key(2)]!.status, AsmrDownloadTaskStatus.paused);
      expect(store[_key(3)]!.status, AsmrDownloadTaskStatus.completed);
      expect(store[_key(4)]!.status, AsmrDownloadTaskStatus.failed);
      expect(store[_key(4)]!.error, 'http 500');

      final persisted = decodePersistedDownloadTasks(writes.last!).tasks;
      final byId = {for (final item in persisted) item.task.work.workKey: item.task};
      expect(byId.keys, {_key(1), _key(2), _key(4)});
      expect(byId[_key(1)]!.status, AsmrDownloadTaskStatus.paused);
      expect(byId[_key(2)]!.status, AsmrDownloadTaskStatus.paused);
      expect(byId[_key(4)]!.status, AsmrDownloadTaskStatus.failed);
      expect(byId[_key(4)]!.error, 'http 500');
    },
  );
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
  await manager
      .taskStream(_key(workId))
      .firstWhere((task) => task?.status == status);
}

String _key(int id) => _work(id).workKey;
