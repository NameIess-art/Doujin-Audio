import 'package:flutter/painting.dart';

export '../../../core/media/cover_image_format.dart';
import '../../settings/application/settings_state.dart';

class CoverImageCacheBudget {
  const CoverImageCacheBudget({
    required this.maximumSize,
    required this.maximumSizeBytes,
  });

  final int maximumSize;
  final int maximumSizeBytes;
}

CoverImageCacheBudget coverImageCacheBudgetForResolution(
  CoverImageResolution resolution,
) {
  switch (resolution) {
    case CoverImageResolution.memorySaver:
      return const CoverImageCacheBudget(
        maximumSize: 120,
        maximumSizeBytes: 32 * 1024 * 1024,
      );
    case CoverImageResolution.balanced:
      return const CoverImageCacheBudget(
        maximumSize: 200,
        maximumSizeBytes: 50 * 1024 * 1024,
      );
    case CoverImageResolution.high:
      return const CoverImageCacheBudget(
        maximumSize: 180,
        maximumSizeBytes: 96 * 1024 * 1024,
      );
    case CoverImageResolution.ultraHigh:
      return const CoverImageCacheBudget(
        maximumSize: 120,
        maximumSizeBytes: 96 * 1024 * 1024,
      );
    case CoverImageResolution.original:
      return const CoverImageCacheBudget(
        maximumSize: 80,
        maximumSizeBytes: 96 * 1024 * 1024,
      );
  }
}

void applyCoverImageCachePolicy(
  CoverImageResolution resolution, {
  ImageCache? imageCache,
  bool clear = false,
}) {
  final cache = imageCache ?? PaintingBinding.instance.imageCache;
  final budget = coverImageCacheBudgetForResolution(resolution);
  cache.maximumSizeBytes = budget.maximumSizeBytes;
  cache.maximumSize = budget.maximumSize;
  if (clear) {
    cache.clear();
  }
}

void compactCoverImageCacheForBackground({ImageCache? imageCache}) {
  final cache = imageCache ?? PaintingBinding.instance.imageCache;
  applyCoverImageCachePolicy(
    CoverImageResolution.memorySaver,
    imageCache: cache,
  );
}
