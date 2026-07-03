import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/audio_detail.dart';
import 'package:nameless_audio/services/audio_detail_cache_service.dart';
import 'package:nameless_audio/services/audio_detail_repository.dart';

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
}

class _FakeAudioDetailRepository implements AudioDetailRepository {
  _FakeAudioDetailRepository({
    required AudioDetail loadResult,
    AudioDetail? prefillResult,
  }) : _loadResult = loadResult,
       _prefillResult = prefillResult;

  AudioDetail _loadResult;
  final AudioDetail? _prefillResult;
  int loadCount = 0;
  int deleteCount = 0;

  @override
  Future<AudioDetailLoadResult> load(AudioDetailTarget target) async {
    loadCount++;
    return AudioDetailLoadResult(detail: _loadResult);
  }

  @override
  Future<List<AudioDetailLoadResult>> loadMany(
    Iterable<AudioDetailTarget> targets,
  ) {
    return Future.wait(targets.map(load));
  }

  @override
  Future<AudioDetailSaveResult> save(AudioDetail detail) async {
    _loadResult = detail;
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
  Future<AudioDetailSaveResult?> prefillRjCodeFromText(
    AudioDetailTarget target,
    String text,
  ) async {
    final detail = _prefillResult;
    if (detail == null) return null;
    _loadResult = detail;
    return AudioDetailSaveResult(
      detail: detail,
      backupAttempted: false,
      backupSaved: false,
    );
  }
}
