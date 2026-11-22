import '../../../library/presentation/library_card_artwork.dart';
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
    this.folderPath,
    this.browseThumbnail = false,
    this.future,
  });

  final MusicTrack track;
  final String? coverPath;
  final int? coverCacheWidth;
  final String? folderPath;
  final bool browseThumbnail;
  final Future<String?>? future;

  @override
  ConsumerState<QueueTrackCover> createState() => QueueTrackCoverState();
}

class QueueTrackCoverState extends ConsumerState<QueueTrackCover> {
  Future<String?>? _future;
  String? _requestKey;
  Object? _coverRevision;

  @override
  Widget build(BuildContext context) {
    final library = ref.read(libraryFacadeProvider);
    final cache = library.coverArtworkCacheService;
    final folderPath = widget.folderPath;
    final requestKey = folderPath ?? widget.track.path;
    final Object coverRevision;
    if (folderPath != null) {
      coverRevision = ref.watch(
        coverGenerationProvider.select(
          (_) => cache.revisionForScope(folderPath),
        ),
      );
    } else {
      final scope = cache.coverSearchKeyForTrack(widget.track) ?? widget.track.path;
      final folderScope = cache.coverScopeFolderForTrack(widget.track);
      coverRevision = ref.watch(
        coverGenerationProvider.select(
          (_) => (
            cache.revisionForScope(scope),
            folderScope == null ? null : cache.revisionForScope(folderScope),
          ),
        ),
      );
    }
    if (widget.future != null) {
      _future = widget.future;
    } else if (_future == null ||
        _requestKey != requestKey ||
        _coverRevision != coverRevision) {
      final coverUi = ref.read(libraryCoverUiControllerProvider);
      if (folderPath != null) {
        _future =
            library.coverArtworkCacheService.cachedFutureForFolder(
              folderPath,
            ) ??
            deferLibraryCardCoverLookup(
              isMounted: () => mounted,
              lookup: () =>
                  coverUi.deferredFolderCover(folderPath, context: context),
            );
      } else if (widget.browseThumbnail) {
        _future =
            library.coverArtworkCacheService.cachedFutureForPlaybackTrack(
              widget.track,
            ) ??
            deferLibraryCardCoverLookup(
              isMounted: () => mounted,
              lookup: () =>
                  coverUi.deferredPlaybackCover(widget.track, context: context),
            );
      } else {
        _future = coverUi.deferredPlaybackCover(widget.track, context: context);
      }
    }
    _requestKey = requestKey;
    _coverRevision = coverRevision;
    return AsyncLocalCoverImage(
      onImageError: library.coverArtworkCacheService.reportArtworkReadFailure,
      future: _future!,
      requestKey: requestKey,
      initialPath: widget.coverPath,
      cacheWidth: widget.coverCacheWidth,
      useDefaultCacheWidth: widget.coverCacheWidth != null,
      browseThumbnail: widget.browseThumbnail,
      deferLoadDuringInteraction: true,
      fit: BoxFit.cover,
    );
  }
}
