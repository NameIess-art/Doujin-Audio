import 'dart:async';
import 'dart:io';

import 'package:doujin_audio/core/media/music_track.dart';

import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'remote cover revalidation shares changed bytes across playback and survives restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'remote_validation_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
        await directory.delete(recursive: true);
      });
      var now = DateTime.utc(2026, 10, 2);
      var requests = 0;
      var version = 1;
      var fail = false;
      String? conditional;
      server.listen((request) async {
        requests++;
        conditional = request.headers.value(HttpHeaders.ifNoneMatchHeader);
        if (fail) {
          request.response.statusCode = HttpStatus.serviceUnavailable;
        } else if (conditional == '"$version"') {
          request.response.statusCode = HttpStatus.notModified;
        } else {
          request.response.headers.set(HttpHeaders.etagHeader, '"$version"');
          request.response.add([
            0x89,
            0x50,
            0x4e,
            0x47,
            0x0d,
            0x0a,
            0x1a,
            0x0a,
            version,
          ]);
        }
        await request.response.close();
      });
      final url = 'http://${server.address.address}:${server.port}/cover.png';
      final library = LibraryService();
      final cache = CoverArtworkCacheService(
        libraryService: library,
        persistentDirectory: () async => directory,
        now: () => now,
      );
      addTearDown(library.dispose);
      addTearDown(cache.dispose);
      final track = MusicTrack(
        path: 'https://example.com/stream',
        displayName: 'work',
        groupKey: 'remote',
        groupTitle: 'work',
        groupSubtitle: '',
        isSingle: false,
        remoteCoverUrl: url,
      );
      final first = await cache.futureForRemoteCover(url);
      final playback = cache.futureForPlaybackTrack(track);
      var synchronous = false;
      unawaited(playback.then<void>((_) => synchronous = true));
      expect(synchronous, isTrue);
      expect(await playback, first);
      expect(requests, 1);
      now = now.add(const Duration(hours: 25));
      expect(await cache.futureForRemoteCover(url), first);
      await cache.refreshRemoteCover(url);
      expect(requests, 2);
      expect(conditional, '"1"');
      expect(cache.generation, 0);
      version = 2;
      final second = await cache.refreshRemoteCover(url, force: true);
      expect(second, isNot(first));
      expect(cache.generation, 1);
      expect(cache.resolvedForPlaybackTrack(track), second);
      expect(await cache.futureForPlaybackTrack(track), second);
      final restarted = CoverArtworkCacheService(
        libraryService: library,
        persistentDirectory: () async => directory,
        now: () => now,
      );
      addTearDown(restarted.dispose);
      await restarted.initialize();
      expect(restarted.resolvedForPlaybackTrack(track), second);
      expect(await restarted.futureForRemoteCover(url), second);
      expect(requests, 3);
      fail = true;
      expect(await cache.refreshRemoteCover(url, force: true), second);
      expect(cache.resolvedForRemoteCover(url), second);
      expect(cache.generation, 1);
      final failedRequestCount = requests;
      now = now.add(const Duration(minutes: 10));
      expect(await cache.refreshRemoteCover(url), second);
      expect(requests, failedRequestCount);
      final offlineRestart = CoverArtworkCacheService(
        libraryService: library,
        persistentDirectory: () async => directory,
        now: () => now,
      );
      addTearDown(offlineRestart.dispose);
      await offlineRestart.initialize();
      expect(await offlineRestart.futureForRemoteCover(url), second);
      await offlineRestart.refreshRemoteCover(url);
      expect(requests, failedRequestCount);
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
