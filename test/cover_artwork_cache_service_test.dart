import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/music_track.dart';
import 'package:nameless_audio/models/audio_detail.dart';
import 'package:nameless_audio/services/audio_database_repository.dart';
import 'package:nameless_audio/services/audio_detail_cache_service.dart';
import 'package:nameless_audio/services/audio_detail_repository.dart';
import 'package:nameless_audio/services/audio_state_services.dart';
import 'package:nameless_audio/services/app_cache_service.dart';
import 'package:nameless_audio/services/cover_artwork_cache_service.dart';
import 'package:nameless_audio/services/file_cache_platform_gateway.dart';
import 'package:nameless_audio/services/path_matcher.dart';

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
    final cover = await _temporaryCoverFile('remote_inflight');
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

    completer.complete(cover.path);
    expect(await first, cover.path);
    expect(
      cache.resolvedForRemoteCover(' https://example.com/cover.jpg '),
      cover.path,
    );
  });

  test(
    'tracks with the same remote cover share the resolved cache path',
    () async {
      final cover = await _temporaryCoverFile('shared_remote');
      var downloads = 0;
      final cache = CoverArtworkCacheService(
        libraryService: LibraryService(),
        remoteCoverDownloader: (url) async {
          downloads += 1;
          return cover.path;
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
    final cover = await _temporaryCoverFile('remote_retry');
    var downloads = 0;
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService(),
      remoteCoverDownloader: (_) async {
        downloads += 1;
        return downloads == 1 ? null : cover.path;
      },
    );

    expect(
      await cache.futureForRemoteCover('https://example.com/cover.jpg'),
      isNull,
    );
    expect(
      await cache.futureForRemoteCover('https://example.com/cover.jpg'),
      cover.path,
    );
    expect(downloads, 2);
    expect(
      cache.resolvedForRemoteCover('https://example.com/cover.jpg'),
      cover.path,
    );
  });

  test('playback cover miss remains retryable', () async {
    final cover = await _temporaryCoverFile('playback_remote_retry');
    var downloads = 0;
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService(),
      remoteCoverDownloader: (_) async {
        downloads += 1;
        return downloads == 1 ? null : cover.path;
      },
    );
    const track = MusicTrack(
      path: 'https://example.com/audio.mp3',
      displayName: 'Remote audio',
      groupKey: 'remote',
      groupTitle: 'Remote',
      groupSubtitle: 'Remote',
      isSingle: false,
      remoteCoverUrl: 'https://example.com/cover.jpg',
    );

    expect(await cache.futureForPlaybackTrack(track), isNull);
    expect(await cache.futureForPlaybackTrack(track), cover.path);
    expect(downloads, 2);
  });

  test('evicted remote cover is downloaded again', () async {
    final firstCover = await _temporaryCoverFile('remote_evicted_first');
    final replacementCover = await _temporaryCoverFile(
      'remote_evicted_replacement',
    );
    var downloads = 0;
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService(),
      remoteCoverDownloader: (_) async {
        downloads += 1;
        return downloads == 1 ? firstCover.path : replacementCover.path;
      },
    );
    const url = 'https://example.com/evicted-cover.jpg';

    expect(await cache.futureForRemoteCover(url), firstCover.path);
    await firstCover.delete();

    expect(await cache.futureForRemoteCover(url), replacementCover.path);
    expect(downloads, 2);
    expect(cache.resolvedForRemoteCover(url), replacementCover.path);
  });

  test('remote cover cache hit refreshes file recency', () async {
    final cover = await _temporaryCoverFile('remote_touch');
    final oldModified = DateTime(2020);
    var downloads = 0;
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService(),
      remoteCoverDownloader: (_) async {
        downloads += 1;
        return cover.path;
      },
    );
    const url = 'https://example.com/touched-cover.jpg';

    await cache.futureForRemoteCover(url);
    await cover.setLastModified(oldModified);
    await cache.futureForRemoteCover(url);

    expect(downloads, 1);
    expect((await cover.lastModified()).isAfter(oldModified), isTrue);
  });

  test('cache trim target reserves ten percent for new writes', () {
    expect(applicationCacheTrimTargetBytes(100), 90);
    expect(applicationCacheTrimTargetBytes(1), 1);
  });

  test(
    'folder card cover is reused as the track cover for grouped audio',
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
      final gateway = _FakeFileCachePlatformGateway(
        coversByPath: <String, String>{trackPath: '/cache/track-cover.image'},
      );
      final cache = CoverArtworkCacheService(
        libraryService: LibraryService()..library.add(track),
        fileCacheGateway: gateway,
      );

      await cache.setFolderCoverSelection(directory.path, folderCover);

      expect(cache.resolvedForFolder(directory.path), folderCover);
      expect(await cache.futureForFolder(directory.path), folderCover);
      expect(await cache.futureForTrack(track), folderCover);
    },
  );

  test('changing folder card cover invalidates grouped track covers', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cover_cache_folder_track_sync_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final trackPath = '${directory.path}${Platform.pathSeparator}track.flac';
    final firstCover = '${directory.path}${Platform.pathSeparator}first.jpg';
    final secondCover = '${directory.path}${Platform.pathSeparator}second.jpg';
    await File(trackPath).writeAsBytes(<int>[1]);
    await File(firstCover).writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);
    await File(secondCover).writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);
    final track = _track(path: trackPath, groupKey: directory.path);
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService()..library.add(track),
      fileCacheGateway: _FakeFileCachePlatformGateway(
        coversByPath: <String, String>{trackPath: '/cache/track-cover.image'},
      ),
    );

    await cache.setFolderCoverSelection(directory.path, firstCover);
    expect(await cache.futureForTrack(track), firstCover);
    expect(cache.resolvedForTrack(track), firstCover);

    await cache.setFolderCoverSelection(directory.path, secondCover);

    expect(cache.resolvedForTrack(track), secondCover);
    expect(await cache.futureForTrack(track), secondCover);
  });

  test('new folder cover replaces a cached empty result immediately', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cover_cache_new_folder_cover_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final cache = CoverArtworkCacheService(libraryService: LibraryService());

    expect(await cache.futureForFolder(directory.path), isNull);
    final previousGeneration = cache.generation;
    final folderCover = File(
      '${directory.path}${Platform.pathSeparator}downloaded.jpg',
    );
    await folderCover.writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);

    await cache.setFolderCoverSelection(directory.path, folderCover.path);

    expect(cache.generation, greaterThan(previousGeneration));
    expect(cache.resolvedForFolder(directory.path), folderCover.path);
    expect(await cache.futureForFolder(directory.path), folderCover.path);
  });

  test(
    'newly saved content cover does not wait for directory discovery',
    () async {
      const folder =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic::Work';
      const cover = '/cache/downloaded.image';
      final cache = CoverArtworkCacheService(
        libraryService: LibraryService(),
        fileCacheGateway: _FakeFileCachePlatformGateway(coversByPath: const {}),
      );
      final previousGeneration = cache.generation;

      await cache.setFolderCoverSelection(folder, cover, newlySaved: true);

      expect(cache.generation, greaterThan(previousGeneration));
      expect(cache.resolvedForFolder(folder), cover);
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

  test('resolved folder card cover is reused from the persisted index', () async {
    const root =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic::WorkA';
    const trackPath = '$root/01.mp3';
    const coverPath = 'content://covers/work-a.jpg';
    final details = _MemoryAudioDetailCacheService();
    final library = LibraryService()
      ..library.add(_track(path: trackPath, groupKey: root));
    final firstGateway = _FakeFileCachePlatformGateway(
      coversByPath: const <String, String>{trackPath: coverPath},
    );
    final first = CoverArtworkCacheService(
      libraryService: library,
      audioDetailCacheService: details,
      fileCacheGateway: firstGateway,
    );

    expect(await first.futureForFolder(root), coverPath);
    expect(
      await details.loadCardCoverPath(
        AudioDetailTarget.libraryRootFolder(root),
      ),
      coverPath,
    );

    final restoredGateway = _FakeFileCachePlatformGateway(
      coversByPath: const <String, String>{},
    );
    final restored = CoverArtworkCacheService(
      libraryService: library,
      audioDetailCacheService: details,
      fileCacheGateway: restoredGateway,
    );

    expect(await restored.futureForFolder(root), coverPath);
    expect(restoredGateway.resolveTrackCoverPaths, isEmpty);
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
    'unknown playback track does not infer a folder cover from its path',
    () async {
      final cache = CoverArtworkCacheService(libraryService: LibraryService());

      expect(
        await cache.futureForPlaybackTrack(
          null,
          trackPath: 'C:/library/work/unknown.flac',
        ),
        isNull,
      );
    },
  );

  test(
    'folder audio track and playback covers follow the selected folder cover',
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

      expect(await cache.futureForTrack(track), folderCover);
      expect(cache.resolvedForTrack(track), folderCover);
      final firstPlaybackFuture = cache.futureForPlaybackTrack(track);
      final secondPlaybackFuture = cache.futureForPlaybackTrack(track);
      expect(identical(firstPlaybackFuture, secondPlaybackFuture), isTrue);
      expect(await firstPlaybackFuture, folderCover);
      expect(
        identical(firstPlaybackFuture, cache.futureForPlaybackTrack(track)),
        isTrue,
      );
      expect(cache.resolvedForPlaybackTrack(track), folderCover);
      expect(cache.resolvedForTrack(track), folderCover);

      cache.invalidateFolder(directory.path);
      expect(
        identical(firstPlaybackFuture, cache.futureForPlaybackTrack(track)),
        isFalse,
      );
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

  test('resolved track cover cache trims old non-active entries', () async {
    final tracks = List<MusicTrack>.generate(
      601,
      (index) =>
          _track(path: '/library/track_$index.flac', groupKey: '/library'),
    );
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService()..library.addAll(tracks),
      fileCacheGateway: _FakeFileCachePlatformGateway(
        coversByPath: <String, String>{
          for (final track in tracks) track.path: '/cache/${track.path}.image',
        },
      ),
      isActiveCoverKey: (key) =>
          key == PathMatcher.normalize(tracks.first.path),
    );

    for (final track in tracks) {
      await cache.futureForTrack(track);
    }

    expect(cache.resolvedForTrack(tracks.first), isNotNull);
    expect(cache.resolvedForTrack(tracks[1]), isNull);
    expect(cache.resolvedForTrack(tracks.last), isNotNull);
  });

  test('resolved folder cover cache trims old non-active entries', () async {
    final root = await Directory.systemTemp.createTemp(
      'cover_cache_folder_trim_',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final folders = <Directory>[];
    for (var index = 0; index < 301; index++) {
      final folder = Directory(
        '${root.path}${Platform.pathSeparator}folder_$index',
      );
      await folder.create();
      await File(
        '${folder.path}${Platform.pathSeparator}cover.jpg',
      ).writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);
      folders.add(folder);
    }
    final activeFolderKey = PathMatcher.normalize(folders.first.path);
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService(),
      isActiveCoverKey: (key) => key == activeFolderKey,
    );

    for (final folder in folders) {
      await cache.futureForFolder(folder.path);
    }

    expect(cache.resolvedForFolder(folders.first.path), isNotNull);
    expect(cache.resolvedForFolder(folders[1].path), isNull);
    expect(cache.resolvedForFolder(folders.last.path), isNotNull);
  });

  test('resolved remote cover cache trims old non-active entries', () async {
    final cover = await _temporaryCoverFile('remote_trim');
    final urls = List<String>.generate(
      301,
      (index) => 'https://example.com/cover_$index.jpg',
    );
    final activeRemoteKey = remoteCoverSearchKey(urls.first);
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService(),
      remoteCoverDownloader: (_) async => cover.path,
      isActiveCoverKey: (key) => key == activeRemoteKey,
    );

    for (final url in urls) {
      await cache.futureForRemoteCover(url);
    }

    expect(cache.resolvedForRemoteCover(urls.first), isNotNull);
    expect(cache.resolvedForRemoteCover(urls[1]), isNull);
    expect(cache.resolvedForRemoteCover(urls.last), isNotNull);
  });

  test('manual cover validity cache trims old non-active entries', () async {
    final tracks = List<MusicTrack>.generate(
      1201,
      (index) => _track(
        path: '/library/manual_$index.flac',
        groupKey: '/library',
        manualCoverPath: 'content://manual/$index',
        isSingle: true,
      ),
    );
    final activeTrackKey = PathMatcher.normalize(tracks.first.path);
    final activeManualKey = tracks.first.manualCoverPath;
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService()..library.addAll(tracks),
      isActiveCoverKey: (key) =>
          key == activeTrackKey || key == activeManualKey,
    );

    for (final track in tracks) {
      await Future<void>.delayed(Duration.zero);
      await cache.futureForTrack(track);
    }

    expect(cache.manualCoverPathValidityCacheSize, lessThanOrEqualTo(1200));
    expect(cache.resolvedForTrack(tracks.first), tracks.first.manualCoverPath);
    expect(cache.resolvedForTrack(tracks.last), tracks.last.manualCoverPath);
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

Future<File> _temporaryCoverFile(String prefix) async {
  final directory = await Directory.systemTemp.createTemp('${prefix}_');
  addTearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  final file = File('${directory.path}${Platform.pathSeparator}cover.image');
  await file.writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);
  return file;
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

class _MemoryAudioDetailCacheService extends AudioDetailCacheService {
  _MemoryAudioDetailCacheService()
    : super(
        repository: AudioDetailRepository(
          databaseRepository: _MemoryAudioDatabaseRepository(),
        ),
      );

  final Map<String, String?> _cardCoverPaths = <String, String?>{};

  String _key(AudioDetailTarget target) =>
      '${target.targetType.dbValue}|${PathMatcher.normalize(target.targetPath)}';

  @override
  Future<String?> loadCardCoverPath(AudioDetailTarget target) async {
    return _cardCoverPaths[_key(target)];
  }

  @override
  Future<void> saveCardCoverPath(
    AudioDetailTarget target,
    String? coverPath,
  ) async {
    _cardCoverPaths[_key(target)] = coverPath;
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
