import 'dart:async';
import 'dart:io';

import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/cache/app_cache_service.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_source_resolver.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_store.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'SAF tracks share only their own complete folder scope until invalidated',
    () async {
      const firstScope = 'content://library/tree/root::work-a';
      const otherScope = 'content://library/tree/root::work-b';
      final scans = <String>[];
      final gateway = _ImageGateway((root, recursive) async {
        expect(recursive, isTrue);
        scans.add(root);
        return ['/cache/${root == firstScope ? 'a' : 'b'}.jpg'];
      });
      final library = LibraryService();
      addTearDown(library.dispose);
      final resolver = CoverArtworkSourceResolver(
        libraryService: library,
        fileCacheGateway: gateway,
        artworkStore: CoverArtworkStore(),
        isClearingPersistentCache: () => false,
      );
      MusicTrack track(String path, String scope) => MusicTrack(
        path: path,
        displayName: 'voice',
        groupKey: scope,
        groupTitle: 'work',
        groupSubtitle: '',
        isSingle: false,
      );
      expect(
        await Future.wait([
          resolver.resolvePlatformCoverPathForTrack(
            track('content://media/one', firstScope),
          ),
          resolver.resolvePlatformCoverPathForTrack(
            track('content://media/two', firstScope),
          ),
        ]),
        ['/cache/a.jpg', '/cache/a.jpg'],
      );
      expect(
        await resolver.resolvePlatformCoverPathForTrack(
          track('content://media/three', firstScope),
        ),
        '/cache/a.jpg',
      );
      expect(
        await resolver.resolvePlatformCoverPathForTrack(
          track('content://media/four', otherScope),
        ),
        '/cache/b.jpg',
      );
      expect(scans, [firstScope, otherScope]);
      expect(gateway.coverRequests, 0);
      resolver.invalidateFolderImageIndexes(firstScope);
      await resolver.resolvePlatformCoverPathForTrack(
        track('content://media/five', firstScope),
      );
      expect(scans, [firstScope, otherScope, firstScope]);
    },
  );

  test(
    'SAF empty folders are shared before each track embedded probe',
    () async {
      const scope = 'content://library/tree/root::work';
      var scans = 0;
      final gateway = _ImageGateway((_, _) async {
        scans++;
        return [];
      })..coverResult = Future.value('/cache/embedded.jpg');
      final library = LibraryService();
      addTearDown(library.dispose);
      final resolver = CoverArtworkSourceResolver(
        libraryService: library,
        fileCacheGateway: gateway,
        artworkStore: CoverArtworkStore(),
        isClearingPersistentCache: () => false,
      );
      for (final path in ['content://media/one', 'content://media/two']) {
        await resolver.resolvePlatformCoverPathForTrack(
          MusicTrack(
            path: path,
            displayName: 'voice',
            groupKey: scope,
            groupTitle: 'work',
            groupSubtitle: '',
            isSingle: false,
          ),
        );
      }
      expect(scans, 1);
      expect(gateway.coverScopes, [(null, null), (null, null)]);
    },
  );

  test(
    'SAF first cover limits copies while the chooser retains every candidate',
    () async {
      const scope = 'content://library/tree/root::work';
      final gateway = _ImageGateway((_, _) async => [])
        ..referenceOverride = [
          for (var index = 0; index < 100; index++)
            CoverImageReference(
              displayPath: '/cache/$index.jpg',
              sourcePath: '$scope/$index.jpg',
            ),
        ];
      final library = LibraryService();
      addTearDown(library.dispose);
      final resolver = CoverArtworkSourceResolver(
        libraryService: library,
        fileCacheGateway: gateway,
        artworkStore: CoverArtworkStore(),
        isClearingPersistentCache: () => false,
      );
      expect(await resolver.resolvePreferredFolderCover(scope), '/cache/0.jpg');
      expect(gateway.imageCopies, 1);
      expect(await resolver.resolvePreferredFolderCover(scope), '/cache/0.jpg');
      expect(gateway.imageCopies, 1);
      expect(
        await resolver.discoverFolderImages(scope, recursive: false),
        hasLength(100),
      );
      expect(gateway.imageCopies, 101);
      gateway.referenceOverride = const [
        CoverImageReference(
          displayPath: '/cache/new.jpg',
          sourcePath: '$scope/new.jpg',
        ),
      ];
      await resolver.discoverFolderImageReferences(
        scope,
        recursive: false,
        refresh: true,
      );
      expect(
        await resolver.resolvePreferredFolderCover(scope),
        '/cache/new.jpg',
      );
    },
  );

  test('completed work refresh indexes have bounded retention', () async {
    final library = LibraryService()..addWatchedLibrary('/works');
    addTearDown(library.dispose);
    final scans = <String>[];
    final resolver = CoverArtworkSourceResolver(
      libraryService: library,
      fileCacheGateway: FileCachePlatformGateway(),
      artworkStore: CoverArtworkStore(),
      isClearingPersistentCache: () => false,
      filesystemImageScanner: (root, _) async {
        scans.add(root);
        return ['$root/cover.jpg'];
      },
    );
    await resolver.discoverFolderImages('/works');
    for (var i = 0; i < 40; i++) {
      await resolver.discoverFolderImageReferences('/works/$i', refresh: true);
    }
    expect(resolver.folderImageIndexCount, lessThanOrEqualTo(33));
    final images = await resolver.discoverFolderImages('/works');
    expect(images, hasLength(41));
    await resolver.discoverFolderImages('/works/0');
    expect(scans, hasLength(41));
  });

  test('a failed pending root scan observes its refresh patches', () async {
    final library = LibraryService()..addWatchedLibrary('/works');
    addTearDown(library.dispose);
    final initial = Completer<List<String>>();
    var rootScans = 0;
    final resolver = CoverArtworkSourceResolver(
      libraryService: library,
      fileCacheGateway: FileCachePlatformGateway(),
      artworkStore: CoverArtworkStore(),
      isClearingPersistentCache: () => false,
      filesystemImageScanner: (root, _) =>
          root.replaceAll('\\', '/') == '/works' && ++rootScans == 1
          ? initial.future
          : Future.value(['/works/a/fresh.jpg']),
    );
    final root = resolver.discoverFolderImages('/works');
    await resolver.discoverFolderImageReferences('/works/a', refresh: true);
    initial.completeError(const FileSystemException('Permission denied'));
    expect(await root, isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(await resolver.discoverFolderImages('/works'), [
      '/works/a/fresh.jpg',
    ]);
  });

  test('index trimming waits for pending root merges', () async {
    final library = LibraryService()..addWatchedLibrary('/works');
    addTearDown(library.dispose);
    final initial = Completer<List<String>>();
    final resolver = CoverArtworkSourceResolver(
      libraryService: library,
      fileCacheGateway: FileCachePlatformGateway(),
      artworkStore: CoverArtworkStore(),
      isClearingPersistentCache: () => false,
      filesystemImageScanner: (root, _) =>
          root.replaceAll('\\', '/') == '/works'
          ? initial.future
          : Future.value(['$root/new.jpg']),
    );
    final root = resolver.discoverFolderImages('/works');
    await Future.wait([
      for (var i = 0; i < 40; i++)
        resolver.discoverFolderImageReferences('/works/$i', refresh: true),
    ]);
    initial.complete(['/works/kept.jpg']);
    final images = await root;
    expect(images, hasLength(41));
    for (var i = 0; i < 40; i++) {
      expect(
        images.any(
          (image) => PathMatcher.equalsNormalized(image, '/works/$i/new.jpg'),
        ),
        isTrue,
      );
    }
    expect(resolver.folderImageIndexCount, lessThanOrEqualTo(33));
  });

  test(
    'work refresh scans only its subtree and patches warm root images',
    () async {
      final library = LibraryService()..addWatchedLibrary('/works');
      addTearDown(library.dispose);
      final scans = <String>[];
      final files = <String, List<String>>{
        '/works': ['/works/a/old.jpg', '/works/b/old.jpg'],
        '/works/a': ['/works/a/new.jpg'],
        '/works/b': ['/works/b/new.jpg'],
      };
      final resolver = CoverArtworkSourceResolver(
        libraryService: library,
        fileCacheGateway: FileCachePlatformGateway(),
        artworkStore: CoverArtworkStore(),
        isClearingPersistentCache: () => false,
        filesystemImageScanner: (root, recursive) async {
          expect(recursive, isTrue);
          final canonical = root.replaceAll('\\', '/');
          scans.add(canonical);
          return files[canonical]!;
        },
      );
      await resolver.discoverFolderImages('/works');
      Future<List<String>> refresh(String folder) async =>
          (await resolver.discoverFolderImageReferences(
            folder,
            refresh: true,
            propagateFailure: true,
          )).map((image) => image.sourcePath).toList();
      expect(await refresh('/works/a'), ['/works/a/new.jpg']);
      expect(await refresh('/works/b'), ['/works/b/new.jpg']);
      files['/works/a'] = ['/works/a/latest.jpg'];
      expect(await refresh('/works/a'), ['/works/a/latest.jpg']);
      expect(await resolver.discoverFolderImages('/works'), [
        '/works/a/latest.jpg',
        '/works/b/new.jpg',
      ]);
      expect(scans, ['/works', '/works/a', '/works/b', '/works/a']);
    },
  );

  test(
    'concurrent work refreshes merge and the same work shares its scan',
    () async {
      final library = LibraryService()..addWatchedLibrary('/works');
      addTearDown(library.dispose);
      final initial = Completer<List<String>>();
      final first = Completer<List<String>>();
      final second = Completer<List<String>>();
      final scans = <String>[];
      final resolver = CoverArtworkSourceResolver(
        libraryService: library,
        fileCacheGateway: FileCachePlatformGateway(),
        artworkStore: CoverArtworkStore(),
        isClearingPersistentCache: () => false,
        filesystemImageScanner: (root, _) {
          final canonical = root.replaceAll('\\', '/');
          scans.add(canonical);
          return switch (canonical) {
            '/works' => initial.future,
            '/works/a' => first.future,
            _ => second.future,
          };
        },
      );
      final root = resolver.discoverFolderImages('/works');
      final a = resolver.discoverFolderImageReferences(
        '/works/a',
        refresh: true,
      );
      final same = resolver.discoverFolderImageReferences(
        '/works/a',
        refresh: true,
      );
      final b = resolver.discoverFolderImageReferences(
        '/works/b',
        refresh: true,
      );
      second.complete(['/works/b/new.jpg']);
      first.complete(['/works/a/new.jpg']);
      initial.complete([
        '/works/a/old.jpg',
        '/works/b/old.jpg',
        '/works/c/keep.jpg',
      ]);
      await Future.wait([a, same, b]);
      expect(await root, [
        '/works/a/new.jpg',
        '/works/b/new.jpg',
        '/works/c/keep.jpg',
      ]);
      expect(await resolver.discoverFolderImages('/works'), await root);
      expect(scans, ['/works', '/works/a', '/works/b']);
    },
  );

  for (final clearAll in [false, true]) {
    test(
      'retired work refresh cannot refill indexes, clearAll=$clearAll',
      () async {
        final library = LibraryService()..addWatchedLibrary('/works');
        addTearDown(library.dispose);
        final pending = Completer<List<String>>();
        final resolver = CoverArtworkSourceResolver(
          libraryService: library,
          fileCacheGateway: FileCachePlatformGateway(),
          artworkStore: CoverArtworkStore(),
          isClearingPersistentCache: () => false,
          filesystemImageScanner: (root, _) =>
              root.replaceAll('\\', '/') == '/works/a'
              ? pending.future
              : Future.value(['/works/b/kept.jpg']),
        );
        await resolver.discoverFolderImages('/works');
        final old = resolver.discoverFolderImageReferences(
          '/works/a',
          refresh: true,
          propagateFailure: true,
        );
        final failure = expectLater(old, throwsStateError);
        if (clearAll) {
          resolver.invalidateAll();
        } else {
          resolver.invalidateFolderImageIndexes('/works/a');
        }
        pending.complete(['/works/a/retired.jpg']);
        await failure;
        expect(resolver.sourcePathForDisplay('/works/a/retired.jpg'), isNull);
        expect(await resolver.discoverFolderImages('/works'), [
          '/works/b/kept.jpg',
        ]);
      },
    );
  }

  test(
    'SAF refresh keeps the native directory scope and discovers new images',
    () async {
      final library = LibraryService()..addWatchedLibrary('content://library');
      addTearDown(library.dispose);
      final paths = <String>[];
      final gateway = _ImageGateway((root, _) async {
        paths.add(root);
        return ['/cache/${paths.length}.jpg'];
      });
      final resolver = CoverArtworkSourceResolver(
        libraryService: library,
        fileCacheGateway: gateway,
        artworkStore: CoverArtworkStore(),
        isClearingPersistentCache: () => false,
      );
      const work = 'content://library/work';
      expect(await resolver.discoverFolderImages(work), ['/cache/1.jpg']);
      final fresh = await resolver.discoverFolderImageReferences(
        work,
        refresh: true,
      );
      expect(fresh.single.displayPath, '/cache/2.jpg');
      expect(await resolver.discoverFolderImages(work), ['/cache/2.jpg']);
      expect(paths, [work, work]);
    },
  );

  test(
    'shared artwork keeps bounded source aliases through moves and trimming',
    () {
      final library = LibraryService();
      addTearDown(library.dispose);
      final resolver = CoverArtworkSourceResolver(
        libraryService: library,
        fileCacheGateway: FileCachePlatformGateway(),
        artworkStore: CoverArtworkStore(),
        isClearingPersistentCache: () => false,
      );
      const shared = '/cache/shared.image';
      for (var index = 0; index <= 500; index++) {
        resolver.rememberFolderImageSource(shared, 'content://library/$index');
      }
      expect(resolver.displayPathForSource('content://library/0'), isNull);
      for (var index = 1; index <= 500; index++) {
        expect(
          resolver.displayPathForSource('content://library/$index'),
          shared,
        );
      }
      expect(resolver.sourcePathForDisplay(shared), 'content://library/500');

      resolver.rememberFolderImageSource(
        '/cache/moved.image',
        'content://library/500',
      );
      expect(resolver.sourcePathForDisplay(shared), 'content://library/499');
      expect(
        resolver.sourcePathForDisplay('/cache/moved.image'),
        'content://library/500',
      );
      resolver.rememberFolderImageSource(
        '/cache/new.image',
        'content://library/new',
      );
      expect(resolver.displayPathForSource('content://library/1'), isNull);
      expect(resolver.displayPathForSource('content://library/2'), shared);

      resolver.trimMemory();
      expect(resolver.sourcePathForDisplay(shared), isNull);
      expect(resolver.sourcePathForDisplay('/cache/moved.image'), isNull);
      expect(resolver.displayPathForSource('content://library/2'), isNull);
      expect(resolver.displayPathForSource('content://library/500'), isNull);
    },
  );

  for (final kind in ['embedded', 'video', 'directory']) {
    test(
      '$kind generation keeps temporary artwork until durable copy completes',
      () async {
        final workspace = await Directory.systemTemp.createTemp(
          'artwork_lease_',
        );
        final temporary = Directory('${workspace.path}/temp');
        final support = Directory('${workspace.path}/support');
        final source = File('${temporary.path}/doujin_audio_covers/image.jpg');
        final partial = File('${source.path}.part');
        final entered = Completer<void>();
        final resume = Completer<void>();
        AppCacheService.resetForTest(
          temporaryDirectories: () async => [temporary],
        );
        addTearDown(() async {
          if (!resume.isCompleted) resume.complete();
          await AppCacheService.enforceLimit();
          AppCacheService.resetForTest();
          await workspace.delete(recursive: true);
        });
        Future<String?> generate() async {
          await source.parent.create(recursive: true);
          await partial.writeAsBytes([0xff, 0xd8, 0xff, 0xd9]);
          entered.complete();
          await resume.future;
          await partial.rename(source.path);
          return source.path;
        }

        final gateway = _GeneratingImageGateway(generate);
        final library = LibraryService();
        addTearDown(library.dispose);
        final store = CoverArtworkStore(
          persistentDirectory: () async => support,
        );
        await store.initialize();
        final resolver = CoverArtworkSourceResolver(
          libraryService: library,
          fileCacheGateway: gateway,
          artworkStore: store,
          isClearingPersistentCache: () => false,
        );
        final track = MusicTrack(
          path: '${workspace.path}/voice.mp3',
          displayName: 'voice',
          groupKey: '',
          groupTitle: '',
          groupSubtitle: '',
          isSingle: true,
        );
        final resolution = kind == 'directory'
            ? resolver
                  .discoverFolderImageReferences('content://library/work')
                  .then((images) => images.single.displayPath)
            : kind == 'video'
            ? resolver.resolveVideoFramePathForTrack(track)
            : resolver.resolveEmbeddedCoverForPath(track.path);
        await entered.future;
        await AppCacheService.setMaxCacheBytes(1);
        await AppCacheService.clearTemporaryCaches();
        expect(await partial.exists(), isTrue);
        resume.complete();
        final durable = await resolution;
        expect(durable, isNotNull);
        expect(PathMatcher.equalsNormalized(durable!, source.path), isFalse);
        await AppCacheService.enforceLimit();
        expect(await source.exists(), isFalse);
        expect(await File(durable).readAsBytes(), [0xff, 0xd8, 0xff, 0xd9]);
      },
    );
  }

  test('scoped invalidation retires only affected image discoveries', () async {
    final affected = Completer<List<String>>();
    final unrelated = Completer<List<String>>();
    final resolver = CoverArtworkSourceResolver(
      libraryService: LibraryService(),
      fileCacheGateway: FileCachePlatformGateway(),
      artworkStore: CoverArtworkStore(),
      isClearingPersistentCache: () => false,
      filesystemImageScanner: (root, _) =>
          root == '/work/a' ? affected.future : unrelated.future,
    );
    final first = resolver.discoverFolderImageReferences(
      '/work/a',
      propagateFailure: true,
    );
    final firstFailure = expectLater(first, throwsStateError);
    final other = resolver.discoverFolderImageReferences(
      '/work/b',
      propagateFailure: true,
    );
    resolver.invalidateFolderImageIndexes('/work/a');
    affected.complete(['/work/a/retired.jpg']);
    unrelated.complete(['/work/b/kept.jpg']);
    await firstFailure;
    expect((await other).single.sourcePath, '/work/b/kept.jpg');
    expect(resolver.sourcePathForDisplay('/work/a/retired.jpg'), isNull);
    expect(
      resolver.sourcePathForDisplay('/work/b/kept.jpg'),
      '/work/b/kept.jpg',
    );
  });

  test(
    'standalone detail and card extraction share a request and restart artifact',
    () async {
      final support = await Directory.systemTemp.createTemp(
        'shared_source_cover_',
      );
      addTearDown(() => support.delete(recursive: true));
      final source = File('${support.path}/bridge.jpg');
      await source.writeAsBytes([0xff, 0xd8, 0xff, 0xd9]);
      final pending = Completer<String?>();
      final track = MusicTrack(
        path: '${support.path}/voice.flac',
        displayName: 'voice',
        groupKey: '',
        groupTitle: '',
        groupSubtitle: '',
        isSingle: true,
      );
      final library = LibraryService()
        ..addOrReplaceTracks([track], persist: false);
      addTearDown(library.dispose);
      final gateway = _ImageGateway((_, _) async => []);
      gateway.coverResult = pending.future;
      final store = CoverArtworkStore(persistentDirectory: () async => support);
      await store.initialize();
      CoverArtworkSourceResolver create(CoverArtworkStore artwork) =>
          CoverArtworkSourceResolver(
            libraryService: library,
            fileCacheGateway: gateway,
            artworkStore: artwork,
            isClearingPersistentCache: () => false,
          );
      final resolver = create(store);
      final card = resolver.resolvePlatformCoverPathForTrack(track);
      final detail = resolver.resolveEmbeddedCoverForPath(track.path);
      pending.complete(source.path);
      final results = await Future.wait([card, detail]);
      expect(results[0], results[1]);
      expect(gateway.coverRequests, 1);
      await source.delete();
      final restartedStore = CoverArtworkStore(
        persistentDirectory: () async => support,
      );
      await restartedStore.initialize();
      expect(
        await create(restartedStore).resolveEmbeddedCoverForPath(track.path),
        results.first,
      );
      expect(gateway.coverRequests, 1);
    },
  );

  test(
    'SAF image references preserve names and durable bytes for large folders',
    () async {
      final support = await Directory.systemTemp.createTemp(
        'durable_saf_images_',
      );
      addTearDown(() => support.delete(recursive: true));
      final nativeImage = File(
        '${support.path}${Platform.pathSeparator}temporary.jpg',
      );
      await nativeImage.writeAsBytes([0xff, 0xd8, 0xff, 0xd9]);
      const root = 'content://library/work';
      final gateway = _ImageGateway((_, _) async => []);
      gateway.referenceOverride = [
        for (var index = 0; index < 501; index++)
          CoverImageReference(
            displayPath: nativeImage.path,
            sourcePath: '$root/original-$index.jpg',
          ),
      ];
      final store = CoverArtworkStore(persistentDirectory: () async => support);
      await store.initialize();
      final resolver = CoverArtworkSourceResolver(
        libraryService: LibraryService(),
        fileCacheGateway: gateway,
        artworkStore: store,
        isClearingPersistentCache: () => false,
      );
      final images = await resolver.discoverFolderImageReferences(
        root,
        propagateFailure: true,
      );
      expect(images, hasLength(501));
      expect(images.first.sourcePath, '$root/original-0.jpg');
      expect(images.last.sourcePath, '$root/original-500.jpg');
      expect(images.first.displayPath, isNot(nativeImage.path));
      await nativeImage.delete();
      final restored = CoverArtworkStore(
        persistentDirectory: () async => support,
      );
      await restored.initialize();
      expect(
        await restored.validatedPath(
          'source-image:${PathMatcher.equivalenceKey('$root/original-0.jpg')}',
        ),
        images.first.displayPath,
      );
      expect(await File(images.first.displayPath).readAsBytes(), [
        0xff,
        0xd8,
        0xff,
        0xd9,
      ]);
    },
  );

  test(
    'strict image discovery reports failure and leaves retry available',
    () async {
      var scans = 0;
      final resolver = CoverArtworkSourceResolver(
        libraryService: LibraryService(),
        fileCacheGateway: FileCachePlatformGateway(),
        artworkStore: CoverArtworkStore(),
        isClearingPersistentCache: () => false,
        filesystemImageScanner: (_, _) async {
          if (++scans == 1) {
            throw const FileSystemException('Permission denied');
          }
          return ['/work/cover.jpg'];
        },
      );
      await expectLater(
        resolver.discoverFolderImages('/work', propagateFailure: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await resolver.discoverFolderImages('/work', propagateFailure: true),
        ['/work/cover.jpg'],
      );
    },
  );

  for (final contentUri in [false, true]) {
    for (final recursive in [false, true]) {
      test(
        'image index reuses ${contentUri ? 'SAF' : 'filesystem'} '
        '${recursive ? 'recursive' : 'direct'} requests until invalidated',
        () async {
          final root = contentUri ? 'content://library/work' : 'C:\\音乐库\\Work';
          final image = contentUri ? '/cache/cover.jpg' : '$root\\cover.jpg';
          final pending = Completer<List<String>>();
          final started = Completer<void>();
          final requests = <bool>[];
          Future<List<String>> scan(String _, bool recursive) {
            requests.add(recursive);
            if (!started.isCompleted) started.complete();
            return pending.future;
          }

          final resolver = CoverArtworkSourceResolver(
            libraryService: LibraryService(),
            fileCacheGateway: _ImageGateway(scan),
            artworkStore: CoverArtworkStore(),
            isClearingPersistentCache: () => false,
            filesystemImageScanner: scan,
          );
          final first = resolver.discoverFolderImages(
            root,
            recursive: recursive,
          );
          final concurrent = resolver.discoverFolderImages(
            root,
            recursive: recursive,
          );
          await started.future;
          expect(requests, [recursive]);
          pending.complete([image]);
          expect(await first, [image]);
          expect(await concurrent, [image]);
          expect(
            await resolver.discoverFolderImages(root, recursive: recursive),
            [image],
          );
          expect(requests, [recursive]);
          expect(resolver.sourcePathForDisplay(image), isNotNull);
          if (!contentUri) {
            await resolver.discoverFolderImages(
              root.toLowerCase().replaceAll('\\', '/'),
              recursive: recursive,
            );
            expect(requests, [recursive]);
          }
          if (contentUri) {
            for (var index = 0; index < 500; index++) {
              resolver.rememberFolderImageSource(
                '/cache/$index.jpg',
                'content://other/$index',
              );
            }
            expect(resolver.sourcePathForDisplay(image), isNull);
            await resolver.discoverFolderImages(root, recursive: recursive);
            expect(resolver.sourcePathForDisplay(image), '$root/cover.jpg');
            expect(requests, [recursive]);
          }

          await resolver.discoverFolderImages(root, recursive: !recursive);
          expect(requests, [recursive, !recursive]);
          resolver.invalidateFolderImageIndexes(root);
          await resolver.discoverFolderImages(root, recursive: recursive);
          await resolver.discoverFolderImages(root, recursive: !recursive);
          expect(requests, [recursive, !recursive, recursive, !recursive]);
          resolver.trimMemory();
          await resolver.discoverFolderImages(root, recursive: recursive);
          expect(requests, hasLength(5));
          resolver.invalidateAll();
          await resolver.discoverFolderImages(root, recursive: recursive);
          expect(requests, hasLength(6));
        },
      );
    }

    test(
      'failed ${contentUri ? 'SAF' : 'filesystem'} image scan can retry',
      () async {
        final root = contentUri ? 'content://library/work' : '/library/work';
        final image = contentUri ? '/cache/cover.jpg' : '$root/cover.jpg';
        var scans = 0;
        Future<List<String>> scan(String _, bool _) async {
          if (++scans == 1) {
            throw const FileSystemException('Permission denied');
          }
          return [image];
        }

        final resolver = CoverArtworkSourceResolver(
          libraryService: LibraryService(),
          fileCacheGateway: _ImageGateway(scan),
          artworkStore: CoverArtworkStore(),
          isClearingPersistentCache: () => false,
          filesystemImageScanner: scan,
        );
        expect(await resolver.discoverFolderImages(root), isEmpty);
        expect(await resolver.discoverFolderImages(root), [image]);
        expect(await resolver.discoverFolderImages(root), [image]);
        expect(scans, 2);
      },
    );
  }

  for (final clearAll in [false, true]) {
    test(
      'old SAF scan cannot overwrite mappings after ${clearAll ? 'cache clear' : 'folder invalidation'}',
      () async {
        const root = 'content://library/work';
        const image = '/cache/cover.jpg';
        final pending = Completer<void>();
        final gateway = _ImageGateway((_, _) async {
          await pending.future;
          return [image];
        });
        final resolver = CoverArtworkSourceResolver(
          libraryService: LibraryService(),
          fileCacheGateway: gateway,
          artworkStore: CoverArtworkStore(),
          isClearingPersistentCache: () => false,
        );
        final old = resolver.discoverFolderImages(root);
        if (clearAll) {
          resolver.invalidateAll();
        } else {
          resolver.invalidateFolderImageIndexes(root);
        }
        gateway.referenceOverride = const [
          CoverImageReference(
            displayPath: image,
            sourcePath: '$root/new-cover.jpg',
          ),
        ];
        expect(await resolver.discoverFolderImages(root), [image]);
        expect(resolver.sourcePathForDisplay(image), '$root/new-cover.jpg');
        pending.complete();
        expect(await old, isEmpty);
        expect(resolver.sourcePathForDisplay(image), '$root/new-cover.jpg');
      },
    );
  }

  test(
    'image-only candidates skip content reads and cover selection still hashes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cover_hash_reads_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}cover.jpg');
      await file.writeAsBytes([1, 2, 3]);
      var fileLookups = 0;
      final resolver = CoverArtworkSourceResolver(
        libraryService: LibraryService(),
        fileCacheGateway: _ImageGateway((_, _) async => const []),
        artworkStore: CoverArtworkStore(),
        isClearingPersistentCache: () => false,
        filesystemImageScanner: (_, _) async => [file.path],
      );
      await IOOverrides.runZoned(
        () async {
          expect(
            await resolver.resolveFolderCoverCandidates(
              directory.path,
              includeEmbeddedCovers: false,
            ),
            [file.path],
          );
          expect(fileLookups, 0);
          expect(await resolver.resolveFolderCoverCandidates(directory.path), [
            file.path,
          ]);
          expect(fileLookups, greaterThan(0));
        },
        createFile: (_) {
          fileLookups++;
          return file;
        },
      );
    },
  );
}

