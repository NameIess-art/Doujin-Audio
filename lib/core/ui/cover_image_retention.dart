import 'dart:collection';

import 'package:flutter/painting.dart';

// Keep recently displayed covers live in Flutter's existing ImageCache while
// their cards are unmounted during navigation or list recycling.
const int _maximumRetainedCoverBytes = 256 * 1024 * 1024;
const int _maximumRetainedCovers = 1200;
final LinkedHashMap<ImageProvider<Object>, _RetainedCover> _retainedCovers =
    LinkedHashMap<ImageProvider<Object>, _RetainedCover>();
int _retainedCoverBytes = 0;

void retainCoverImage(
  ImageProvider<Object> provider,
  ImageConfiguration configuration,
) {
  final retained = _retainedCovers.remove(provider);
  if (retained != null) {
    _retainedCovers[provider] = retained;
    return;
  }

  final stream = provider.resolve(configuration);
  late final _RetainedCover cover;
  cover = _RetainedCover(
    stream,
    ImageStreamListener((info, _) {
      if (!identical(_retainedCovers[provider], cover)) return;
      _retainedCoverBytes -= cover.bytes;
      cover.bytes = info.image.width * info.image.height * 4;
      _retainedCoverBytes += cover.bytes;
      _trimRetainedCovers();
    }, onError: (_, _) => _removeRetainedCover(provider)),
  );
  _retainedCovers[provider] = cover;
  stream.addListener(cover.listener);
  _trimRetainedCovers();
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
  cover.stream.removeListener(cover.listener);
}

final class _RetainedCover {
  _RetainedCover(this.stream, this.listener);

  final ImageStream stream;
  final ImageStreamListener listener;
  int bytes = 0;
}
