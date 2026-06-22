import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/audio_detail.dart';
import 'package:nameless_audio/models/library_node.dart';
import 'package:nameless_audio/models/music_track.dart';
import 'package:nameless_audio/services/audio_detail_cache_service.dart';
import 'package:nameless_audio/services/audio_detail_repository.dart';
import 'package:nameless_audio/services/audio_state_services.dart';
import 'package:nameless_audio/services/library_snapshot_cache_service.dart';

void main() {
  test(
    'tree snapshot reuses the in-flight future for the same revision',
    () async {
      final library = LibraryService();
      library.watchedFolders.add('/library');
      library.library.add(
        _track(path: '/library/work/track.mp3', groupKey: '/library/work'),
      );
      library.markStructureChanged();
      final service = LibrarySnapshotCacheService(
        libraryService: library,
        detailCacheService: AudioDetailCacheService(
          repository: _FakeAudioDetailRepository(),
        ),
      );

      final first = service.treeSnapshot(onCommitted: () {});
      final second = service.treeSnapshot(onCommitted: () {});

      expect(identical(first, second), isTrue);
      expect((await first).tree, isNotEmpty);
    },
  );

  test(
    'category snapshot reuses cached detail loads until detail revision changes',
    () async {
      final target = AudioDetailTarget.libraryRootFolder('/library');
      final repository = _FakeAudioDetailRepository(
        details: {AudioLibraryDetailKey.forTarget(target): 'Initial'},
      );
      final detailCache = AudioDetailCacheService(repository: repository);
      final library = LibraryService();
      library.watchedFolders.add('/library');
      library.library.add(
        _track(path: '/library/work/track.mp3', groupKey: '/library/work'),
      );
      library.markStructureChanged();
      final service = LibrarySnapshotCacheService(
        libraryService: library,
        detailCacheService: detailCache,
      );

      final first = await service.categorySnapshot(onCommitted: () {});
      final second = await service.categorySnapshot(onCommitted: () {});

      expect(first.entries.single.detail.workTitle, 'Initial');
      expect(second.entries.single.detail.workTitle, 'Initial');
      expect(repository.loadCount, 1);

      final saved = await detailCache.save(
        AudioDetail.empty(target).copyWith(workTitle: 'Updated'),
      );
      service.markDetailChanged(saved.detail);

      final updated = await service.categorySnapshot(onCommitted: () {});
      expect(updated.entries.single.detail.workTitle, 'Updated');
    },
  );

  test('tree sync invalidates when the library structure revision changes', () {
    final library = LibraryService();
    library.watchedFolders.add('/library');
    final service = LibrarySnapshotCacheService(
      libraryService: library,
      detailCacheService: AudioDetailCacheService(
        repository: _FakeAudioDetailRepository(),
      ),
    );

    expect(service.treeSync, isEmpty);

    library.library.add(
      _track(path: '/library/work/track.mp3', groupKey: '/library/work'),
    );
    library.markStructureChanged();
    service.markStructureChanged();

    expect(service.treeSync.whereType<FolderNode>(), isNotEmpty);
  });
}

MusicTrack _track({required String path, required String groupKey}) {
  return MusicTrack(
    path: path,
    displayName: 'Track',
    groupKey: groupKey,
    groupTitle: 'Work',
    groupSubtitle: groupKey,
    isSingle: false,
  );
}

class _FakeAudioDetailRepository implements AudioDetailRepository {
  _FakeAudioDetailRepository({Map<String, String>? details})
    : _details = details ?? const <String, String>{};

  final Map<String, String> _details;
  int loadCount = 0;

  @override
  Future<AudioDetailLoadResult> load(AudioDetailTarget target) async {
    loadCount++;
    final title = _details[AudioLibraryDetailKey.forTarget(target)] ?? '';
    return AudioDetailLoadResult(
      detail: AudioDetail.empty(target).copyWith(workTitle: title),
    );
  }

  @override
  Future<AudioDetailSaveResult> save(AudioDetail detail) async {
    return AudioDetailSaveResult(
      detail: detail,
      backupAttempted: false,
      backupSaved: false,
    );
  }

  @override
  Future<void> delete(AudioDetailTarget target) async {}

  @override
  Future<AudioDetailSaveResult?> prefillRjCodeFromText(
    AudioDetailTarget target,
    String text,
  ) async {
    return null;
  }
}
