import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/music_track.dart';
import 'package:nameless_audio/services/audio_database_repository.dart';
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
    'loose folder image affects the folder but not the track cover',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cover_cache_folder_selection_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final trackPath = '${directory.path}${Platform.pathSeparator}track.flac';
      final folderCover =
          '${directory.path}${Platform.pathSeparator}folder.jpg';
      await File(trackPath).writeAsBytes(<int>[1]);
      await File(folderCover).writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);
      final track = _track(path: trackPath, groupKey: directory.path);
      final cache = CoverArtworkCacheService(
        libraryService: LibraryService()..library.add(track),
        fileCacheGateway: _FakeFileCachePlatformGateway(
          coversByPath: <String, String>{trackPath: '/cache/track-cover.image'},
        ),
      );

      await cache.setFolderCoverSelection(directory.path, folderCover);

      expect(await cache.futureForFolder(directory.path), folderCover);
      expect(await cache.futureForTrack(track), '/cache/track-cover.image');
    },
  );

  test('folder selection is restored independently from track data', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cover_cache_folder_restore_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final cover = File(
      '${directory.path}${Platform.pathSeparator}selected.jpg',
    );
    await cover.writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);
    final repository = _MemoryAudioDatabaseRepository();
    final trackPath = '${directory.path}${Platform.pathSeparator}track.flac';
    final track = _track(path: trackPath, groupKey: directory.path);
    final library = LibraryService()..library.add(track);
    final gateway = _FakeFileCachePlatformGateway(
      coversByPath: <String, String>{trackPath: cover.path},
    );
    final first = CoverArtworkCacheService(
      libraryService: library,
      databaseRepository: repository,
      fileCacheGateway: gateway,
    );

    await first.setFolderCoverSelection(directory.path, cover.path);
    final restored = CoverArtworkCacheService(
      libraryService: library,
      databaseRepository: repository,
      fileCacheGateway: gateway,
    );

    expect(await restored.futureForFolder(directory.path), cover.path);
  });

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
    'standalone audio track ignores folder image and uses its own embedded cover',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cover_cache_single_audio_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final trackPath = '${directory.path}${Platform.pathSeparator}voice.mp3';
      final folderCover = '${directory.path}${Platform.pathSeparator}cover.jpg';
      await File(trackPath).writeAsBytes(<int>[1]);
      await File(folderCover).writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);

      final library = LibraryService()
        ..watchedFolders.add(directory.path)
        ..library.add(
          _track(path: trackPath, groupKey: '__single_files__', isSingle: true),
        );
      final gateway = _FakeFileCachePlatformGateway(
        coversByPath: <String, String>{trackPath: '/cache/voice-cover.image'},
      );
      final cache = CoverArtworkCacheService(
        libraryService: library,
        fileCacheGateway: gateway,
      );

      expect(
        await cache.futureForTrack(library.library.single),
        '/cache/voice-cover.image',
      );
      expect(gateway.resolveTrackCoverPaths, <String>[trackPath]);
    },
  );

  test('standalone audio track does not fall back to folder cover', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cover_cache_single_audio_miss_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final trackPath = '${directory.path}${Platform.pathSeparator}voice.mp3';
    final folderCover = '${directory.path}${Platform.pathSeparator}cover.jpg';
    await File(trackPath).writeAsBytes(<int>[1]);
    await File(folderCover).writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);

    final library = LibraryService()
      ..watchedFolders.add(directory.path)
      ..library.add(
        _track(path: trackPath, groupKey: '__single_files__', isSingle: true),
      );
    final gateway = _FakeFileCachePlatformGateway(coversByPath: const {});
    final cache = CoverArtworkCacheService(
      libraryService: library,
      fileCacheGateway: gateway,
    );

    expect(await cache.futureForTrack(library.library.single), isNull);
    expect(await cache.futureForPlaybackTrack(library.library.single), isNull);
    expect(gateway.resolveTrackCoverPaths, <String>[trackPath]);
  });

  test(
    'folder audio playback falls back to the selected folder cover only',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cover_cache_playback_folder_fallback_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final trackPath = '${directory.path}${Platform.pathSeparator}voice.flac';
      final folderCover = '${directory.path}${Platform.pathSeparator}cover.jpg';
      await File(trackPath).writeAsBytes(<int>[1]);
      await File(folderCover).writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);

      final track = _track(path: trackPath, groupKey: directory.path);
      final library = LibraryService()
        ..watchedFolders.add(directory.path)
        ..library.add(track);
      final gateway = _FakeFileCachePlatformGateway(coversByPath: const {});
      final cache = CoverArtworkCacheService(
        libraryService: library,
        fileCacheGateway: gateway,
      );

      await cache.setFolderCoverSelection(directory.path, folderCover);

      expect(await cache.futureForTrack(track), isNull);
      expect(cache.resolvedForTrack(track), isNull);
      expect(await cache.futureForPlaybackTrack(track), folderCover);
      expect(cache.resolvedForPlaybackTrack(track), folderCover);
      expect(cache.resolvedForTrack(track), isNull);
    },
  );

  test('tracks in one folder keep separate embedded cover caches', () async {
    final library = LibraryService();
    final first = _track(path: '/work/01.flac', groupKey: '/work');
    final second = _track(path: '/work/02.flac', groupKey: '/work');
    library.library.addAll(<MusicTrack>[first, second]);
    final gateway = _FakeFileCachePlatformGateway(
      coversByPath: const <String, String>{
        '/work/01.flac': '/cache/01.image',
        '/work/02.flac': '/cache/02.image',
      },
    );
    final cache = CoverArtworkCacheService(
      libraryService: library,
      fileCacheGateway: gateway,
    );

    expect(await cache.futureForTrack(first), '/cache/01.image');
    expect(await cache.futureForTrack(second), '/cache/02.image');
    expect(cache.resolvedForTrack(first), '/cache/01.image');
    expect(cache.resolvedForTrack(second), '/cache/02.image');
  });

  test(
    'folder cover candidates include audio covers and video frames',
    () async {
      final library = LibraryService();
      final audio = _track(path: '/work/audio.flac', groupKey: '/work');
      final video = _track(
        path: '/work/video.mp4',
        groupKey: '/work',
        isVideo: true,
      );
      library.library.addAll(<MusicTrack>[audio, video]);
      final cache = CoverArtworkCacheService(
        libraryService: library,
        fileCacheGateway: _FakeFileCachePlatformGateway(
          coversByPath: const <String, String>{
            '/work/audio.flac': '/cache/audio.image',
          },
          videoFramesByPath: const <String, String>{
            '/work/video.mp4': '/cache/video.image',
          },
        ),
      );

      expect(await cache.discoverCoverCandidatesInFolder('/work'), <String>[
        '/cache/audio.image',
        '/cache/video.image',
      ]);
    },
  );

  test('stored cover cache path is used before platform lookup', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cover_cache_stored_track_cover_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final trackPath = '${directory.path}${Platform.pathSeparator}voice.mp3';
    final cachedCover =
        '${directory.path}${Platform.pathSeparator}embedded.image';
    await File(trackPath).writeAsBytes(<int>[1]);
    await File(cachedCover).writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);

    final track = _track(
      path: trackPath,
      groupKey: '__single_files__',
      isSingle: true,
      coverCachePath: cachedCover,
    );
    final gateway = _FakeFileCachePlatformGateway(coversByPath: const {});
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService()..library.add(track),
      fileCacheGateway: gateway,
    );

    expect(await cache.futureForTrack(track), cachedCover);
    expect(gateway.resolveTrackCoverPaths, isEmpty);
  });

  test('new folder image resolves after folder cache invalidation', () async {
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
  _FakeFileCachePlatformGateway({
    required this.coversByPath,
    this.videoFramesByPath = const <String, String>{},
  });

  final Map<String, String> coversByPath;
  final Map<String, String> videoFramesByPath;
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

  @override
  Future<String?> resolveVideoFrame({required String path, int? modifiedAtMs}) {
    return Future<String?>.value(videoFramesByPath[path]);
  }
}

class _MemoryAudioDatabaseRepository extends AudioDatabaseRepository {
  final Map<String, String> _settings = <String, String>{};

  @override
  Future<String?> loadAppSetting(String key) async => _settings[key];

  @override
  Future<void> saveAppSetting(String key, String? value) async {
    if (value == null) {
      _settings.remove(key);
    } else {
      _settings[key] = value;
    }
  }
}

MusicTrack _track({
  required String path,
  required String groupKey,
  String? manualCoverPath,
  String? coverCachePath,
  bool isSingle = false,
  bool isVideo = false,
}) {
  return MusicTrack(
    path: path,
    displayName: 'Track',
    groupKey: groupKey,
    groupTitle: 'Work',
    groupSubtitle: groupKey,
    isSingle: isSingle,
    isVideo: isVideo,
    coverCachePath: coverCachePath,
    manualCoverPath: manualCoverPath,
  );
}
