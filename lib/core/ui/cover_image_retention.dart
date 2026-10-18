import 'dart:async';
import 'dart:collection';

import 'package:flutter/painting.dart';

import '../media/path_matcher.dart';

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

  final cover = _RetainedCover(sourceKey: _fileSourceKey(provider));
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
                  cover.width = info.image.width;
                  cover.height = info.image.height;
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

({ImageProvider<Object> provider, bool isAdequate})? retainedCoverImageFor(
  ImageProvider<Object> requested,
) {
  if (_retainedCovers[requested]?.handle != null) {
    return (provider: requested, isAdequate: true);
  }
  final sourceKey = _fileSourceKey(requested);
  if (sourceKey == null) return null;
  ImageProvider<Object>? selected;
  _RetainedCover? selectedCover;
  var selectedIsAdequate = false;
  for (final entry in _retainedCovers.entries) {
    final cover = entry.value;
    if (cover.handle == null) continue;
    if (cover.sourceKey != sourceKey) continue;
    final adequate =
        entry.key is FileImage ||
        (requested is ResizeImage &&
            (requested.width == null || cover.width >= requested.width!) &&
            (requested.height == null || cover.height >= requested.height!));
    // Prefer the smallest adequate decode; otherwise show the best preview.
    if (selectedCover == null ||
        (adequate && !selectedIsAdequate) ||
        (adequate == selectedIsAdequate &&
            (adequate
                ? cover.bytes < selectedCover.bytes
                : cover.bytes > selectedCover.bytes))) {
      selected = entry.key;
      selectedCover = cover;
      selectedIsAdequate = adequate;
    }
  }
  return selected == null
      ? null
      : (provider: selected, isAdequate: selectedIsAdequate);
}

FileImage? _fileSource(ImageProvider<Object> provider) {
  if (provider is FileImage) return provider;
  if (provider is ResizeImage && provider.imageProvider is FileImage) {
    return provider.imageProvider as FileImage;
  }
  return null;
}

(String, double)? _fileSourceKey(ImageProvider<Object> provider) {
  final source = _fileSource(provider);
  return source == null
      ? null
      : (PathMatcher.equivalenceKey(source.file.path), source.scale);
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
  _RetainedCover({required this.sourceKey});

  // Normalize once on retention, rather than for every candidate during scroll.
  final (String, double)? sourceKey;
  Object? key;
  ImageStream? stream;
  ImageStreamListener? listener;
  ImageStreamCompleterHandle? handle;
  int bytes = 0;
  int width = 0;
  int height = 0;

  void stopListening() {
    final current = listener;
    if (current == null) return;
    listener = null;
    stream!.removeListener(current);
  }
}
