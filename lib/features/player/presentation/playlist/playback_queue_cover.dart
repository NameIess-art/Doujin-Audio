import '../../../library/presentation/library_providers.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/widgets/async_cover_image.dart';

class QueueTrackCover extends ConsumerStatefulWidget {
  const QueueTrackCover({
    super.key,
    required this.track,
    required this.coverPath,
    required this.coverCacheWidth,
    this.future,
  });

  final MusicTrack track;
  final String? coverPath;
  final int? coverCacheWidth;
  final Future<String?>? future;

  @override
  ConsumerState<QueueTrackCover> createState() => QueueTrackCoverState();
}

class QueueTrackCoverState extends ConsumerState<QueueTrackCover> {
  Future<String?>? _future;
  String? _trackPath;
  int _coverGeneration = -1;

  @override
  Widget build(BuildContext context) {
    final library = ref.read(libraryFacadeProvider);
    final coverGeneration = ref.watch(coverGenerationProvider);
    if (widget.future != null) {
      _future = widget.future;
    } else if (_future == null ||
        _trackPath != widget.track.path ||
        _coverGeneration != coverGeneration) {
      _future = library.playbackCoverPathFutureForTrack(widget.track);
    }
    _trackPath = widget.track.path;
    _coverGeneration = coverGeneration;
    return AsyncLocalCoverImage(
      onImageError: library.coverArtworkCacheService.reportArtworkReadFailure,
      future: _future!,
      requestKey: widget.track.path,
      initialPath: widget.coverPath,
      cacheWidth: widget.coverCacheWidth,
      useDefaultCacheWidth: widget.coverCacheWidth != null,
      fit: BoxFit.cover,
    );
  }
}
