import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/audio_detail.dart';
import 'package:nameless_audio/features/library/domain/library_node.dart';
import 'package:nameless_audio/core/media/music_track.dart';
import 'package:nameless_audio/features/library/application/audio_detail_cache_service.dart';
import 'package:nameless_audio/features/library/application/audio_detail_repository.dart';
import 'package:nameless_audio/features/library/application/library_service.dart';
import 'package:nameless_audio/features/library/application/library_snapshot_cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    'tree snapshot runs every callback attached to an in-flight build',
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

      var firstCommitted = false;
      var secondCommitted = false;
      final first = service.treeSnapshot(
        onCommitted: () => firstCommitted = true,
      );
      final second = service.treeSnapshot(
        onCommitted: () => secondCommitted = true,
      );

      expect(identical(first, second), isTrue);
      await first;

      expect(firstCommitted, isTrue);
      expect(secondCommitted, isTrue);
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
      await service.reconcileCategorySnapshot(onCommitted: () {});

      expect(service.treeSnapshotRevision, -1);
      expect(service.cardSnapshotRevision, library.structureRevision);
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

  test(
    'database category snapshot commits before backup reconciliation completes',
    () async {
      final target = AudioDetailTarget.libraryRootFolder('/library');
      final reconciliationGate = Completer<void>();
      final repository = _FakeAudioDetailRepository(
        databaseDetails: {
          AudioLibraryDetailKey.forTarget(target): 'Database preview',
        },
        details: {AudioLibraryDetailKey.forTarget(target): 'Backup reconciled'},
        reconciliationGate: reconciliationGate,
      );
      final library = LibraryService()
        ..watchedFolders.add('/library')
        ..library.add(
          _track(path: '/library/work/track.mp3', groupKey: '/library/work'),
        )
        ..markStructureChanged();
      final service = LibrarySnapshotCacheService(
        libraryService: library,
        detailCacheService: AudioDetailCacheService(repository: repository),
      );
      var commitCount = 0;

      final preview = await service.categorySnapshot(
        onCommitted: () => commitCount++,
      );

      expect(preview.entries.single.detail.workTitle, 'Database preview');
      expect(service.categorySnapshotSync, same(preview));
      expect(repository.databaseSnapshotLoadCount, 1);
      expect(repository.loadCount, 0);
      expect(commitCount, 1);

      final reconciliation = service.reconcileCategorySnapshot(
        onCommitted: () => commitCount++,
      );
      reconciliationGate.complete();
      await reconciliation;
      await Future<void>.delayed(Duration.zero);

      expect(
        service.categorySnapshotSync?.entries.single.detail.workTitle,
        'Backup reconciled',
      );
      expect(commitCount, 2);
    },
  );

  test(
    'stale backup reconciliation cannot overwrite a newer detail revision',
    () async {
      final target = AudioDetailTarget.libraryRootFolder('/library');
      final reconciliationGate = Completer<void>();
      final repository = _FakeAudioDetailRepository(
        databaseDetails: {
          AudioLibraryDetailKey.forTarget(target): 'Database preview',
        },
        details: {AudioLibraryDetailKey.forTarget(target): 'Stale backup'},
        reconciliationGate: reconciliationGate,
      );
      final detailCache = AudioDetailCacheService(repository: repository);
      final library = LibraryService()
        ..watchedFolders.add('/library')
        ..library.add(
          _track(path: '/library/work/track.mp3', groupKey: '/library/work'),
        )
        ..markStructureChanged();
      final service = LibrarySnapshotCacheService(
        libraryService: library,
        detailCacheService: detailCache,
      );

      await service.categorySnapshot(onCommitted: () {});
      final reconciliation = service.reconcileCategorySnapshot(
        onCommitted: () {},
      );
      final userDetail = AudioDetail.empty(
        target,
      ).copyWith(workTitle: 'New user edit');
      detailCache.markChanged(userDetail);
      service.markDetailChanged(userDetail);
      reconciliationGate.complete();
      await reconciliation;
      await Future<void>.delayed(Duration.zero);

      expect(
        service.categorySnapshotSync?.entries.single.detail.workTitle,
        'New user edit',
      );
    },
  );

  test(
    'derived snapshot keeps nested tracks under the watched work root for detail lookup',
    () async {
      const workRoot = '/library/work';
      final target = AudioDetailTarget.libraryRootFolder(workRoot);
      final repository = _FakeAudioDetailRepository(
        details: {AudioLibraryDetailKey.forTarget(target): 'Backup title'},
      );
      final library = LibraryService()
        ..watchedFolders.add(workRoot)
        ..library.add(
          _track(path: '$workRoot/disc/track.mp3', groupKey: '$workRoot/disc'),
        )
        ..markStructureChanged();
      final derived = buildLibraryDerivedSnapshot(
        LibraryDerivedSnapshotPayload(
          tracks: List<MusicTrack>.of(library.library),
          watchedFolders: List<String>.of(library.watchedFolders),
          nodeOrder: const <String>[],
        ),
      );
      final service = LibrarySnapshotCacheService(
        libraryService: library,
        detailCacheService: AudioDetailCacheService(repository: repository),
      )..adoptCardSnapshot(derived.cardSnapshot);

      final snapshot = await service.categorySnapshot(onCommitted: () {});

      expect(snapshot.entries, hasLength(1));
      expect(snapshot.entries.single.target, target);
      expect(snapshot.entries.single.detail.workTitle, 'Backup title');
    },
  );

  test('category detail batch failure falls back per work', () async {
    final firstTarget = AudioDetailTarget.libraryRootFolder('/library/first');
    final secondTarget = AudioDetailTarget.libraryRootFolder('/library/second');
    final repository = _FakeAudioDetailRepository(
      details: {
        AudioLibraryDetailKey.forTarget(firstTarget): 'First backup',
        AudioLibraryDetailKey.forTarget(secondTarget): 'Second backup',
      },
      failBatchLoad: true,
    );
    final library = LibraryService()
      ..watchedFolders.addAll(<String>['/library/first', '/library/second'])
      ..library.addAll(<MusicTrack>[
        _track(path: '/library/first/track.mp3', groupKey: '/library/first'),
        _track(path: '/library/second/track.mp3', groupKey: '/library/second'),
      ])
      ..markStructureChanged();
    final service = LibrarySnapshotCacheService(
      libraryService: library,
      detailCacheService: AudioDetailCacheService(repository: repository),
    );

    await service.categorySnapshot(onCommitted: () {});
    await service.reconcileCategorySnapshot(onCommitted: () {});

    expect(
      service.categorySnapshotSync?.entries.map(
        (entry) => entry.detail.workTitle,
      ),
      containsAll(<String>['First backup', 'Second backup']),
    );
    expect(repository.batchLoadCount, 1);
    expect(repository.loadCount, 2);
  });

  test('first category snapshot commits without a presentation gate', () async {
    final library = LibraryService()
      ..watchedFolders.add('/library')
      ..library.add(
        _track(path: '/library/work/track.mp3', groupKey: '/library/work'),
      )
      ..markStructureChanged();
    final repository = _FakeAudioDetailRepository();
    final service = LibrarySnapshotCacheService(
      libraryService: library,
      detailCacheService: AudioDetailCacheService(repository: repository),
    );
    var committed = false;

    final first = service.categorySnapshot(onCommitted: () => committed = true);
    final repeated = service.categorySnapshot(
      onCommitted: () => committed = true,
    );
    expect(identical(first, repeated), isTrue);

    await first;

    expect(repository.databaseSnapshotLoadCount, 1);
    expect(repository.loadCount, 0);
    expect(committed, isTrue);
  });

  test('category detail loading completes all batches immediately', () async {
    final repository = _FakeAudioDetailRepository();
    final library = LibraryService();
    for (var index = 0; index < 30; index++) {
      final folderPath = '/library_$index';
      library.watchedFolders.add(folderPath);
      library.library.add(
        _track(path: '$folderPath/track.mp3', groupKey: folderPath),
      );
    }
    library.markStructureChanged();
    final service = LibrarySnapshotCacheService(
      libraryService: library,
      detailCacheService: AudioDetailCacheService(repository: repository),
    );

    final snapshotFuture = service.categorySnapshot(onCommitted: () {});
    final snapshot = await snapshotFuture;
    await service.reconcileCategorySnapshot(onCommitted: () {});

    expect(repository.batchLoadCount, 2);
    expect(repository.loadCount, 30);
    expect(snapshot.entries, hasLength(30));
  });

  test('tree cache updates only after async snapshot commits', () async {
    final library = LibraryService();
    library.watchedFolders.add('/library');
    final service = LibrarySnapshotCacheService(
      libraryService: library,
      detailCacheService: AudioDetailCacheService(
        repository: _FakeAudioDetailRepository(),
      ),
    );

    expect(service.tree, isEmpty);
    expect(service.treeSnapshotRevision, -1);

    library.library.add(
      _track(path: '/library/work/track.mp3', groupKey: '/library/work'),
    );
    library.markStructureChanged();
    service.markStructureChanged();

    expect(service.tree, isEmpty);

    var committed = false;
    final snapshot = await service.treeSnapshot(
      onCommitted: () => committed = true,
    );

    expect(snapshot.tree.whereType<FolderNode>(), isNotEmpty);
    expect(service.tree.whereType<FolderNode>(), isNotEmpty);
    expect(service.treeSnapshotRevision, library.structureRevision);
    expect(committed, isTrue);
  });

  test(
    'top-level reorder updates the current tree cache synchronously',
    () async {
      final library = LibraryService();
      library.library.addAll(<MusicTrack>[
        _track(path: '/library/first/01.mp3', groupKey: '/library/first'),
        _track(path: '/library/second/01.mp3', groupKey: '/library/second'),
      ]);
      library.syncLibraryNodeOrder();
      library.markStructureChanged();
      final service = LibrarySnapshotCacheService(
        libraryService: library,
        detailCacheService: AudioDetailCacheService(
          repository: _FakeAudioDetailRepository(),
        ),
      );
      await service.cardSnapshot(onCommitted: () {});
      final initialOrder = service.cards.map((node) => node.path).toList();

      library.reorderLibraryNodes(
        0,
        initialOrder.length,
        currentTree: service.cards,
      );

      expect(service.applyCurrentTopLevelOrder(), isTrue);
      expect(service.cards.map((node) => node.path), <String>[
        initialOrder.last,
        initialOrder.first,
      ]);
      expect(service.cardSnapshotRevision, library.structureRevision);
    },
  );

  test(
    'card snapshot keeps folder tracks without building child nodes',
    () async {
      final library = LibraryService()
        ..watchedFolders.add('/library')
        ..library.addAll(<MusicTrack>[
          _track(path: '/library/work/disc/01.mp3', groupKey: '/library/work'),
          _track(path: '/library/work/disc/02.mp3', groupKey: '/library/work'),
        ])
        ..markStructureChanged();
      final service = LibrarySnapshotCacheService(
        libraryService: library,
        detailCacheService: AudioDetailCacheService(
          repository: _FakeAudioDetailRepository(),
        ),
      );

      final snapshot = await service.cardSnapshot(onCommitted: () {});
      final folder = snapshot.tree.single as FolderNode;

      expect(folder.children, isEmpty);
      expect(folder.allTracks, hasLength(2));
      expect(folder.totalTrackCount, 2);
      expect(service.treeSnapshotRevision, -1);
    },
  );
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
  _FakeAudioDetailRepository({
    Map<String, String>? details,
    Map<String, String>? databaseDetails,
    this.failBatchLoad = false,
    this.reconciliationGate,
  }) : _details = details ?? const <String, String>{},
       _databaseDetails =
           databaseDetails ?? details ?? const <String, String>{};

  final Map<String, String> _details;
  final Map<String, String> _databaseDetails;
  final bool failBatchLoad;
  final Completer<void>? reconciliationGate;
  int loadCount = 0;
  int batchLoadCount = 0;
  int databaseSnapshotLoadCount = 0;

  @override
  Future<AudioDetailLoadResult> load(AudioDetailTarget target) async {
    loadCount++;
    final title = _details[AudioLibraryDetailKey.forTarget(target)] ?? '';
    return AudioDetailLoadResult(
      detail: AudioDetail.empty(target).copyWith(workTitle: title),
    );
  }

  @override
  Future<List<AudioDetailLoadResult>> loadMany(
    Iterable<AudioDetailTarget> targets,
  ) async {
    batchLoadCount++;
    await reconciliationGate?.future;
    if (failBatchLoad) {
      throw StateError('batch load failed');
    }
    return Future.wait(targets.map(load));
  }

  @override
  Future<List<AudioDetailLoadResult>> loadDatabaseSnapshotMany(
    Iterable<AudioDetailTarget> targets,
  ) async {
    databaseSnapshotLoadCount++;
    return <AudioDetailLoadResult>[
      for (final target in targets)
        AudioDetailLoadResult(
          detail: AudioDetail.empty(target).copyWith(
            workTitle:
                _databaseDetails[AudioLibraryDetailKey.forTarget(target)] ?? '',
          ),
        ),
    ];
  }

  @override
  Future<AudioDetailSaveResult> save(
    AudioDetail detail, {
    AudioDetailSaveOrigin origin = AudioDetailSaveOrigin.user,
  }) async {
    return AudioDetailSaveResult(
      detail: detail,
      backupAttempted: false,
      backupSaved: false,
    );
  }

  @override
  Future<void> delete(AudioDetailTarget target) async {}

  @override
  Future<void> deleteMany(Iterable<AudioDetailTarget> targets) async {}

  @override
  Future<AudioDetailSaveResult?> prefillRjCodeFromText(
    AudioDetailTarget target,
    String text,
  ) async {
    return null;
  }
}
