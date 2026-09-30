import 'dart:async';
import 'dart:io';

import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_source_resolver.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_store.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
            if (contentUri) return const [];
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
        expect(await old, [image]);
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