class _ImageGateway extends FileCachePlatformGateway {
  _ImageGateway(this.scan);

  final Future<List<String>> Function(String, bool) scan;
  List<CoverImageReference>? referenceOverride;
  Future<String?>? coverResult;
  int coverRequests = 0;
  final coverScopes = <(String?, String?)>[];
  int imageCopies = 0;

  @override
  Future<String?> resolveTrackCover({
    required String path,
    String? groupKey,
    String? rootFolder,
    bool propagateFailure = false,
  }) {
    coverRequests++;
    coverScopes.add((groupKey, rootFolder));
    return coverResult ?? Future.value();
  }

  @override
  Future<List<CoverImageReference>> discoverRootImages({
    required String path,
    String? groupKey,
    String? rootFolder,
    bool recursive = true,
    bool preferredOnly = false,
  }) async {
    final images =
        referenceOverride ??
        [
          for (final image in await scan(path, recursive))
            CoverImageReference(
              displayPath: image,
              sourcePath: '$path/cover.jpg',
            ),
        ];
    final selected = preferredOnly ? images.take(1).toList() : images;
    imageCopies += selected.length;
    return selected;
  }
}

class _GeneratingImageGateway extends FileCachePlatformGateway {
  _GeneratingImageGateway(this.generate);
  final Future<String?> Function() generate;

  @override
  Future<String?> resolveTrackCover({
    required String path,
    String? groupKey,
    String? rootFolder,
    bool propagateFailure = false,
  }) => generate();

  @override
  Future<String?> resolveVideoFrame({
    required String path,
    int? modifiedAtMs,
  }) => generate();

  @override
  Future<List<CoverImageReference>> discoverRootImages({
    required String path,
    String? groupKey,
    String? rootFolder,
    bool recursive = true,
    bool preferredOnly = false,
  }) async => [
    CoverImageReference(
      displayPath: (await generate())!,
      sourcePath: '$path/cover.jpg',
    ),
  ];
}
