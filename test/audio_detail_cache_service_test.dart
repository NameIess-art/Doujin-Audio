import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/audio_detail.dart';
import 'package:nameless_audio/features/library/application/audio_detail_cache_service.dart';
import 'package:nameless_audio/features/library/application/audio_detail_repository.dart';

void main() {
  test('load reuses in-flight and resolved detail results by target', () async {
    final target = AudioDetailTarget.libraryRootFolder('/library/work');
    final repository = _FakeAudioDetailRepository(
      loadResult: AudioDetail.empty(target).copyWith(workTitle: 'Loaded'),
    );
    final cache = AudioDetailCacheService(repository: repository);

    final first = cache.load(target);
    final second = cache.load(target);

    expect(identical(first, second), isTrue);
    expect((await first).detail.workTitle, 'Loaded');
    expect(repository.loadCount, 1);

    final resolved = await cache.load(target);
    expect(resolved.detail.workTitle, 'Loaded');
    expect(repository.loadCount, 1);
  });

  test(
    'save, delete, and prefill bump revision and update cached detail',
    () async {
      final target = AudioDetailTarget.libraryRootFolder('/library/work');
      final repository = _FakeAudioDetailRepository(
        loadResult: AudioDetail.empty(target),
        prefillResult: AudioDetail.empty(target).copyWith(rjCode: 'RJ123456'),
      );
      final cache = AudioDetailCacheService(repository: repository);

      expect(cache.revision, 0);

      await cache.save(AudioDetail.empty(target).copyWith(workTitle: 'Saved'));
      expect(cache.revision, 1);
      expect((await cache.load(target)).detail.workTitle, 'Saved');

      final prefilled = await cache.prefillRjCodeFromText(target, 'RJ123456');
      expect(prefilled, isNotNull);
      expect(cache.revision, 2);
      expect((await cache.load(target)).detail.rjCode, 'RJ123456');

      await cache.delete(target);
      expect(cache.revision, 3);
      expect(repository.deleteCount, 1);
    },
  );

  test('resolved details use least-recently-used eviction', () async {
    final first = AudioDetailTarget.libraryRootFolder('/library/first');
    final second = AudioDetailTarget.libraryRootFolder('/library/second');
    final third = AudioDetailTarget.libraryRootFolder('/library/third');
    final repository = _FakeAudioDetailRepository(
      loadResult: AudioDetail.empty(first),
    );
    final cache = AudioDetailCacheService(
      repository: repository,
      maxResolvedEntries: 2,
    );

    await cache.load(first);
    await cache.load(second);
    await cache.load(first);
    await cache.load(third);
    expect(repository.loadCount, 3);

    await cache.load(second);
    expect(repository.loadCount, 4);
    await cache.load(third);
    expect(repository.loadCount, 4);
  });

  test(
    'clear prevents an older in-flight load from repopulating cache',
    () async {
      final target = AudioDetailTarget.libraryRootFolder('/library/work');
      final pendingLoad = Completer<AudioDetail>();
      final repository = _FakeAudioDetailRepository(
        loadResult: AudioDetail.empty(target),
        pendingLoad: pendingLoad,
      );
      final cache = AudioDetailCacheService(repository: repository);

      final staleLoad = cache.load(target);
      cache.clear();
      repository.pendingLoad = null;
      repository.loadResult = AudioDetail.empty(
        target,
      ).copyWith(workTitle: 'Restored database title');
      pendingLoad.complete(
        AudioDetail.empty(target).copyWith(workTitle: 'Stale cached title'),
      );
      expect((await staleLoad).detail.workTitle, 'Stale cached title');

      final reloaded = await cache.load(target);

      expect(reloaded.detail.workTitle, 'Restored database title');
      expect(repository.loadCount, 2);
    },
  );
}

class _FakeAudioDetailRepository implements AudioDetailRepository {
  _FakeAudioDetailRepository({
    required this.loadResult,
    AudioDetail? prefillResult,
    this.pendingLoad,
  }) : _prefillResult = prefillResult;

  AudioDetail loadResult;
  Completer<AudioDetail>? pendingLoad;
  final AudioDetail? _prefillResult;
  int loadCount = 0;
  int deleteCount = 0;

  @override
  Future<AudioDetailLoadResult> load(AudioDetailTarget target) async {
    loadCount++;
    final pending = pendingLoad;
    final detail = pending == null ? loadResult : await pending.future;
    return AudioDetailLoadResult(detail: detail.copyWith(target: target));
  }

  @override
  Future<List<AudioDetailLoadResult>> loadMany(
    Iterable<AudioDetailTarget> targets,
  ) {
    return Future.wait(targets.map(load));
  }

  @override
  Future<AudioDetailSaveResult> save(AudioDetail detail) async {
    loadResult = detail;
    return AudioDetailSaveResult(
      detail: detail,
      backupAttempted: false,
      backupSaved: false,
    );
  }

  @override
  Future<void> delete(AudioDetailTarget target) async {
    deleteCount++;
  }

  @override
  Future<void> deleteMany(Iterable<AudioDetailTarget> targets) async {
    deleteCount += targets.length;
  }

  @override
  Future<AudioDetailSaveResult?> prefillRjCodeFromText(
    AudioDetailTarget target,
    String text,
  ) async {
    final detail = _prefillResult;
    if (detail == null) return null;
    loadResult = detail;
    return AudioDetailSaveResult(
      detail: detail,
      backupAttempted: false,
      backupSaved: false,
    );
  }
}
