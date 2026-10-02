import 'dart:async';
import 'dart:io';

import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_source_resolver.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_store.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
          final requests = <bool>[];
          Future<List<String>> scan(String _, bool recursive) {
            requests.add(recursive);
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

  @override
  Future<String?> resolveTrackCover({
    required String path,
    String? groupKey,
    String? rootFolder,
  }) {
    coverRequests++;
    return coverResult ?? Future.value();
  }

  @override
  Future<List<CoverImageReference>> discoverRootImages({
    required String path,
    String? groupKey,
    String? rootFolder,
    bool recursive = true,
  }) async =>
      referenceOverride ??
      [
        for (final image in await scan(path, recursive))
          CoverImageReference(
            displayPath: image,
            sourcePath: '$path/cover.jpg',
          ),
      ];
}
