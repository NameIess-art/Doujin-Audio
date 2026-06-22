import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/music_track.dart';
import 'package:nameless_audio/services/audio_state_services.dart';
import 'package:nameless_audio/services/cover_artwork_cache_service.dart';

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

  test('manual cover is returned before scanning the folder', () {
    final library = LibraryService();
    library.watchedFolders.add('/library');
    library.library.add(
      _track(
        path: '/library/work/track.mp3',
        groupKey: '/library/work',
        manualCoverPath: '/covers/manual.jpg',
      ),
    );
    final cache = CoverArtworkCacheService(libraryService: library);

    expect(cache.resolvedForFolder('/library'), '/covers/manual.jpg');
    expect(
      cache.resolvedForTrack(library.library.single),
      '/covers/manual.jpg',
    );
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
