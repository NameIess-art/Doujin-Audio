import 'dart:async';

import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
