import 'dart:async';
import 'dart:collection';

import 'package:flutter/painting.dart';

// Keep recent completers without a live listener: hidden animated covers must
// stop decoding, while recycled cards can still reuse the same decoded image.
int _maximumRetainedCoverBytes = 50 * 1024 * 1024;
int _maximumRetainedCovers = 200;
final LinkedHashMap<ImageProvider<Object>, _RetainedCover> _retainedCovers =
    LinkedHashMap<ImageProvider<Object>, _RetainedCover>();
int _retainedCoverBytes = 0;

void configureRetainedCoverBudget({
  required int maximumSize,
  required int maximumSizeBytes,
}) {
  _maximumRetainedCovers = maximumSize;
  _maximumRetainedCoverBytes = maximumSizeBytes;
  _trimRetainedCovers();
}

void retainCoverImage(
  ImageProvider<Object> provider,
  ImageConfiguration configuration,
) {
  final retained = _retainedCovers.remove(provider);
  if (retained != null) {
    _retainedCovers[provider] = retained;
    return;
  }

  final cover = _RetainedCover();
  _retainedCovers[provider] = cover;
  _trimRetainedCovers();
  unawaited(
    provider
        .obtainKey(configuration)
        .then<void>(
          (key) {
            if (!identical(_retainedCovers[provider], cover)) return;
            cover.key = key;
            final stream = provider.resolve(configuration);
            cover.stream = stream;
            cover.listener = ImageStreamListener(
              (info, _) {
                try {
                  if (!identical(_retainedCovers[provider], cover)) return;
                  cover.handle = stream.completer!.keepAlive();
                  cover.bytes = info.sizeBytes;
                  _retainedCoverBytes += cover.bytes;
                  _trimRetainedCovers();
                } finally {
                  info.dispose();
                  cover.stopListening();
                }
              },
              onError: (_, _) {
                if (identical(_retainedCovers[provider], cover)) {
                  _removeRetainedCover(provider);
                }
              },
            );
            stream.addListener(cover.listener!);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (identical(_retainedCovers[provider], cover)) {
              _removeRetainedCover(provider);
            }
          },
        ),
  );
}

void restoreRetainedCoverImage(ImageProvider<Object> provider) {
  final cover = _retainedCovers[provider];
  if (cover?.handle == null) return;
  // ImageCache's live index disappears when its last listener is removed. Put
  // the retained completer back under the original key before Image resolves.
  PaintingBinding.instance.imageCache.putIfAbsent(
    cover!.key!,
    () => cover.stream!.completer!,
  );
}

void releaseRetainedCoverImages() {
  for (final provider in _retainedCovers.keys.toList(growable: false)) {
    _removeRetainedCover(provider);
  }
}

void releaseRetainedCoverImage(ImageProvider<Object> provider) {
  _removeRetainedCover(provider);
}

void _trimRetainedCovers() {
  while (_retainedCovers.length > _maximumRetainedCovers ||
      _retainedCoverBytes > _maximumRetainedCoverBytes) {
    _removeRetainedCover(_retainedCovers.keys.first);
  }
}

void _removeRetainedCover(ImageProvider<Object> provider) {
  final cover = _retainedCovers.remove(provider);
  if (cover == null) return;
  _retainedCoverBytes -= cover.bytes;
  cover.stopListening();
  cover.handle?.dispose();
}

final class _RetainedCover {
  Object? key;
  ImageStream? stream;
  ImageStreamListener? listener;
  ImageStreamCompleterHandle? handle;
  int bytes = 0;

  void stopListening() {
    final current = listener;
    if (current == null) return;
    listener = null;
    stream!.removeListener(current);
  }
}
