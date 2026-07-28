import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/music_track.dart';
import 'package:nameless_audio/core/media/audio_detail.dart';
import 'support/test_persistence_repository.dart';
import 'package:nameless_audio/features/library/application/audio_detail_cache_service.dart';
import 'package:nameless_audio/features/library/application/audio_detail_repository.dart';
import 'package:nameless_audio/features/library/application/library_service.dart';
import 'package:nameless_audio/features/settings/application/app_cache_service.dart';
import 'package:nameless_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:nameless_audio/features/library/application/cover_image_cache_policy.dart';
import 'package:nameless_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:nameless_audio/core/media/path_matcher.dart';

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

  test('resolved remote cover reuses its completed future', () async {
    final cover = await _temporaryCoverFile('remote_resolved_future');
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService(),
      remoteCoverDownloader: (_) async => cover.path,
    );
    addTearDown(cache.dispose);
    const url = 'https://example.com/resolved-cover.jpg';

    await cache.futureForRemoteCover(url);
    final second = cache.futureForRemoteCover(url);
    final third = cache.futureForRemoteCover(url);

    expect(identical(second, third), isTrue);
    expect(await second, cover.path);
  });

  test('ASMR remote covers use the gateway language header', () {
    expect(
      remoteCoverRequestHeadersForUrl(
        'https://api.asmr-300.com/api/cover/123.jpg',
      )[HttpHeaders.acceptLanguageHeader],
      'zh-CN,zh;q=0.9,en;q=0.8',
    );
    expect(
      remoteCoverRequestHeadersForUrl('https://example.com/cover.jpg'),
      isEmpty,
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
      final first = MusicTrack(
        path: 'https://example.com/audio-a.mp3',
        displayName: 'A',
        groupKey: 'remote-a',
        groupTitle: 'Remote',
        groupSubtitle: 'Remote',
        isSingle: false,
        remoteCoverUrl: 'https://example.com/cover.jpg',
      );
      final second = MusicTrack(
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

  test('remote cover miss uses shared retry cooldown', () async {
    final cover = await _temporaryCoverFile('remote_retry');
    var downloads = 0;
    var now = DateTime(2026);
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService(),
      now: () => now,
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
      isNull,
    );
    expect(downloads, 1);

    now = now.add(const Duration(seconds: 10));
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

  test('remote cover retry delay doubles and caps at five minutes', () async {
    var downloads = 0;
    var now = DateTime(2026);
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService(),
      now: () => now,
      remoteCoverDownloader: (_) async {
        downloads++;
        return null;
      },
    );
    const retryDelays = <Duration>[
      Duration(seconds: 10),
      Duration(seconds: 20),
      Duration(seconds: 40),
      Duration(seconds: 80),
      Duration(seconds: 160),
      Duration(seconds: 300),
    ];

    for (var attempt = 0; attempt < retryDelays.length; attempt++) {
      expect(
        await cache.futureForRemoteCover('https://example.com/missing.jpg'),
        isNull,
      );
      expect(downloads, attempt + 1);
      expect(
        await cache.futureForRemoteCover('https://example.com/missing.jpg'),
        isNull,
      );
      expect(downloads, attempt + 1);
      now = now.add(retryDelays[attempt]);
    }
  });

  test('playback cover miss remains retryable', () async {
    final cover = await _temporaryCoverFile('playback_remote_retry');
    var downloads = 0;
    var now = DateTime(2026);
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService(),
      now: () => now,
      remoteCoverDownloader: (_) async {
        downloads += 1;
        return downloads == 1 ? null : cover.path;
      },
    );
    final track = MusicTrack(
      path: 'https://example.com/audio.mp3',
      displayName: 'Remote audio',
      groupKey: 'remote',
      groupTitle: 'Remote',
      groupSubtitle: 'Remote',
      isSingle: false,
      remoteCoverUrl: 'https://example.com/cover.jpg',
    );

    expect(await cache.futureForPlaybackTrack(track), isNull);
    expect(await cache.futureForPlaybackTrack(track), isNull);
    expect(downloads, 1);
    await Future<void>.delayed(Duration.zero);
    now = now.add(const Duration(seconds: 10));
    expect(await cache.futureForPlaybackTrack(track), cover.path);
    expect(downloads, 2);
  });

  test('remote cover downloads never exceed four concurrent tasks', () async {
    final cover = await _temporaryCoverFile('remote_concurrency');
    final release = Completer<void>();
    var active = 0;
    var peak = 0;
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService(),
      remoteCoverDownloader: (_) async {
        active++;
        if (active > peak) peak = active;
        await release.future;
        active--;
        return cover.path;
      },
    );

    final futures = <Future<String?>>[
      for (var index = 0; index < 8; index++)
        cache.futureForRemoteCover('https://example.com/$index.jpg'),
    ];
    await Future<void>.delayed(Duration.zero);

    expect(active, 4);
    expect(peak, 4);
    release.complete();
    expect(await Future.wait(futures), everyElement(cover.path));
    expect(peak, 4);
  });

  test(
    'remote cover download streams valid images and removes partials',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'remote_cover_stream_',
      );
      final pngBytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/valid') {
          request.response.add(pngBytes);
        } else if (request.uri.path == '/too-large') {
          request.response.contentLength = maxCoverFileBytes + 1;
          request.response.add(List<int>.filled(maxCoverFileBytes + 1, 0));
        } else if (request.uri.path == '/chunked-too-large') {
          request.response.headers.chunkedTransferEncoding = true;
          request.response.add(List<int>.filled(maxCoverFileBytes + 1, 0));
        } else {
          request.response.add(utf8.encode('not an image'));
        }
        await request.response.close();
      });
      addTearDown(() async {
        await server.close(force: true);
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final cache = CoverArtworkCacheService(
        libraryService: LibraryService(),
        temporaryDirectory: () async => directory,
      );
      addTearDown(cache.dispose);
      String url(String path) =>
          'http://${server.address.address}:${server.port}/$path';

      final validPath = await cache.futureForRemoteCover(url('valid'));
      expect(validPath, isNotNull);
      expect(await File(validPath!).readAsBytes(), pngBytes);
      expect(await cache.futureForRemoteCover(url('too-large')), isNull);
      expect(
        await cache.futureForRemoteCover(url('chunked-too-large')),
        isNull,
      );
      expect(await cache.futureForRemoteCover(url('invalid')), isNull);
      expect(
        directory
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.part')),
        isEmpty,
      );
    },
  );

  test('stalled remote covers release a slot for the next request', () async {
    final directory = await Directory.systemTemp.createTemp(
      'remote_cover_timeout_',
    );
    final pngBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
      '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    final fifthStarted = Completer<void>();
    server.listen((request) async {
      requests++;
      if (requests <= 4) {
        request.response.headers.chunkedTransferEncoding = true;
        request.response.add(pngBytes.take(8).toList());
        await request.response.flush();
        return;
      }
      if (!fifthStarted.isCompleted) fifthStarted.complete();
      request.response.add(pngBytes);
      await request.response.close();
    });
    addTearDown(() async {
      await server.close(force: true);
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService(),
      temporaryDirectory: () async => directory,
      requestTimeout: const Duration(seconds: 1),
      downloadIdleTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(cache.dispose);
    final baseUrl = 'http://${server.address.address}:${server.port}';

    final futures = <Future<String?>>[
      for (var index = 0; index < 5; index++)
        cache.futureForRemoteCover('$baseUrl/$index.png'),
    ];

    await fifthStarted.future.timeout(const Duration(seconds: 2));
    final results = await Future.wait(futures);
    expect(requests, 5);
    expect(results.take(4), everyElement(isNull));
    expect(results.last, isNotNull);
    expect(
      directory
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.part')),
      isEmpty,
    );
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
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect((await cover.lastModified()).isAfter(oldModified), isTrue);
  });

  test('remote cover recency touch is throttled for five minutes', () async {
    final cover = await _temporaryCoverFile('remote_touch_throttle');
    final oldModified = DateTime(2020);
    var now = DateTime(2026, 1, 1, 12);
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService(),
      now: () => now,
      remoteCoverDownloader: (_) async => cover.path,
    );
    addTearDown(cache.dispose);
    const url = 'https://example.com/throttled-cover.jpg';

    await cache.futureForRemoteCover(url);
    await cover.setLastModified(oldModified);
    await cache.futureForRemoteCover(url);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect((await cover.lastModified()).isAfter(oldModified), isTrue);

    await cover.setLastModified(oldModified);
    await cache.futureForRemoteCover(url);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await cover.lastModified(), oldModified);

    now = now.add(const Duration(minutes: 5));
    await cache.futureForRemoteCover(url);
    await Future<void>.delayed(const Duration(milliseconds: 100));
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
          'content://com.android.externalstorage.documents/tree/primary%3AMusic/'
          'document/primary%3AMusic%2FWork';
      const cover = '/cache/downloaded.image';
      const source =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic/'
          'document/primary%3AMusic%2FWork%2Fdownloaded.jpg';
      final details = _MemoryAudioDetailCacheService();
      final cache = CoverArtworkCacheService(
        libraryService: LibraryService(),
        audioDetailCacheService: details,
        fileCacheGateway: _FakeFileCachePlatformGateway(coversByPath: const {}),
      );
      final previousGeneration = cache.generation;

      await cache.setFolderCoverSelection(
        folder,
        cover,
        newlySaved: true,
        sourcePath: source,
      );

      expect(cache.generation, greaterThan(previousGeneration));
      expect(cache.resolvedForFolder(folder), cover);
      expect(
        await details.loadCardCoverSelection(
          AudioDetailTarget.libraryRootFolder(folder),
        ),
        (path: source, selected: true),
      );
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
    final repository = _MemoryTestPersistenceRepository();
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

  test(
    'stale folder selection falls back to selected audio detail cover',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cover_cache_selected_detail_restore_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final cover = File(
        '${directory.path}${Platform.pathSeparator}restored.jpg',
      );
      await cover.writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);
      final track = _track(
        path: '${directory.path}${Platform.pathSeparator}track.flac',
        groupKey: directory.path,
      );
      final repository = _MemoryTestPersistenceRepository();
      await repository.saveAppSetting(
        'folder_cover_selections_v1',
        json.encode(<String, String>{
          directory.path: '${directory.path}${Platform.pathSeparator}stale.jpg',
        }),
      );
      final details = _MemoryAudioDetailCacheService();
      await details.saveCardCoverPath(
        AudioDetailTarget.libraryRootFolder(directory.path),
        cover.path,
        selected: true,
      );
      final cache = CoverArtworkCacheService(
        libraryService: LibraryService()..library.add(track),
        databaseRepository: repository,
        audioDetailCacheService: details,
        fileCacheGateway: _FakeFileCachePlatformGateway(coversByPath: const {}),
      );

      expect(await cache.futureForTrack(track), cover.path);
      expect(await cache.futureForFolder(directory.path), cover.path);
    },
  );

  test('manual folder selection keeps the persisted portable path', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cover_cache_portable_selection_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final source = await _temporaryCoverFile('external_manual_selection');
    final portable = File(
      '${directory.path}${Platform.pathSeparator}portable.jpg',
    );
    await portable.writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);
    final track = _track(
      path: '${directory.path}${Platform.pathSeparator}track.flac',
      groupKey: directory.path,
    );
    final details = _MemoryAudioDetailCacheService(
      persistedPathOverride: portable.path,
    );
    final cache = CoverArtworkCacheService(
      libraryService: LibraryService()..library.add(track),
      audioDetailCacheService: details,
      fileCacheGateway: _FakeFileCachePlatformGateway(coversByPath: const {}),
    );

    expect(
      await cache.setFolderCoverSelection(
        directory.path,
        source.path,
        newlySaved: true,
      ),
      portable.path,
    );
    expect(await cache.futureForTrack(track), portable.path);
    expect(
      await details.loadCardCoverSelection(
        AudioDetailTarget.libraryRootFolder(directory.path),
      ),
      (path: portable.path, selected: true),
    );
  });

  test('child folder covers never access audio detail JSON state', () async {
    const libraryRoot =
        'content://com.android.externalstorage.documents/tree/primary%3ALibrary';
    const workRoot = '$libraryRoot::Work';
    const childFolder = '$workRoot/音声';
    const childCover = 'content://covers/child.jpg';
    final details = _MemoryAudioDetailCacheService();
    final library = LibraryService()
      ..watchedLibraries.add(libraryRoot)
      ..library.add(
        _track(path: '$libraryRoot/document/track.wav', groupKey: childFolder),
      );
    final cache = CoverArtworkCacheService(
      libraryService: library,
      audioDetailCacheService: details,
      fileCacheGateway: _FakeFileCachePlatformGateway(
        coversByPath: const <String, String>{},
        discoveredImages: (_) async => const <CoverImageReference>[
          CoverImageReference(displayPath: childCover, sourcePath: childCover),
        ],
      ),
    );

    expect(await cache.futureForFolder(childFolder), childCover);
    expect(
      await cache.setFolderCoverSelection(
        childFolder,
        childCover,
        newlySaved: true,
      ),
      childCover,
    );
    expect(details.loadedTargets, isEmpty);
    expect(details.savedTargets, isEmpty);
  });

  test(
    'folder image selection persists its source URI instead of cache path',
    () async {
      const folder =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic/'
          'document/primary%3AMusic%2FWork';
      const source =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic/'
          'document/primary%3AMusic%2FWork%2Fimages%2Fcover.png';
      final cachedCover = await _temporaryCoverFile('source_uri_selection');
      final details = _MemoryAudioDetailCacheService();
      final cache = CoverArtworkCacheService(
        libraryService: LibraryService(),
        audioDetailCacheService: details,
        fileCacheGateway: _FakeFileCachePlatformGateway(
          coversByPath: const <String, String>{},
          discoveredImages: (_) async => <CoverImageReference>[
            CoverImageReference(
              displayPath: cachedCover.path,
              sourcePath: source,
            ),
          ],
        ),
      );

      expect(
        await cache.setFolderCoverSelection(folder, cachedCover.path),
        cachedCover.path,
      );
      expect(
        await details.loadCardCoverSelection(
          AudioDetailTarget.libraryRootFolder(folder),
        ),
        (path: source, selected: true),
      );
    },
  );

  test(
    'persisted source URI resolves to a fresh display cache on re-import',
    () async {
      const folder =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic/'
          'document/primary%3AMusic%2FWork';
      const source =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic/'
          'document/primary%3AMusic%2FWork%2Fimages%2Fcover.png';
      final freshCache = await _temporaryCoverFile('source_uri_restore');
      final target = AudioDetailTarget.libraryRootFolder(folder);
      final details = _MemoryAudioDetailCacheService()
        ..seedCardCover(target, source, selected: true);
      final cache = CoverArtworkCacheService(
        libraryService: LibraryService(),
        audioDetailCacheService: details,
        fileCacheGateway: _FakeFileCachePlatformGateway(
          coversByPath: const <String, String>{},
          discoveredImages: (_) async => <CoverImageReference>[
            CoverImageReference(
              displayPath: freshCache.path,
              sourcePath: source,
            ),
          ],
        ),
      );

      expect(await cache.futureForFolder(folder), freshCache.path);
      expect(cache.resolvedForFolder(folder), freshCache.path);
      expect(await details.loadCardCoverSelection(target), (
        path: source,
        selected: true,
      ));
    },
  );

  test('resolved folder card cover is reused from the persisted index', () async {
    const root =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic::WorkA';
    const trackPath = '$root/01.mp3';
    const coverPath = 'content://covers/work-a.jpg';
    final details = _MemoryAudioDetailCacheService();
    final library = LibraryService()
      ..library.add(_track(path: trackPath, groupKey: root))
      ..tracksByGroup[root] = <MusicTrack>[
        _track(path: trackPath, groupKey: root),
      ];
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
      ..library.addAll(<MusicTrack>[
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
    library.tracksByGroup[root] = List<MusicTrack>.from(library.library);
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
      library.tracksByGroup[directory.path] = List<MusicTrack>.from(
        library.library,
      );
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

  test('folder card cover stops after the first embedded cover hit', () async {
    final library = LibraryService();
    final tracks = List<MusicTrack>.generate(
      3,
      (index) => _track(path: '/work/0$index.flac', groupKey: '/work'),
    );
    library
      ..library.addAll(tracks)
      ..tracksByGroup['/work'] = tracks;
    final gateway = _FakeFileCachePlatformGateway(
      coversByPath: <String, String>{tracks.first.path: '/cache/first.image'},
    );
    final cache = CoverArtworkCacheService(
      libraryService: library,
      fileCacheGateway: gateway,
    );

    expect(await cache.futureForFolder('/work'), '/cache/first.image');
    expect(gateway.resolveTrackCoverPaths, <String>[tracks.first.path]);
  });

  test('folder image avoids embedded cover lookups', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cover_cache_preferred_folder_image_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final cover = File('${directory.path}${Platform.pathSeparator}cover.jpg');
    await cover.writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);
    final track = _track(
      path: '${directory.path}${Platform.pathSeparator}audio.flac',
      groupKey: directory.path,
    );
    final library = LibraryService()
      ..library.add(track)
      ..tracksByGroup[directory.path] = <MusicTrack>[track];
    final gateway = _FakeFileCachePlatformGateway(
      coversByPath: <String, String>{track.path: '/cache/unused.image'},
    );
    final cache = CoverArtworkCacheService(
      libraryService: library,
      fileCacheGateway: gateway,
    );

    expect(await cache.futureForFolder(directory.path), cover.path);
    expect(gateway.resolveTrackCoverPaths, isEmpty);
  });

  test('folder card embedded-cover lookup stays in its work tree', () async {
    const root =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic::Work';
    const subfolder = '$root/Sub';
    const sibling =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic::Other';
    final rootTrack = _track(path: '$root/01.flac', groupKey: root);
    final subfolderTrack = _track(
      path: '$subfolder/02.flac',
      groupKey: subfolder,
    );
    final siblingTrack = _track(
      path: '$sibling/ignored.flac',
      groupKey: sibling,
    );
    final library = LibraryService()
      ..library.addAll(<MusicTrack>[siblingTrack, subfolderTrack, rootTrack])
      ..tracksByGroup[root] = <MusicTrack>[rootTrack]
      ..tracksByGroup[subfolder] = <MusicTrack>[subfolderTrack]
      ..tracksByGroup[sibling] = <MusicTrack>[siblingTrack];
    final gateway = _FakeFileCachePlatformGateway(coversByPath: const {});
    final cache = CoverArtworkCacheService(
      libraryService: library,
      fileCacheGateway: gateway,
    );

    expect(await cache.futureForFolder(root), isNull);
    expect(gateway.resolveTrackCoverPaths, <String>[
      subfolderTrack.path,
      rootTrack.path,
    ]);
  });

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
    'playlist tracks use the same preferred cover as their work card',
    () async {
      final library = LibraryService();
      final first = _track(path: '/work/01.flac', groupKey: '/work');
      final second = _track(path: '/work/02.flac', groupKey: '/work');
      library
        ..library.addAll(<MusicTrack>[first, second])
        ..tracksByGroup['/work'] = <MusicTrack>[first, second];
      final cache = CoverArtworkCacheService(
        libraryService: library,
        fileCacheGateway: _FakeFileCachePlatformGateway(
          coversByPath: const <String, String>{
            '/work/01.flac': '/cache/work.image',
            '/work/02.flac': '/cache/second.image',
          },
        ),
      );

      expect(await cache.futureForTrack(second), '/cache/second.image');
      expect(await cache.futureForFolder('/work'), '/cache/work.image');
      expect(await cache.futureForPlaybackTrack(second), '/cache/work.image');
      expect(cache.resolvedForPlaybackTrack(second), '/cache/work.image');
    },
  );

  test(
    'folder detail candidates include every image audio cover and video frame',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cover_cache_detail_candidates_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final nested = Directory(
        '${directory.path}${Platform.pathSeparator}nested',
      );
      await nested.create();
      final firstImage =
          '${directory.path}${Platform.pathSeparator}01-cover.jpg';
      final secondImage = '${nested.path}${Platform.pathSeparator}02-cover.png';
      await File(firstImage).writeAsBytes(<int>[1]);
      await File(secondImage).writeAsBytes(<int>[2]);

      final library = LibraryService();
      final audioPath = '${directory.path}${Platform.pathSeparator}audio.flac';
      final videoPath = '${nested.path}${Platform.pathSeparator}video.mp4';
      final audio = _track(path: audioPath, groupKey: directory.path);
      final video = _track(
        path: videoPath,
        groupKey: nested.path,
        isVideo: true,
      );
      library.library.addAll(<MusicTrack>[audio, video]);
      final cache = CoverArtworkCacheService(
        libraryService: library,
        fileCacheGateway: _FakeFileCachePlatformGateway(
          coversByPath: <String, String>{audioPath: '/cache/audio.image'},
          videoFramesByPath: <String, String>{videoPath: '/cache/video.image'},
        ),
      );

      expect(
        await cache.discoverCoverCandidatesInFolder(directory.path),
        <String>[
          firstImage,
          secondImage,
          '/cache/audio.image',
          '/cache/video.image',
        ],
      );
    },
  );

  test(
    'folder detail cover resolution uses four workers and keeps track order',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cover_cache_candidate_concurrency_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final tracks = <MusicTrack>[
        for (var index = 0; index < 10; index++)
          _track(
            path: '${directory.path}${Platform.pathSeparator}$index.flac',
            groupKey: directory.path,
          ),
      ];
      var active = 0;
      var peak = 0;
      final gateway = _FakeFileCachePlatformGateway(
        coversByPath: const <String, String>{},
        resolveTrackCoverHandler: (trackPath, _) async {
          active++;
          if (active > peak) peak = active;
          final index = int.parse(
            trackPath.split(Platform.pathSeparator).last.split('.').first,
          );
          await Future<void>.delayed(
            Duration(milliseconds: (4 - index % 4) * 5),
          );
          active--;
          return index == 7 ? '/cache/3.image' : '/cache/$index.image';
        },
      );
      final cache = CoverArtworkCacheService(
        libraryService: LibraryService()..library.addAll(tracks),
        fileCacheGateway: gateway,
      );

      expect(
        await cache.discoverCoverCandidatesInFolder(directory.path),
        <String>[
          for (var index = 0; index < 10; index++)
            if (index != 7) '/cache/$index.image',
        ],
      );
      expect(peak, 4);
    },
  );

  test(
    'folder detail audio candidates do not repeat the content folder image',
    () async {
      const root =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic::WorkA';
      final tracks = <MusicTrack>[
        _track(path: '$root/01.mp3', groupKey: root),
        _track(path: '$root/02.mp3', groupKey: root),
      ];
      final gateway = _FakeFileCachePlatformGateway(
        coversByPath: <String, String>{
          tracks.first.path: '/cache/embedded-01.image',
          tracks.last.path: '/cache/embedded-02.image',
        },
      );
      final cache = CoverArtworkCacheService(
        libraryService: LibraryService()..library.addAll(tracks),
        fileCacheGateway: gateway,
      );

      expect(await cache.discoverCoverCandidatesInFolder(root), <String>[
        '/cache/embedded-01.image',
        '/cache/embedded-02.image',
      ]);
      expect(gateway.resolveTrackCoverGroupKeys, <String?>[null, null]);
    },
  );

  test(
    'folder detail candidates keep the selected cover without repeating its content',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cover_cache_selected_candidate_',
      );
      final portableDirectory = await Directory.systemTemp.createTemp(
        'cover_cache_selected_portable_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
        if (await portableDirectory.exists()) {
          await portableDirectory.delete(recursive: true);
        }
      });
      final discoveredCover = File(
        '${directory.path}${Platform.pathSeparator}embedded.jpg',
      );
      final selectedCover = File(
        '${portableDirectory.path}${Platform.pathSeparator}persisted.png',
      );
      await discoveredCover.writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);
      await selectedCover.writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);
      final cache = CoverArtworkCacheService(libraryService: LibraryService());

      expect(
        await cache.discoverCoverCandidatesInFolder(directory.path),
        <String>[discoveredCover.path],
      );
      expect(
        await cache.discoverCoverCandidatesInFolder(
          directory.path,
          selectedCoverPath: selectedCover.path,
        ),
        <String>[selectedCover.path],
      );
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

  test(
    'manual folder cover is not overwritten by an older automatic lookup',
    () async {
      const folder = 'content://library/work';
      const automaticCover = 'content://covers/automatic.jpg';
      const manualCover = 'content://covers/manual.jpg';
      final discovery = Completer<List<CoverImageReference>>();
      final gateway = _FakeFileCachePlatformGateway(
        coversByPath: const <String, String>{},
        discoveredImages: (_) => discovery.future,
      );
      final details = _MemoryAudioDetailCacheService();
      final cache = CoverArtworkCacheService(
        libraryService: LibraryService(),
        fileCacheGateway: gateway,
        audioDetailCacheService: details,
      );

      final automaticLookup = cache.futureForFolder(folder);
      await Future<void>.delayed(Duration.zero);
      await cache.setFolderCoverSelection(
        folder,
        manualCover,
        newlySaved: true,
      );
      discovery.complete(const <CoverImageReference>[
        CoverImageReference(
          displayPath: automaticCover,
          sourcePath: automaticCover,
        ),
      ]);

      expect(await automaticLookup, manualCover);
      expect(cache.resolvedForFolder(folder), manualCover);
      expect(
        await details.loadCardCoverPath(
          AudioDetailTarget.libraryRootFolder(folder),
        ),
        manualCover,
      );
    },
  );

  test(
    'filesystem folder cover skips recursive index when a direct image exists',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'cover_direct_scan_root_',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final child = Directory('${root.path}${Platform.pathSeparator}child');
      await child.create();
      final directCover =
          '${child.path}${Platform.pathSeparator}direct-cover.jpg';
      final requests = <({String rootPath, bool recursive})>[];
      final library = LibraryService()..watchedLibraries.add(root.path);
      final cache = CoverArtworkCacheService(
        libraryService: library,
        filesystemImageScanner: (rootPath, recursive) async {
          requests.add((rootPath: rootPath, recursive: recursive));
          return !recursive && rootPath == child.path
              ? <String>[directCover]
              : const <String>[];
        },
      );

      expect(await cache.futureForFolder(child.path), directCover);
      expect(requests, <({String rootPath, bool recursive})>[
        (rootPath: child.path, recursive: false),
      ]);
    },
  );

  test(
    'filesystem folder cover builds recursive root index after a direct miss',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'cover_recursive_scan_root_',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final child = Directory('${root.path}${Platform.pathSeparator}child');
      await child.create();
      final nestedCover =
          '${child.path}${Platform.pathSeparator}nested-cover.jpg';
      final requests = <({String rootPath, bool recursive})>[];
      final library = LibraryService()..watchedLibraries.add(root.path);
      final cache = CoverArtworkCacheService(
        libraryService: library,
        filesystemImageScanner: (rootPath, recursive) async {
          requests.add((rootPath: rootPath, recursive: recursive));
          return recursive && rootPath == root.path
              ? <String>[nestedCover]
              : const <String>[];
        },
      );

      expect(await cache.futureForFolder(child.path), nestedCover);
      expect(requests, <({String rootPath, bool recursive})>[
        (rootPath: child.path, recursive: false),
        (rootPath: root.path, recursive: true),
      ]);
    },
  );

  test(
    'filesystem image discovery reuses one index per library root',
    () async {
      final root = await Directory.systemTemp.createTemp('cover_root_index_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final child = Directory('${root.path}${Platform.pathSeparator}child');
      await child.create();
      final first = File('${child.path}${Platform.pathSeparator}first.jpg');
      await first.writeAsBytes(const <int>[1]);
      final sibling = Directory('${root.path}${Platform.pathSeparator}sibling');
      await sibling.create();
      await File(
        '${sibling.path}${Platform.pathSeparator}sibling.jpg',
      ).writeAsBytes(const <int>[3]);
      final library = LibraryService()..watchedLibraries.add(root.path);
      final cache = CoverArtworkCacheService(libraryService: library);

      expect(await cache.futureForFolder(root.path), first.path);
      expect(await cache.discoverCoverCandidatesInFolder(root.path), <String>[
        first.path,
        '${sibling.path}${Platform.pathSeparator}sibling.jpg',
      ]);
      expect(await cache.discoverCoverCandidatesInFolder(child.path), <String>[
        first.path,
      ]);
      final second = File('${child.path}${Platform.pathSeparator}second.png');
      await second.writeAsBytes(const <int>[2]);

      expect(await cache.discoverCoverCandidatesInFolder(child.path), <String>[
        first.path,
      ]);

      cache.invalidateFolder(child.path);
      expect(await cache.discoverCoverCandidatesInFolder(child.path), <String>[
        first.path,
        second.path,
      ]);
    },
  );
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
    this.discoveredImages,
    this.resolveTrackCoverHandler,
  });

  final Map<String, String> coversByPath;
  final Map<String, String> videoFramesByPath;
  final Future<List<CoverImageReference>> Function(String path)?
  discoveredImages;
  final Future<String?> Function(String path, String? groupKey)?
  resolveTrackCoverHandler;
  final List<String> resolveTrackCoverPaths = <String>[];
  final List<String?> resolveTrackCoverGroupKeys = <String?>[];

  @override
  Future<String?> resolveTrackCover({
    required String path,
    String? groupKey,
    String? rootFolder,
  }) async {
    resolveTrackCoverPaths.add(path);
    resolveTrackCoverGroupKeys.add(groupKey);
    final handler = resolveTrackCoverHandler;
    if (handler != null) return handler(path, groupKey);
    return coversByPath[path];
  }

  @override
  Future<List<CoverImageReference>> discoverRootImages({
    required String path,
    String? groupKey,
    String? rootFolder,
    bool recursive = true,
  }) async => discoveredImages?.call(path) ?? const <CoverImageReference>[];

  @override
  Future<String?> resolveVideoFrame({required String path, int? modifiedAtMs}) {
    return Future<String?>.value(videoFramesByPath[path]);
  }
}

