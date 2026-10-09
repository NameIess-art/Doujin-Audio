import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/persistence/json_document_store.dart';
import 'package:doujin_audio/features/library/application/audio_detail_cache_service.dart';
import 'package:doujin_audio/features/library/application/audio_detail_repository.dart';

void main() {
  test(
    'equivalent Windows paths share detail cache and operation queue',
    () async {
      final target = AudioDetailTarget.libraryRootFolder('E:/Library/Work');
      final alias = AudioDetailTarget.libraryRootFolder(r'e:\library\work');
      final repository = _FakeAudioDetailRepository(
        AudioDetail.empty(target).copyWith(workTitle: 'Saved work'),
      );
      final cache = AudioDetailCacheService(repository: repository);
      final loaded = await Future.wait([cache.load(target), cache.load(alias)]);
      expect(
        loaded.map((result) => result.detail.workTitle),
        everyElement('Saved work'),
      );
      expect(repository.loadCount, 1);
      await cache.updateDerivedFields(
        alias,
        duration: const Duration(seconds: 3),
      );
      expect(
        cache.resolvedDetail(target)?.duration,
        const Duration(seconds: 3),
      );
      expect(cache.resolvedDetail(alias)?.workTitle, 'Saved work');
    },
  );

  test(
    'cache deduplicates concurrent loads and retains resolved detail',
    () async {
      final target = AudioDetailTarget.libraryRootFolder('/library/work');
      final repository = _FakeAudioDetailRepository(
        AudioDetail.empty(target).copyWith(workTitle: 'Cached'),
      );
      final cache = AudioDetailCacheService(repository: repository);

      final results = await Future.wait(<Future<AudioDetailLoadResult>>[
        cache.load(target),
        cache.load(target),
      ]);

      expect(
        results.map((result) => result.detail.workTitle),
        everyElement('Cached'),
      );
      expect(repository.loadCount, 1);
      expect(cache.resolvedDetail(target)?.workTitle, 'Cached');
    },
  );

  test('derived updates refresh cache without using explicit save', () async {
    final target = AudioDetailTarget.libraryRootFolder('/library/work');
    final repository = _FakeAudioDetailRepository(AudioDetail.empty(target));
    final cache = AudioDetailCacheService(repository: repository);

    final updated = await cache.updateDerivedFields(
      target,
      duration: const Duration(seconds: 3),
    );

    expect(updated.duration, const Duration(seconds: 3));
    expect(cache.resolvedDetail(target)?.duration, const Duration(seconds: 3));
    expect(repository.explicitSaveCount, 0);
  });

  for (final paths in <(String, String)>[
    ('/library/work', '/library/work'),
    ('E:/Library/Work', r'e:\library\work'),
  ]) {
    test('single read reuses a pending batch for ${paths.$1}', () async {
      final target = AudioDetailTarget.libraryRootFolder(paths.$1);
      final alias = AudioDetailTarget.libraryRootFolder(paths.$2);
      final started = Completer<void>();
      final release = Completer<void>();
      final repository =
          _FakeAudioDetailRepository(
              AudioDetail.empty(target).copyWith(workTitle: 'Saved work'),
            )
            ..beforeBatchLoad = (_) async {
              started.complete();
              await release.future;
            };
      final cache = AudioDetailCacheService(repository: repository);
      final batch = cache.loadMany([target]);
      await started.future;
      final single = cache.load(alias);
      release.complete();

      final batchResult = await batch;
      expect(await single, same(batchResult.single));
      expect(repository.batchRequests, hasLength(1));
      expect(repository.loadCount, 0);
    });
  }

  test('overlapping batches only query unresolved targets in order', () async {
    final targets = <AudioDetailTarget>[
      for (final name in ['a', 'b', 'c'])
        AudioDetailTarget.libraryRootFolder('/library/$name'),
    ];
    final started = Completer<void>();
    final release = Completer<void>();
    final repository =
        _FakeAudioDetailRepository(AudioDetail.empty(targets.first))
          ..beforeBatchLoad = (_) async {
            if (started.isCompleted) return;
            started.complete();
            await release.future;
          };
    final cache = AudioDetailCacheService(repository: repository);
    final first = cache.loadMany(targets.take(2));
    await started.future;
    final second = cache.loadMany([targets[1], targets[2], targets[1]]);
    release.complete();

    await first;
    expect((await second).map((result) => result.detail.target), [
      targets[1],
      targets[2],
      targets[1],
    ]);
    expect(repository.batchRequests, [
      targets.take(2).toList(),
      [targets[2]],
    ]);
    expect(repository.loadCount, 0);
  });

  test('queued read observes a save after a pending batch', () async {
    final target = AudioDetailTarget.libraryRootFolder('/library/work');
    final started = Completer<void>();
    final release = Completer<void>();
    final repository =
        _FakeAudioDetailRepository(
            AudioDetail.empty(target).copyWith(workTitle: 'Before'),
          )
          ..beforeBatchLoad = (_) async {
            started.complete();
            await release.future;
          };
    final cache = AudioDetailCacheService(repository: repository);
    final batch = cache.loadMany([target]);
    await started.future;
    final save = cache.save(repository.detail.copyWith(workTitle: 'After'));
    final read = cache.load(target);
    release.complete();

    expect((await batch).single.detail.workTitle, 'Before');
    await save;
    expect((await read).detail.workTitle, 'After');
    expect(repository.batchRequests, hasLength(1));
    expect(repository.loadCount, 0);
    expect(repository.explicitSaveCount, 1);
  });

  test('failed batch leaves overlapping reads able to retry', () async {
    final target = AudioDetailTarget.libraryRootFolder('/library/work');
    final started = Completer<void>();
    final release = Completer<void>();
    final repository =
        _FakeAudioDetailRepository(
            AudioDetail.empty(target).copyWith(workTitle: 'Retried'),
          )
          ..beforeBatchLoad = (_) async {
            if (started.isCompleted) return;
            started.complete();
            await release.future;
            throw StateError('Batch failed');
          };
    final cache = AudioDetailCacheService(repository: repository);
    final first = cache.loadMany([target]);
    final failure = expectLater(first, throwsStateError);
    await started.future;
    final retry = cache.loadMany([target]);
    release.complete();

    await failure;
    expect((await retry).single.detail.workTitle, 'Retried');
    expect(repository.batchRequests, hasLength(2));
    expect((await cache.load(target)).detail.workTitle, 'Retried');
    expect(repository.loadCount, 0);
  });

  test('suspend cancels new operations', () async {
    final target = AudioDetailTarget.libraryRootFolder('/library/work');
    final cache = AudioDetailCacheService(
      repository: _FakeAudioDetailRepository(AudioDetail.empty(target)),
    );
    await cache.suspendAndWait();

    expect(cache.load(target), throwsA(isA<AudioDetailOperationCancelled>()));
  });

  test('trimMemory prunes resolved details down to budget', () async {
    final repository = _FakeAudioDetailRepository(
      AudioDetail.empty(AudioDetailTarget.libraryRootFolder('/library/work')),
    );
    final cache = AudioDetailCacheService(
      repository: repository,
      maxResolvedEntries: 20,
    );

    for (var i = 0; i < 15; i++) {
      final target = AudioDetailTarget.libraryRootFolder('/library/work_$i');
      repository.detail = AudioDetail.empty(target);
      await cache.load(target);
      expect(cache.resolvedDetail(target), isNotNull);
    }

    cache.trimMemory();

    // With maxResolvedEntries: 20, trimMemory prunes to 20 ~/ 10 = 2 entries
    var retainedCount = 0;
    for (var i = 0; i < 15; i++) {
      final target = AudioDetailTarget.libraryRootFolder('/library/work_$i');
      if (cache.resolvedDetail(target) != null) {
        retainedCount++;
      }
    }
    expect(retainedCount, 2);
  });
}

