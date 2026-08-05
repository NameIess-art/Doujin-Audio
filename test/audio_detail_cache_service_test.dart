import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/audio_detail.dart';
import 'package:nameless_audio/core/persistence/json_document_store.dart';
import 'package:nameless_audio/features/library/application/audio_detail_cache_service.dart';
import 'package:nameless_audio/features/library/application/audio_detail_repository.dart';

void main() {
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
      AudioDetail.empty(target).copyWith(duration: const Duration(seconds: 3)),
    );

    expect(updated.duration, const Duration(seconds: 3));
    expect(cache.resolvedDetail(target)?.duration, const Duration(seconds: 3));
    expect(repository.explicitSaveCount, 0);
  });

  test('suspend cancels new operations', () async {
    final target = AudioDetailTarget.libraryRootFolder('/library/work');
    final cache = AudioDetailCacheService(
      repository: _FakeAudioDetailRepository(AudioDetail.empty(target)),
    );
    await cache.suspendAndWait();

    expect(cache.load(target), throwsA(isA<AudioDetailOperationCancelled>()));
  });
}

final class _FakeAudioDetailRepository implements AudioDetailRepository {
  _FakeAudioDetailRepository(this.detail);

  AudioDetail detail;
  int loadCount = 0;
  int explicitSaveCount = 0;

  @override
  Future<AudioDetailLoadResult> load(AudioDetailTarget target) async {
    loadCount++;
    return AudioDetailLoadResult(detail: detail);
  }

  @override
  Future<List<AudioDetailLoadResult>> loadMany(
    Iterable<AudioDetailTarget> targets,
  ) async => <AudioDetailLoadResult>[
    for (final _ in targets) AudioDetailLoadResult(detail: detail),
  ];

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
  Future<AudioDetail> updateDerivedFields(AudioDetail next) async {
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
