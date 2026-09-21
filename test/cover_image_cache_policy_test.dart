import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';
import 'package:doujin_audio/features/library/application/cover_image_cache_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('cover image cache budgets follow selected resolution', () {
    expect(
      coverImageCacheBudgetForResolution(
        CoverImageResolution.memorySaver,
      ).maximumSizeBytes,
      32 * 1024 * 1024,
    );
    expect(
      coverImageCacheBudgetForResolution(
        CoverImageResolution.balanced,
      ).maximumSize,
      200,
    );
    expect(
      coverImageCacheBudgetForResolution(
        CoverImageResolution.high,
      ).maximumSizeBytes,
      96 * 1024 * 1024,
    );
    expect(
      coverImageCacheBudgetForResolution(
        CoverImageResolution.ultraHigh,
      ).maximumSize,
      120,
    );
    expect(
      coverImageCacheBudgetForResolution(
        CoverImageResolution.original,
      ).maximumSize,
      80,
    );
  });

  test('applyCoverImageCachePolicy updates an ImageCache instance', () {
    final cache = ImageCache();

    applyCoverImageCachePolicy(
      CoverImageResolution.memorySaver,
      imageCache: cache,
    );

    expect(cache.maximumSize, 120);
    expect(cache.maximumSizeBytes, 32 * 1024 * 1024);
  });

  test(
    'background compaction retains cached covers within its budget',
    () async {
      final cache = ImageCache()
        ..maximumSize = 500
        ..maximumSizeBytes = 128 * 1024 * 1024;
      final picture = ui.PictureRecorder();
      ui.Canvas(
        picture,
      ).drawColor(const ui.Color(0xFF336699), ui.BlendMode.src);
      final image = await picture.endRecording().toImage(2, 2);
      final completer = cache.putIfAbsent(
        'cover',
        () =>
            OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image))),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cache.currentSize, 1);

      compactCoverImageCacheForBackground(imageCache: cache);

      expect(cache.maximumSize, 120);
      expect(cache.maximumSizeBytes, 32 * 1024 * 1024);
      expect(cache.currentSize, 1);
      expect(
        cache.putIfAbsent('cover', () => throw StateError('reloaded')),
        same(completer),
      );
      cache.clear();
      cache.clearLiveImages();
    },
  );

  test('memory pressure trim clears image cache and live images', () {
    final cache = ImageCache()
      ..maximumSize = 300
      ..maximumSizeBytes = 64 * 1024 * 1024;

    trimCoverImageCacheOnMemoryPressure(imageCache: cache);

    expect(cache.currentSize, 0);
    expect(cache.currentSizeBytes, 0);
  });
}