final class _FakeAudioDetailRepository implements AudioDetailRepository {
  _FakeAudioDetailRepository(this.detail);

  @override
  Future<bool> exportTimeSegments(AudioDetailTarget target) async => true;

  AudioDetail detail;
  int loadCount = 0;
  int explicitSaveCount = 0;
  final List<List<AudioDetailTarget>> batchRequests = [];
  Future<void> Function(List<AudioDetailTarget>)? beforeBatchLoad;

  @override
  Future<AudioDetailLoadResult> load(AudioDetailTarget target) async {
    loadCount++;
    return AudioDetailLoadResult(detail: detail);
  }

  @override
  Future<List<AudioDetailLoadResult>> loadMany(
    Iterable<AudioDetailTarget> targets,
  ) async {
    final values = targets.toList(growable: false);
    batchRequests.add(values);
    await beforeBatchLoad?.call(values);
    return <AudioDetailLoadResult>[
      for (final target in values)
        AudioDetailLoadResult(detail: detail.copyWith(target: target)),
    ];
  }

  @override
  Future<AudioDetailSaveResult> save(AudioDetail next) async {
    explicitSaveCount++;
    detail = next;
    return AudioDetailSaveResult(
      detail: next,
      documentStatus: JsonDocumentWriteStatus.replaced,
    );
  }

  @override
  Future<AudioDetailSaveResult> retarget(
    AudioDetailTarget previousTarget,
    AudioDetail next,
  ) => save(next);

  @override
  Future<AudioDetailSaveResult> saveMissingDuration(
    AudioDetailTarget target,
    Duration duration,
  ) async {
    detail = detail.copyWith(
      target: target,
      duration: detail.duration ?? duration,
    );
    return AudioDetailSaveResult(
      detail: detail,
      documentStatus: JsonDocumentWriteStatus.replaced,
    );
  }

  @override
  Future<AudioDetail> updateDerivedFields(
    AudioDetailTarget target, {
    String? rjCode,
    Duration? duration,
    String? cardCoverPath,
    bool? cardCoverSelected,
  }) async {
    var next = detail.copyWith(
      target: target,
      rjCode: detail.rjCode.isEmpty ? rjCode : null,
      duration: detail.duration ?? duration,
    );
    if (cardCoverPath != null || cardCoverSelected != null) {
      next = next.copyWith(
        cardCoverPath: cardCoverPath,
        cardCoverSelected: cardCoverSelected,
      );
    }
    detail = next;
    return next;
  }

  @override
  Future<AudioDetailBackupImportResult> importBackupsMany(
    Iterable<AudioDetailTarget> targets,
  ) async => const AudioDetailBackupImportResult();

  @override
  Future<AudioDetailSaveResult?> prefillRjCodeFromText(
    AudioDetailTarget target,
    String text,
  ) async => null;

  @override
  Future<void> delete(AudioDetailTarget target) async {}

  @override
  Future<void> deleteMany(Iterable<AudioDetailTarget> targets) async {}
}
