import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late HttpServer server;
  late LibraryService library;
  late DateTime now;
  late int requests;
  late List<CoverArtworkCacheService> caches;
  Future<void> Function(HttpRequest request)? respond;
  final pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('持久封面 cache ');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    library = LibraryService();
    now = DateTime.utc(2026, 10, 2);
    requests = 0;
    caches = [];
    respond = null;
    server.listen((request) async {
      requests++;
      if (respond != null) {
        await respond!(request);
      } else {
        request.response.add(pngBytes);
        await request.response.close();
      }
    });
  });

  tearDown(() async {
    for (final cache in caches) {
      await cache.dispose();
    }
    await library.dispose();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  CoverArtworkCacheService createCache() {
    final cache = CoverArtworkCacheService(
      libraryService: library,
      persistentDirectory: () async => directory,
      now: () => now,
    );
    caches.add(cache);
    return cache;
  }

  String url(String name) =>
      'http://${server.address.address}:${server.port}/$name.png';

  test(
    'remote artwork remains durable without requests after aging or offline restart',
    () async {
      final coverUrl = url('cover');
      final cache = createCache();
      final track = MusicTrack(
        path: 'https://example.com/stream',
        displayName: 'work',
        groupKey: 'remote',
        groupTitle: 'work',
        groupSubtitle: '',
        isSingle: false,
        remoteCoverUrl: coverUrl,
      );
      final pending = cache.futureForRemoteCover(coverUrl);
      expect(identical(cache.futureForRemoteCover(coverUrl), pending), isTrue);
      final first = await pending;
      expect(first, isNotNull);
      expect(await File(first!).readAsBytes(), pngBytes);
      final playback = cache.futureForPlaybackTrack(track);
      var synchronous = false;
      unawaited(playback.then<void>((_) => synchronous = true));
      expect(synchronous, isTrue);
      expect(await playback, first);
      expect(requests, 1);
      now = now.add(const Duration(hours: 25));
      expect(await cache.futureForRemoteCover(coverUrl), first);
      now = now.add(const Duration(days: 365));
      expect(await cache.futureForRemoteCover(coverUrl), first);
      await Future<void>.delayed(Duration.zero);
      expect(requests, 1);
      expect(cache.generation, 0);

      await cache.dispose();
      final restarted = createCache();
      await restarted.initialize();
      expect(restarted.resolvedForPlaybackTrack(track), first);
      expect(await restarted.futureForRemoteCover(coverUrl), first);
      await Future<void>.delayed(Duration.zero);
      expect(requests, 1);

      await restarted.dispose();
      await server.close(force: true);
      final offlineRestart = createCache();
      await offlineRestart.initialize();
      expect(await offlineRestart.futureForRemoteCover(coverUrl), first);
      expect(await offlineRestart.futureForPlaybackTrack(track), first);
      offlineRestart.trimMemory();
      expect(await offlineRestart.futureForRemoteCover(coverUrl), first);
      expect(await File(first).readAsBytes(), pngBytes);
      expect(requests, 1);
    },
  );

  test(
    'different URLs are fetched once and share identical durable bytes',
    () async {
      final cache = createCache();
      final first = await cache.futureForRemoteCover(url('first'));
      final second = await cache.futureForRemoteCover(url('second'));
      expect(first, isNotNull);
      expect(second, first);
      expect(requests, 2);
      expect(await cache.futureForRemoteCover(url('first')), first);
      expect(await cache.futureForRemoteCover(url('second')), second);
      expect(requests, 2);
    },
  );

  for (final missing in [false, true]) {
    test(
      '${missing ? 'missing' : 'corrupt'} remote artifact repairs at the same path and notifies',
      () async {
        final cache = createCache();
        final coverUrl = url('repair');
        final saved = await cache.futureForRemoteCover(coverUrl);
        expect(saved, isNotNull);
        if (missing) {
          await File(saved!).delete();
        } else {
          await File(saved!).writeAsString('corrupt image');
        }
        final previousGeneration = cache.generation;
        final repaired = cache.generationChanges.firstWhere(
          (generation) => generation > previousGeneration,
        );
        cache.reportArtworkReadFailure(saved);
        await repaired.timeout(const Duration(seconds: 2));
        expect(await cache.futureForRemoteCover(coverUrl), saved);
        expect(await File(saved).readAsBytes(), pngBytes);
        expect(requests, 2);
      },
    );
  }

  test(
    'explicit clearing downloads again and retires in-flight artwork',
    () async {
      final cache = createCache();
      final coverUrl = url('clear');
      final saved = await cache.futureForRemoteCover(coverUrl);
      expect(saved, isNotNull);
      expect(await cache.clearPersistentCache(), pngBytes.length);
      expect(await File(saved!).exists(), isFalse);
      expect(cache.resolvedForRemoteCover(coverUrl), isNull);
      expect(await cache.futureForRemoteCover(coverUrl), saved);
      expect(requests, 2);

      final started = Completer<void>();
      final release = Completer<void>();
      respond = (request) async {
        started.complete();
        await release.future;
        request.response.add(pngBytes);
        await request.response.close();
      };
      final pendingUrl = url('pending');
      final pending = cache.futureForRemoteCover(pendingUrl);
      await started.future.timeout(const Duration(seconds: 2));
      final generation = cache.generation;
      final retired = cache.generationChanges.firstWhere(
        (value) => value > generation,
      );
      final clearing = cache.clearPersistentCache();
      await retired.timeout(const Duration(seconds: 2));
      release.complete();
      expect(await pending, isNull);
      await clearing;
      expect(cache.resolvedForRemoteCover(pendingUrl), isNull);
      expect(
        directory
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (file) =>
                  file.path.endsWith('.image') || file.path.endsWith('.part'),
            ),
        isEmpty,
      );
      final restarted = createCache();
      await restarted.initialize();
      expect(restarted.resolvedForRemoteCover(pendingUrl), isNull);
      respond = null;
      expect(await restarted.futureForRemoteCover(pendingUrl), isNotNull);
      expect(requests, 4);
    },
  );

  test('local folder invalidation keeps an unrelated remote lookup', () async {
    const url = 'https://example.com/local-invalidation.jpg';
    final download = Completer<String?>();
    final library = LibraryService();
    final cache = CoverArtworkCacheService(
      libraryService: library,
      remoteCoverDownloader: (_) => download.future,
    );
    addTearDown(library.dispose);
    addTearDown(cache.dispose);

    final pending = cache.futureForRemoteCover(url);
    cache.invalidateFolder('/library/local');
    expect(identical(cache.futureForRemoteCover(url), pending), isTrue);
    download.complete('content://covers/remote');
    expect(await pending, 'content://covers/remote');
    expect(cache.resolvedForRemoteCover(url), 'content://covers/remote');
  });

  test('invalidated remote lookup cannot remove its replacement', () async {
    const url = 'https://example.com/cover.jpg';
    final firstDownload = Completer<String?>();
    final replacementDownload = Completer<String?>();
    var downloads = 0;
    var coverChanges = 0;
    final library = LibraryService();
    final cache = CoverArtworkCacheService(
      libraryService: library,
      remoteCoverDownloader: (_) =>
          ++downloads == 1 ? firstDownload.future : replacementDownload.future,
      isActiveCoverKey: (_) => true,
      onActiveCoverChanged: () => coverChanges++,
    );
    addTearDown(library.dispose);
    addTearDown(cache.dispose);

    final first = cache.futureForRemoteCover(url);
    cache.invalidateAll();
    final replacement = cache.futureForRemoteCover(url);
    firstDownload.complete('content://covers/old');
    expect(await first, isNull);
    expect(cache.resolvedForRemoteCover(url), isNull);
    expect(coverChanges, 0);
    expect(identical(cache.futureForRemoteCover(url), replacement), isTrue);
    expect(downloads, 2);

    replacementDownload.complete('content://covers/new');
    expect(await replacement, 'content://covers/new');
    expect(cache.resolvedForRemoteCover(url), 'content://covers/new');
    expect(coverChanges, 1);
  });

  test('disposed remote lookup cannot publish or notify', () async {
    const url = 'https://example.com/disposed.jpg';
    final download = Completer<String?>();
    var coverChanges = 0;
    final library = LibraryService();
    final cache = CoverArtworkCacheService(
      libraryService: library,
      remoteCoverDownloader: (_) => download.future,
      isActiveCoverKey: (_) => true,
      onActiveCoverChanged: () => coverChanges++,
    );
    addTearDown(library.dispose);

    final pending = cache.futureForRemoteCover(url);
    await cache.dispose();
    download.complete('content://covers/disposed');
    expect(await pending, isNull);
    expect(cache.resolvedForRemoteCover(url), isNull);
    expect(await cache.futureForRemoteCover(url), isNull);
    expect(coverChanges, 0);
  });
}
