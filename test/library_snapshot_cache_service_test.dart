import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/dlsite_metadata.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/persistence/json_document_store.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/audio_detail_cache_service.dart';
import 'package:doujin_audio/features/library/application/audio_detail_repository.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/application/library_organizer.dart';
import 'package:doujin_audio/features/library/application/library_snapshot_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_metadata_coordinator.dart';
import 'package:doujin_audio/features/library/application/dlsite_metadata_service.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'support/test_persistence_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'clear prevents old card and full tree requests from repopulating folder sources',
    () async {
      const root = '/library/work';
      final library = LibraryService()
        ..watchedFolders.add(root)
        ..library.add(_track(path: '$root/old.mp3', groupKey: root))
        ..markStructureChanged();
      final cardBuild = Completer<LibraryTreeSnapshot>();
      final treeBuild = Completer<LibraryTreeSnapshot>();
      final snapshot = const LibraryOrganizer().buildTree(
        tracks: library.library,
        watchedFolders: library.watchedFolders,
      );
      final service = LibrarySnapshotCacheService(
        libraryService: library,
        detailCacheService: AudioDetailCacheService(
          repository: _FakeAudioDetailRepository(),
        ),
        cardSnapshotBuilder: (_) => cardBuild.future,
        treeSnapshotBuilder: (_) => treeBuild.future,
      );
      var commits = 0;
      final cardRequest = service.cardSnapshot(onCommitted: () => commits++);
      final treeRequest = service.treeSnapshot(onCommitted: () => commits++);
      service.clear();
      cardBuild.complete(snapshot);
      treeBuild.complete(snapshot);
      await Future.wait([cardRequest, treeRequest]);

      expect(service.cards, isEmpty);
      expect(service.tree, isEmpty);
      expect(service.cardSnapshotRevision, -1);
      expect(service.treeSnapshotRevision, -1);
      expect(service.resolvedFolderTree(root), isNull);
      expect(commits, 0);
    },
  );

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
    'tree snapshot builder can be injected and propagates failures',
    () async {
      final library = LibraryService()
        ..watchedFolders.add('/library')
        ..library.add(
          _track(path: '/library/work/track.mp3', groupKey: '/library/work'),
        )
        ..markStructureChanged();
      var buildCount = 0;
      final service = LibrarySnapshotCacheService(
        libraryService: library,
        detailCacheService: AudioDetailCacheService(
          repository: _FakeAudioDetailRepository(),
        ),
        treeSnapshotBuilder: (_) async {
          buildCount++;
          throw StateError('tree build failed');
        },
      );

      await expectLater(
        service.treeSnapshot(onCommitted: () {}),
        throwsStateError,
      );
      await expectLater(
        service.treeSnapshot(onCommitted: () {}),
        throwsStateError,
      );
      expect(buildCount, 2);
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
    'batch metadata with covers rebuilds categories and publishes once',
    () async {
      final library = LibraryService();
      for (var index = 0; index < 24; index++) {
        final folder = PathMatcher.normalize('C:/library/$index');
        library.watchedFolders.add(folder);
        library.library.add(
          _track(path: '$folder/track.mp3', groupKey: folder),
        );
      }
      library.markStructureChanged();
      final repository = _FakeAudioDetailRepository();
      final detailCache = AudioDetailCacheService(repository: repository);
      final snapshots = LibrarySnapshotCacheService(
        libraryService: library,
        detailCacheService: detailCache,
      );
      final initial = await snapshots.categorySnapshot(onCommitted: () {});
      final initialRevision = snapshots.categorySnapshotRevision;
      var stateNotifications = 0;
      var coverNotifications = 0;
      final covers = _BatchCoverArtwork();
      final coordinator = LibraryMetadataCoordinator(
        databaseRepository: TestPersistenceRepository(),
        detailCacheService: detailCache,
        metadataService: _BatchMetadataService(),
        asmrMetadataService: null,
        service: library,
        snapshotCacheService: snapshots,
        coverArtwork: () => covers,
        syncState: () => stateNotifications++,
        notifyCoverChanged: () {
          coverNotifications++;
          expect(
            snapshots.categorySnapshotSync?.detailRevision,
            detailCache.revision,
          );
        },
      );
      addTearDown(coordinator.dispose);
      for (var index = 0; index < initial.entries.length; index++) {
        await coordinator.applyMetadata(
          initial.entries[index].detail,
          DlsiteMetadata(
            rjCode: 'RJ123456',
            workTitle: 'Updated $index',
            circleName: index == 0 ? 'Rare circle' : 'Common circle',
            voiceActors: const ['Common voice'],
            tags: index == 0 ? const ['Rare tag'] : const ['Common tag'],
            coverUrl: 'https://example.com/cover.jpg',
          ),
          saveCover: true,
          language: AppLanguage.zh,
          deferCategoryUpdate: true,
        );
      }
      final latest = initial.entries.first.detail.copyWith(
        workTitle: 'Latest edit',
        tags: const ['Common tag'],
      );
      await coordinator.saveAudioDetail(latest, deferCategoryUpdate: true);
      expect(snapshots.categorySnapshotRevision, initialRevision);
      expect(stateNotifications, 0);
      expect(coverNotifications, 0);
      expect(covers.savedCount, 24);

      coordinator.flushMetadataUpdates();
      final updated = await snapshots.categorySnapshot(onCommitted: () {});
      expect(snapshots.categorySnapshotRevision, initialRevision + 1);
      expect(stateNotifications, 1);
      expect(coverNotifications, 1);
      expect(updated.entries.first.detail.workTitle, 'Latest edit');
      expect(updated.entries.last.detail.workTitle, 'Updated 23');
      expect(updated.tagTerms, ['Common tag']);
      expect(updated.voiceActorTerms, ['Common voice']);
      expect(updated.circleTerms, ['Common circle']);
      expect(repository.batchLoadCount, 1);

      await coordinator.setFolderManualCover('C:/library/0', '/covers/new.jpg');
      expect(coverNotifications, 2);
    },
  );

  test(
    'category snapshot reads SQLite details in one batch and commits once',
    () async {
      final target = AudioDetailTarget.libraryRootFolder('/library');
      final repository = _FakeAudioDetailRepository(
        details: {AudioLibraryDetailKey.forTarget(target): 'Database detail'},
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

      final snapshot = await service.categorySnapshot(
        onCommitted: () => commitCount++,
      );

      expect(snapshot.entries.single.detail.workTitle, 'Database detail');
      expect(service.categorySnapshotSync, same(snapshot));
      expect(repository.batchLoadCount, 1);
      expect(repository.loadCount, 1);
      expect(commitCount, 1);

      expect(
        service.categorySnapshotSync?.entries.single.detail.workTitle,
        'Database detail',
      );
      expect(commitCount, 1);
    },
  );

  test(
    'a newer detail revision updates the committed category snapshot',
    () async {
      final target = AudioDetailTarget.libraryRootFolder('/library');
      final repository = _FakeAudioDetailRepository(
        details: {AudioLibraryDetailKey.forTarget(target): 'Database detail'},
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
      final userDetail = AudioDetail.empty(
        target,
      ).copyWith(workTitle: 'New user edit');
      detailCache.markChanged(userDetail);
      service.markDetailChanged(userDetail);

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
        details: {AudioLibraryDetailKey.forTarget(target): 'Database title'},
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
        ),
      );
      final service = LibrarySnapshotCacheService(
        libraryService: library,
        detailCacheService: AudioDetailCacheService(repository: repository),
      )..adoptCardSnapshot(derived.cardSnapshot);

      final snapshot = await service.categorySnapshot(onCommitted: () {});

      expect(snapshot.entries, hasLength(1));
      expect(snapshot.entries.single.target, target);
      expect(snapshot.entries.single.detail.workTitle, 'Database title');
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

    expect(repository.batchLoadCount, 1);
    expect(repository.loadCount, 1);
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
    expect(repository.batchLoadCount, 1);
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

  test('an older in-flight tree cannot overwrite a newer revision', () async {
    final library = LibraryService()
      ..watchedFolders.add('/library')
      ..library.add(_track(path: '/library/old.mp3', groupKey: '/library'))
      ..markStructureChanged();
    final builders = <Completer<LibraryTreeSnapshot>>[];
    final service = LibrarySnapshotCacheService(
      libraryService: library,
      detailCacheService: AudioDetailCacheService(
        repository: _FakeAudioDetailRepository(),
      ),
      treeSnapshotBuilder: (_) {
        final completer = Completer<LibraryTreeSnapshot>();
        builders.add(completer);
        return completer.future;
      },
    );
    var oldCommitted = false;
    var newCommitted = false;

    final oldFuture = service.treeSnapshot(
      onCommitted: () => oldCommitted = true,
    );
    library.library.add(_track(path: '/library/new.mp3', groupKey: '/library'));
    library.markStructureChanged();
    service.markStructureChanged();
    final newFuture = service.treeSnapshot(
      onCommitted: () => newCommitted = true,
    );

    final newSnapshot = const LibraryOrganizer().buildTree(
      tracks: List<MusicTrack>.of(library.library),
      watchedFolders: List<String>.of(library.watchedFolders),
    );
    builders[1].complete(newSnapshot);
    await newFuture;
    final oldSnapshot = const LibraryOrganizer().buildTree(
      tracks: <MusicTrack>[
        _track(path: '/library/old.mp3', groupKey: '/library'),
      ],
      watchedFolders: const <String>['/library'],
    );
    builders[0].complete(oldSnapshot);
    await oldFuture;

    expect(oldCommitted, isFalse);
    expect(newCommitted, isTrue);
    expect(service.treeSnapshotRevision, library.structureRevision);
    expect(
      (service.tree.single as FolderNode).allTracks.map((track) => track.path),
      containsAll(<String>['/library/old.mp3', '/library/new.mp3']),
    );
  });

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

  test('folder tree loads one shallow card and reuses its cache', () async {
    final library = LibraryService()
      ..watchedLibraries.add('/library')
      ..library.addAll([
        _track(
          path: '/library/first/Disc/01.mp3',
          groupKey: '/library/first/Disc',
        ),
        _track(path: '/library/second/02.mp3', groupKey: '/library/second'),
      ])
      ..markStructureChanged();
    final service =
        LibrarySnapshotCacheService(
          libraryService: library,
          detailCacheService: AudioDetailCacheService(
            repository: _FakeAudioDetailRepository(),
          ),
        )..adoptCardSnapshot(
          const LibraryOrganizer().buildCardTree(
            tracks: library.library,
            watchedFolders: library.watchedFolders,
            watchedLibraries: library.watchedLibraries,
          ),
        );

    expect(service.resolvedFolderTree('/library/first'), isNull);
    final folder = (await service.loadFolderTree('/library/first'))!;

    expect(folder.children.single, isA<FolderNode>());
    expect((folder.children.single as FolderNode).name, 'Disc');
    expect(folder.allTracks.map((track) => track.path), [
      '/library/first/Disc/01.mp3',
    ]);
    expect(service.resolvedFolderTree('/library/first'), same(folder));
    expect(await service.loadFolderTree('/library/first'), same(folder));
    expect(
      service.cards.whereType<FolderNode>().every(
        (card) => card.children.isEmpty,
      ),
      isTrue,
    );
    expect(service.tree, isEmpty);
    expect(service.treeSnapshotRevision, -1);

    service.clear();
    expect(service.resolvedFolderTree('/library/first'), isNull);
    final rebuilt = await service.loadFolderTree('/library/first');
    expect(rebuilt, isNot(same(folder)));
    expect(rebuilt?.allTracks.single.path, '/library/first/Disc/01.mp3');
  });

  test(
    'cold folder reads never build and equivalent requests share a build',
    () async {
      const root = r'E:\作品 空格\Work';
      final library = LibraryService()
        ..library.addAll([
          _track(path: '$root\\Disc\\01.mp3', groupKey: '$root\\Disc'),
          _track(path: r'E:\Other\02.mp3', groupKey: r'E:\Other'),
        ])
        ..markStructureChanged();
      final build = Completer<LibraryTreeSnapshot>();
      LibraryDerivedSnapshotPayload? requested;
      var buildCount = 0;
      final service = LibrarySnapshotCacheService(
        libraryService: library,
        detailCacheService: AudioDetailCacheService(
          repository: _FakeAudioDetailRepository(),
        ),
        treeSnapshotBuilder: (payload) {
          buildCount++;
          requested = payload;
          return build.future;
        },
      );

      expect(service.resolvedFolderTree(root), isNull);
      expect(service.resolvedFolderTree('e:/作品 空格/work/'), isNull);
      expect(buildCount, 0);
      final first = service.loadFolderTree(root);
      final second = service.loadFolderTree('e:/作品 空格/work/');
      expect(second, same(first));
      expect(buildCount, 0);
      await Future<void>.delayed(Duration.zero);
      expect(buildCount, 1);
      expect(requested!.tracks.map((track) => track.path), [
        '$root\\Disc\\01.mp3',
      ]);
      expect(requested!.watchedFolders, [root]);
      expect(requested!.watchedLibraries, isEmpty);
      build.complete(
        const LibraryOrganizer().buildTree(
          tracks: requested!.tracks,
          watchedFolders: requested!.watchedFolders,
        ),
      );
      final folder = await first;
      expect(await second, same(folder));
      expect(service.resolvedFolderTree('e:/作品 空格/work/'), same(folder));
      expect(await service.loadFolderTree(root), same(folder));
      expect(buildCount, 1);
      expect(service.tree, isEmpty);
    },
  );

  for (final clear in [false, true]) {
    for (final oldCompletesFirst in [false, true]) {
      test(
        'folder ${clear ? "clear" : "revision change"} joins the current request when old completes ${oldCompletesFirst ? "first" : "last"}',
        () async {
          const root = '/library/work';
          final library = LibraryService()
            ..library.add(_track(path: '$root/old.mp3', groupKey: root))
            ..markStructureChanged();
          final builds = <Completer<LibraryTreeSnapshot>>[];
          final snapshots = <LibraryTreeSnapshot>[];
          final service = LibrarySnapshotCacheService(
            libraryService: library,
            detailCacheService: AudioDetailCacheService(
              repository: _FakeAudioDetailRepository(),
            ),
            treeSnapshotBuilder: (payload) {
              snapshots.add(
                const LibraryOrganizer().buildTree(
                  tracks: payload.tracks,
                  watchedFolders: payload.watchedFolders,
                ),
              );
              final build = Completer<LibraryTreeSnapshot>();
              builds.add(build);
              return build.future;
            },
          );
          final oldRequest = service.loadFolderTree(root);
          await Future<void>.delayed(Duration.zero);
          library.library
            ..clear()
            ..add(_track(path: '$root/new.mp3', groupKey: root));
          if (clear) {
            service.clear();
          } else {
            library.markStructureChanged();
          }
          expect(service.resolvedFolderTree(root), isNull);
          final currentRequest = service.loadFolderTree(root);
          await Future<void>.delayed(Duration.zero);
          expect(builds, hasLength(2));
          if (oldCompletesFirst) {
            builds[0].complete(snapshots[0]);
            await Future<void>.delayed(Duration.zero);
            expect(service.resolvedFolderTree(root), isNull);
          }
          builds[1].complete(snapshots[1]);
          final current = await currentRequest;
          if (!oldCompletesFirst) builds[0].complete(snapshots[0]);
          expect(await oldRequest, same(current));
          expect(current!.allTracks.single.path, '$root/new.mp3');
          expect(service.resolvedFolderTree(root), same(current));
          expect(builds, hasLength(2));
        },
      );
    }
  }

  test(
    'folder requests follow multiple revision and clear changes without waiting cycles',
    () async {
      const root = '/library/work';
      final library = LibraryService()
        ..library.add(_track(path: '$root/0.mp3', groupKey: root))
        ..markStructureChanged();
      final builds = <Completer<LibraryTreeSnapshot>>[];
      final snapshots = <LibraryTreeSnapshot>[];
      final service = LibrarySnapshotCacheService(
        libraryService: library,
        detailCacheService: AudioDetailCacheService(
          repository: _FakeAudioDetailRepository(),
        ),
        treeSnapshotBuilder: (payload) {
          snapshots.add(
            const LibraryOrganizer().buildTree(
              tracks: payload.tracks,
              watchedFolders: payload.watchedFolders,
            ),
          );
          final build = Completer<LibraryTreeSnapshot>();
          builds.add(build);
          return build.future;
        },
      );
      final requests = [service.loadFolderTree(root)];
      await Future<void>.delayed(Duration.zero);
      for (var generation = 1; generation <= 3; generation++) {
        library.library
          ..clear()
          ..add(_track(path: '$root/$generation.mp3', groupKey: root));
        if (generation != 2) library.markStructureChanged();
        if (generation != 1) service.clear();
        requests.add(service.loadFolderTree(root));
        await Future<void>.delayed(Duration.zero);
        builds[generation - 1].complete(snapshots[generation - 1]);
        await Future<void>.delayed(Duration.zero);
        expect(service.resolvedFolderTree(root), isNull);
        expect(builds, hasLength(generation + 1));
      }
      builds.last.complete(snapshots.last);
      final folders = await Future.wait(
        requests,
      ).timeout(const Duration(seconds: 2));
      expect(
        folders.every((folder) => identical(folder, folders.last)),
        isTrue,
      );
      expect(folders.last!.allTracks.single.path, '$root/3.mp3');
      expect(service.resolvedFolderTree(root), same(folders.last));
      expect(builds, hasLength(4));
    },
  );

  test(
    'invalidated folder request rebuilds without another caller and retries failures',
    () async {
      const root = '/library/work';
      final library = LibraryService()
        ..library.add(_track(path: '$root/old.mp3', groupKey: root))
        ..markStructureChanged();
      final oldBuild = Completer<LibraryTreeSnapshot>();
      var buildCount = 0;
      final service = LibrarySnapshotCacheService(
        libraryService: library,
        detailCacheService: AudioDetailCacheService(
          repository: _FakeAudioDetailRepository(),
        ),
        treeSnapshotBuilder: (payload) async {
          buildCount++;
          if (buildCount == 1) return oldBuild.future;
          if (buildCount == 2) throw StateError('build failed');
          return const LibraryOrganizer().buildTree(
            tracks: payload.tracks,
            watchedFolders: payload.watchedFolders,
          );
        },
      );
      final request = service.loadFolderTree(root);
      await Future<void>.delayed(Duration.zero);
      service.clear();
      final failed = expectLater(request, throwsStateError);
      oldBuild.complete(
        const LibraryOrganizer().buildTree(
          tracks: library.library,
          watchedFolders: [root],
        ),
      );
      await failed;
      expect(service.resolvedFolderTree(root), isNull);
      expect(
        (await service.loadFolderTree(root))!.allTracks.single.path,
        '$root/old.mp3',
      );
      expect(buildCount, 3);
    },
  );

  test(
    'folder tree ignores an older full tree after replacement and removal',
    () async {
      const root = '/library/work';
      final library = LibraryService()
        ..watchedFolders.add(root)
        ..library.add(_track(path: '$root/old.mp3', groupKey: root))
        ..markStructureChanged();
      final service = LibrarySnapshotCacheService(
        libraryService: library,
        detailCacheService: AudioDetailCacheService(
          repository: _FakeAudioDetailRepository(),
        ),
        treeSnapshotBuilder: (payload) async =>
            const LibraryOrganizer().buildTree(
              tracks: payload.tracks,
              watchedFolders: payload.watchedFolders,
            ),
      );
      final fullSnapshot = await service.treeSnapshot(onCommitted: () {});
      final oldFolder = fullSnapshot.tree.single as FolderNode;
      expect(service.resolvedFolderTree(root), same(oldFolder));

      library.library
        ..clear()
        ..add(_track(path: '$root/new.mp3', groupKey: root));
      library.markStructureChanged();
      expect(service.resolvedFolderTree(root), isNull);
      final updated = (await service.loadFolderTree(root))!;
      expect(updated, isNot(same(oldFolder)));
      expect(updated.allTracks.single.path, '$root/new.mp3');
      expect(service.resolvedFolderTree(root), same(updated));

      library.library.clear();
      library.markStructureChanged();
      expect(service.resolvedFolderTree(root), isNull);
      expect(await service.loadFolderTree(root), isNull);
    },
  );

  test(
    'folder tree resolves equivalent Windows paths from the same cache',
    () async {
      const root = r'E:\作品 空格\Work';
      final library = LibraryService()
        ..watchedFolders.add(root)
        ..library.add(
          _track(path: '$root\\Disc\\01.mp3', groupKey: '$root\\Disc'),
        )
        ..markStructureChanged();
      final service = LibrarySnapshotCacheService(
        libraryService: library,
        detailCacheService: AudioDetailCacheService(
          repository: _FakeAudioDetailRepository(),
        ),
      );

      expect(service.resolvedFolderTree(root), isNull);
      final folder = (await service.loadFolderTree(root))!;

      expect((folder.children.single as FolderNode).name, 'Disc');
      expect(service.resolvedFolderTree('e:/作品 空格/work/'), same(folder));
      expect(folder.allTracks.single.path, '$root\\Disc\\01.mp3');
    },
  );

  test(
    'folder tree keeps SAF synthetic child paths under an existing work root',
    () async {
      const libraryRoot =
          'content://com.android.externalstorage.documents/tree/primary%3ALibrary';
      const workRoot = '$libraryRoot::作品';
      const documentWorkRoot =
          '$libraryRoot/document/primary%3ALibrary%2F%E4%BD%9C%E5%93%81';
      final library = LibraryService()
        ..watchedLibraries.add(libraryRoot)
        ..library.addAll([
          _track(
            path: '$libraryRoot/document/opaque-id-1',
            groupKey: '$workRoot/Disc',
          ),
          _track(
            path: '$libraryRoot/document/opaque-id-2',
            groupKey: '$libraryRoot::Other',
          ),
        ])
        ..markStructureChanged();
      final service = LibrarySnapshotCacheService(
        libraryService: library,
        detailCacheService: AudioDetailCacheService(
          repository: _FakeAudioDetailRepository(),
        ),
      );

      expect(service.resolvedFolderTree(workRoot), isNull);
      final request = service.loadFolderTree(workRoot);
      expect(service.loadFolderTree(documentWorkRoot), same(request));
      final folder = (await request)!;
      final disc = folder.children.single as FolderNode;

      expect(disc.name, 'Disc');
      expect(disc.path, '$workRoot/Disc');
      expect(folder.allTracks.single.path, '$libraryRoot/document/opaque-id-1');
      expect(service.resolvedFolderTree(documentWorkRoot), same(folder));
      expect(service.treeSnapshotRevision, -1);
    },
  );

  test('card snapshot propagates one failure and can retry', () async {
    final library = LibraryService()
      ..watchedFolders.add('/library')
      ..markStructureChanged();
    var buildCount = 0;
    var commitCount = 0;
    final service = LibrarySnapshotCacheService(
      libraryService: library,
      detailCacheService: AudioDetailCacheService(
        repository: _FakeAudioDetailRepository(),
      ),
      cardSnapshotBuilder: (_) async {
        buildCount++;
        if (buildCount == 1) throw StateError('card build failed');
        return LibraryTreeSnapshot(
          tree: const <LibraryNode>[],
          leafFolderCount: 0,
        );
      },
    );

    await expectLater(
      service.cardSnapshot(onCommitted: () => commitCount++),
      throwsStateError,
    );
    expect(commitCount, 0);

    await service.cardSnapshot(onCommitted: () => commitCount++);

    expect(buildCount, 2);
    expect(commitCount, 1);
  });
}

class _BatchCoverArtwork implements CoverArtworkCacheService {
  int savedCount = 0;

  @override
  Future<String?> setFolderCoverSelection(
    String folderPath,
    String coverPath, {
    bool newlySaved = false,
    String? sourcePath,
  }) async {
    savedCount++;
    return coverPath;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BatchMetadataService implements DlsiteMetadataService {
  @override
  Future<CoverImageReference> downloadCover({
    required String coverUrl,
    required String folderPath,
    required String rjCode,
    String? fileName,
    AppLanguage language = AppLanguage.ja,
  }) async => const CoverImageReference(
    displayPath: '/covers/cover.jpg',
    sourcePath: '/covers/cover.jpg',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  @override
  Future<bool> exportTimeSegments(AudioDetailTarget target) async => true;

  _FakeAudioDetailRepository({
    Map<String, String>? details,
    this.failBatchLoad = false,
  }) : _details = details ?? const <String, String>{};

  final Map<String, String> _details;
  final bool failBatchLoad;
  int loadCount = 0;
  int batchLoadCount = 0;

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
    if (failBatchLoad) {
      throw StateError('batch load failed');
    }
    final values = targets.toList(growable: false);
    loadCount += values.length;
    return <AudioDetailLoadResult>[
      for (final target in values)
        AudioDetailLoadResult(
          detail: AudioDetail.empty(target).copyWith(
            workTitle: _details[AudioLibraryDetailKey.forTarget(target)] ?? '',
          ),
        ),
    ];
  }

  @override
  Future<AudioDetailBackupImportResult> importBackupsMany(
    Iterable<AudioDetailTarget> targets,
  ) async {
    return const AudioDetailBackupImportResult();
  }

  @override
  Future<AudioDetailSaveResult> save(AudioDetail detail) async {
    return AudioDetailSaveResult(
      detail: detail,
      documentStatus: JsonDocumentWriteStatus.preserved,
    );
  }

  @override
  Future<AudioDetailSaveResult> retarget(
    AudioDetailTarget previousTarget,
    AudioDetail detail,
  ) => save(detail);

  @override
  Future<AudioDetailSaveResult> saveMissingDuration(
    AudioDetailTarget target,
    Duration duration,
  ) async {
    return AudioDetailSaveResult(
      detail: AudioDetail.empty(target).copyWith(duration: duration),
      documentStatus: JsonDocumentWriteStatus.preserved,
    );
  }

  @override
  Future<AudioDetail> updateDerivedFields(
    AudioDetailTarget target, {
    String? rjCode,
    Duration? duration,
    String? cardCoverPath,
    bool? cardCoverSelected,
  }) async => AudioDetail.empty(target).copyWith(
    rjCode: rjCode,
    duration: duration,
    cardCoverPath: cardCoverPath,
    cardCoverSelected: cardCoverSelected,
  );

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
