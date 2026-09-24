import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final cache = ImageCache();
      applyCoverImageCachePolicy(
        CoverImageResolution.memorySaver,
        imageCache: cache,
      );
      expect(cache.maximumSize, 120);
      expect(cache.maximumSizeBytes, 32 * 1024 * 1024);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('Windows keeps more decoded covers across page changes', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final cache = ImageCache();
      applyCoverImageCachePolicy(
        CoverImageResolution.balanced,
        imageCache: cache,
      );
      expect(cache.maximumSize, 1200);
      expect(cache.maximumSizeBytes, 256 * 1024 * 1024);

      applyCoverImageCachePolicy(
        CoverImageResolution.memorySaver,
        imageCache: cache,
      );
      expect(cache.maximumSize, 120);
      expect(cache.maximumSizeBytes, 32 * 1024 * 1024);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test(
    'memory pressure releases idle covers but preserves mounted images',
    () async {
      final cache = ImageCache();
      final picture = ui.PictureRecorder();
      ui.Canvas(
        picture,
      ).drawColor(const ui.Color(0xFF336699), ui.BlendMode.src);
      final image = await picture.endRecording().toImage(2, 2);
      final completer = cache.putIfAbsent(
        'cover',
        () =>
            OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image))),
      )!;
      final listener = ImageStreamListener((_, _) {});
      completer.addListener(listener);
      await Future<void>.delayed(Duration.zero);
      trimCoverImageCacheOnMemoryPressure(imageCache: cache);
      expect(cache.currentSize, 0);
      expect(cache.liveImageCount, 1);
      expect(
        cache.putIfAbsent('cover', () => throw StateError('reloaded')),
        same(completer),
      );
      completer.removeListener(listener);
      cache.clear();
      cache.clearLiveImages();
    },
  );
}
