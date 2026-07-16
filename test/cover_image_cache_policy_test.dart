import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/settings/application/settings_state.dart';
import 'package:nameless_audio/features/library/application/cover_image_cache_policy.dart';

void main() {
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

  test('background compaction switches to the memory saver budget', () {
    final cache = ImageCache()
      ..maximumSize = 500
      ..maximumSizeBytes = 128 * 1024 * 1024;

    compactCoverImageCacheForBackground(imageCache: cache);

    expect(cache.maximumSize, 120);
    expect(cache.maximumSizeBytes, 32 * 1024 * 1024);
    expect(cache.currentSize, 0);
    expect(cache.currentSizeBytes, 0);
  });
}