class _MemoryTestPersistenceRepository extends TestPersistenceRepository {
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
  _MemoryAudioDetailCacheService({this.persistedPathOverride})
    : super(
        repository: AudioDetailRepository(
          databaseRepository: _MemoryTestPersistenceRepository(),
        ),
      );

  final String? persistedPathOverride;

  final Map<String, String?> _cardCoverPaths = <String, String?>{};
  final Map<String, bool> _cardCoverSelections = <String, bool>{};
  final List<AudioDetailTarget> loadedTargets = <AudioDetailTarget>[];
  final List<AudioDetailTarget> savedTargets = <AudioDetailTarget>[];

  String _key(AudioDetailTarget target) =>
      '${target.targetType.dbValue}|${PathMatcher.normalize(target.targetPath)}';

  void seedCardCover(
    AudioDetailTarget target,
    String path, {
    required bool selected,
  }) {
    final key = _key(target);
    _cardCoverPaths[key] = path;
    _cardCoverSelections[key] = selected;
  }

  @override
  Future<String?> loadCardCoverPath(AudioDetailTarget target) async {
    return _cardCoverPaths[_key(target)];
  }

  @override
  Future<({String? path, bool selected})> loadCardCoverSelection(
    AudioDetailTarget target,
  ) async {
    loadedTargets.add(target);
    final key = _key(target);
    return (
      path: _cardCoverPaths[key],
      selected: _cardCoverSelections[key] ?? false,
    );
  }

  @override
  Future<String?> saveCardCoverPath(
    AudioDetailTarget target,
    String? coverPath, {
    bool? selected,
  }) async {
    savedTargets.add(target);
    final key = _key(target);
    final previousPath = _cardCoverPaths[key];
    final previousSelected = _cardCoverSelections[key] ?? false;
    final persistedPath = coverPath == null
        ? null
        : persistedPathOverride ?? coverPath;
    _cardCoverPaths[key] = persistedPath;
    _cardCoverSelections[key] =
        persistedPath != null &&
        (selected ?? (previousPath == coverPath && previousSelected));
    return persistedPath;
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
