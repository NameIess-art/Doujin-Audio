import 'package:flutter/painting.dart';
import 'package:mime/mime.dart';

import '../../player/application/audio_state_services.dart';

const int maxCoverFileBytes = 8 * 1024 * 1024;
const Set<String> supportedCoverMimeTypes = <String>{
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
  'image/bmp',
  'image/avif',
  'image/heic',
  'image/heif',
};

String? detectCoverMimeType(String filePath, List<int> headerBytes) {
  final detected = lookupMimeType(
    filePath,
    headerBytes: headerBytes,
  )?.toLowerCase();
  return supportedCoverMimeTypes.contains(detected) ? detected : null;
}

String extensionForCoverMimeType(String mimeType) {
  return switch (mimeType.toLowerCase()) {
    'image/jpeg' => 'jpg',
    'image/png' => 'png',
    'image/webp' => 'webp',
    'image/gif' => 'gif',
    'image/bmp' => 'bmp',
    'image/avif' => 'avif',
    'image/heic' || 'image/heif' => 'heic',
    _ => 'image',
  };
}

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
    clear: true,
  );
  cache.clearLiveImages();
}
