import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/music_track.dart';
import 'package:nameless_audio/services/audio_state_services.dart';
import 'package:nameless_audio/services/cover_artwork_cache_service.dart';
import 'package:nameless_audio/services/file_cache_platform_gateway.dart';

void main() {
  test('folder cover future reuses the same in-flight lookup', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cover_cache_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final cache = CoverArtworkCacheService(libraryService: LibraryService());

    final first = cache.futureForFolder(directory.path);
    final second = cache.futureForFolder(directory.path);

    expect(identical(first, second), isTrue);
    expect(await first, isNull);
  });

  test('remote cover future reuses the same in-flight download', () async {
    final completer = Completer<String?>();
    var downloads = 0;
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService(),
      remoteCoverDownloader: (url) {
        downloads += 1;
        return completer.future;
      },
    );

    final first = cache.futureForRemoteCover('https://example.com/cover.jpg');
    final second = cache.futureForRemoteCover('https://example.com/cover.jpg');

    expect(identical(first, second), isTrue);
    expect(downloads, 1);

    completer.complete('/cache/cover.image');
    expect(await first, '/cache/cover.image');
    expect(
      cache.resolvedForRemoteCover(' https://example.com/cover.jpg '),
      '/cache/cover.image',
    );
  });

  test(
    'tracks with the same remote cover share the resolved cache path',
    () async {
      var downloads = 0;
      final cache = CoverArtworkCacheService(
        libraryService: LibraryService(),
        remoteCoverDownloader: (url) async {
          downloads += 1;
          return '/cache/${url.hashCode}.image';
        },
      );
      const first = MusicTrack(
        path: 'https://example.com/audio-a.mp3',
        displayName: 'A',
        groupKey: 'remote-a',
        groupTitle: 'Remote',
        groupSubtitle: 'Remote',
        isSingle: false,
        remoteCoverUrl: 'https://example.com/cover.jpg',
      );
      const second = MusicTrack(
        path: 'https://example.com/audio-b.mp3',
        displayName: 'B',
        groupKey: 'remote-b',
        groupTitle: 'Remote',
        groupSubtitle: 'Remote',
        isSingle: false,
        remoteCoverUrl: ' https://example.com/cover.jpg ',
      );

      final firstPath = await cache.futureForTrack(first);
      final secondPath = await cache.futureForTrack(second);

      expect(firstPath, secondPath);
      expect(downloads, 1);
      expect(cache.resolvedForTrack(first), firstPath);
      expect(cache.resolvedForTrack(second), firstPath);
    },
  );

  test('remote cover search key normalizes whitespace and trailing slash', () {
    expect(
      remoteCoverSearchKey(' https://example.com/cover.jpg/ '),
      remoteCoverSearchKey('https://example.com/cover.jpg'),
    );
  });

  test('remote cover miss is not cached so retry can download again', () async {
    var downloads = 0;
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService(),
      remoteCoverDownloader: (_) async {
        downloads += 1;
        return downloads == 1 ? null : '/cache/cover.image';
      },
    );

    expect(
      await cache.futureForRemoteCover('https://example.com/cover.jpg'),
      isNull,
    );
    expect(
      await cache.futureForRemoteCover('https://example.com/cover.jpg'),
      '/cache/cover.image',
    );
    expect(downloads, 2);
    expect(
      cache.resolvedForRemoteCover('https://example.com/cover.jpg'),
      '/cache/cover.image',
    );
  });

  test(
    'manual cover is validated asynchronously before scanning the folder',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cover_cache_manual_test_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final manualCover = File(
        '${directory.path}${Platform.pathSeparator}manual.jpg',
      );
      await manualCover.writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);

      final library = LibraryService();
      library.watchedFolders.add('/library');
      library.library.add(
        _track(
          path: '/library/work/track.mp3',
          groupKey: '/library/work',
          manualCoverPath: manualCover.path,
        ),
      );
      final cache = CoverArtworkCacheService(libraryService: library);

      expect(cache.resolvedForFolder('/library'), isNull);
      expect(await cache.futureForFolder('/library'), manualCover.path);
      expect(cache.resolvedForFolder('/library'), manualCover.path);
      expect(cache.resolvedForTrack(library.library.single), manualCover.path);
    },
  );

  test('content folder cover tries later tracks when the first misses', () async {
    const root =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic::WorkA';
    final library = LibraryService()
      ..library.addAll(const <MusicTrack>[
        MusicTrack(
          path:
              'content://com.android.externalstorage.documents/tree/primary%3AMusic::WorkA/01.mp3',
          displayName: '01',
          groupKey: root,
          groupTitle: 'Work A',
          groupSubtitle: 'Work A',
          isSingle: false,
        ),
        MusicTrack(
          path:
              'content://com.android.externalstorage.documents/tree/primary%3AMusic::WorkA/02.mp3',
          displayName: '02',
          groupKey: root,
          groupTitle: 'Work A',
          groupSubtitle: 'Work A',
          isSingle: false,
        ),
      ]);
    final gateway = _FakeFileCachePlatformGateway(
      coversByPath: const <String, String>{
        'content://com.android.externalstorage.documents/tree/primary%3AMusic::WorkA/02.mp3':
            'content://covers/work-a.jpg',
      },
    );
    final cache = CoverArtworkCacheService(
      libraryService: library,
      fileCacheGateway: gateway,
    );

    expect(await cache.futureForFolder(root), 'content://covers/work-a.jpg');
    expect(gateway.resolveTrackCoverPaths, <String>[
      'content://com.android.externalstorage.documents/tree/primary%3AMusic::WorkA/01.mp3',
      'content://com.android.externalstorage.documents/tree/primary%3AMusic::WorkA/02.mp3',
    ]);
  });

  test(
    'filesystem folder cover tries later tracks when the first misses',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cover_cache_embedded_test_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final firstPath = '${directory.path}${Platform.pathSeparator}01.mp3';
      final secondPath = '${directory.path}${Platform.pathSeparator}02.mp3';
      await File(firstPath).writeAsBytes(<int>[1]);
      await File(secondPath).writeAsBytes(<int>[2]);

      final library = LibraryService()
        ..library.addAll(<MusicTrack>[
          _track(path: firstPath, groupKey: directory.path),
          _track(path: secondPath, groupKey: directory.path),
        ]);
      final gateway = _FakeFileCachePlatformGateway(
        coversByPath: <String, String>{secondPath: '/cache/02-cover.image'},
      );
      final cache = CoverArtworkCacheService(
        libraryService: library,
        fileCacheGateway: gateway,
      );

      expect(
        await cache.futureForFolder(directory.path),
        '/cache/02-cover.image',
      );
      expect(gateway.resolveTrackCoverPaths, <String>[firstPath, secondPath]);
    },
  );

  test(
    'stale restored manual cover is ignored and folder is rescanned',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cover_cache_stale_manual_test_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final cover = File('${directory.path}${Platform.pathSeparator}cover.jpg');
      await cover.writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);
      final missingCover =
          '${directory.path}${Platform.pathSeparator}old_cache.image';

      final library = LibraryService()
        ..library.add(
          _track(
            path: '${directory.path}${Platform.pathSeparator}track.mp3',
            groupKey: directory.path,
            manualCoverPath: missingCover,
          ),
        );
      final cache = CoverArtworkCacheService(libraryService: library);

      expect(cache.resolvedForFolder(directory.path), isNull);
      expect(await cache.futureForFolder(directory.path), cover.path);
    },
  );

  test('manual cover miss is cached until scope invalidation', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cover_cache_manual_miss_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final missingCover = '${directory.path}${Platform.pathSeparator}manual.jpg';
    final library = LibraryService()
      ..library.add(
        _track(
          path: '${directory.path}${Platform.pathSeparator}track.mp3',
          groupKey: directory.path,
          manualCoverPath: missingCover,
        ),
      );
    final cache = CoverArtworkCacheService(libraryService: library);

    expect(cache.resolvedForFolder(directory.path), isNull);
    await File(missingCover).writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);

    expect(cache.resolvedForFolder(directory.path), isNull);
    cache.invalidateFolder(directory.path);
    expect(await cache.futureForFolder(directory.path), missingCover);
    expect(cache.resolvedForFolder(directory.path), missingCover);
  });

  test('folder miss can resolve after scope invalidation', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cover_cache_miss_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final cache = CoverArtworkCacheService(libraryService: LibraryService());

    expect(await cache.futureForFolder(directory.path), isNull);
    final cover = File('${directory.path}${Platform.pathSeparator}cover.jpg');
    await cover.writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);

    expect(await cache.futureForFolder(directory.path), isNull);
    cache.invalidateFolder(directory.path);
    expect(await cache.futureForFolder(directory.path), cover.path);
  });

  test('scope invalidation only bumps generation for affected cache keys', () {
    final cache = CoverArtworkCacheService(libraryService: LibraryService());

    expect(cache.generation, 0);
    cache.invalidateFolder('/library/work');
    expect(cache.generation, 1);
    cache.invalidateFolders(['/library/work', '/library/other']);
    expect(cache.generation, 2);
    cache.invalidateAll();
    expect(cache.generation, 3);
  });
}

class _FakeFileCachePlatformGateway extends FileCachePlatformGateway {
  _FakeFileCachePlatformGateway({required this.coversByPath});

  final Map<String, String> coversByPath;
  final List<String> resolveTrackCoverPaths = <String>[];

  @override
  Future<String?> resolveTrackCover({
    required String path,
    String? groupKey,
    String? rootFolder,
  }) async {
    resolveTrackCoverPaths.add(path);
    return coversByPath[path];
  }
}

MusicTrack _track({
  required String path,
  required String groupKey,
  String? manualCoverPath,
}) {
  return MusicTrack(
    path: path,
    displayName: 'Track',
    groupKey: groupKey,
    groupTitle: 'Work',
    groupSubtitle: groupKey,
    isSingle: false,
    manualCoverPath: manualCoverPath,
  );
}
