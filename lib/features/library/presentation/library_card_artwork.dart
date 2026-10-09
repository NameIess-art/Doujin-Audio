import 'library_providers.dart';
import '../../settings/presentation/settings_providers.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_styles.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/widgets/rj_code_overlay.dart';
import '../../settings/application/settings_state.dart';
import '../../../core/ui/visual_settings_providers.dart';
import 'library_cover_ui_controller.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/duration_overlay.dart';

import 'library_tab_tree_widgets.dart';

Future<String?> deferLibraryCardCoverLookup({
  required bool Function() isMounted,
  required Future<String?> Function() lookup,
}) {
  final completer = Completer<String?>();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!isMounted()) {
      completer.complete(null);
      return;
    }
    unawaited(
      lookup().then(completer.complete, onError: completer.completeError),
    );
  });
  return completer.future;
}

class LibraryCoverThumbnail extends ConsumerStatefulWidget {
  const LibraryCoverThumbnail({
    super.key,
    required this.folderPath,
    this.width = 82,
    this.duration,
  });

  final String folderPath;
  final double width;
  final Duration? duration;

  @override
  ConsumerState<LibraryCoverThumbnail> createState() =>
      _LibraryCoverThumbnailState();
}

class _LibraryCoverThumbnailState extends ConsumerState<LibraryCoverThumbnail> {
  Future<String?>? _coverPathFuture;
  String? _lastFolderPath;
  Object? _lastCoverRevision;

  Future<String?> _coverFutureFor(
    LibraryCoverUiController coverUi,
    Object coverRevision,
  ) {
    if (_lastFolderPath != widget.folderPath ||
        _lastCoverRevision != coverRevision) {
      _lastFolderPath = widget.folderPath;
      _lastCoverRevision = coverRevision;
      _coverPathFuture =
          ref
              .read(libraryFacadeProvider)
              .coverArtworkCacheService
              .cachedFutureForFolder(widget.folderPath) ??
          deferLibraryCardCoverLookup(
            isMounted: () => mounted,
            lookup: () => coverUi.deferredFolderCover(
              widget.folderPath,
              context: context,
            ),
          );
    }
    return _coverPathFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final libraryFacade = ref.read(libraryFacadeProvider);
    final coverRevision = ref.watch(
      coverGenerationProvider.select(
        (_) => libraryFacade.coverArtworkCacheService.revisionForScope(
          widget.folderPath,
        ),
      ),
    );
    final resolution = ref.watch(coverImageResolutionProvider);
    final coverUi = ref.read(libraryCoverUiControllerProvider);
    final coverPathFuture = _coverFutureFor(coverUi, coverRevision);
    final width = widget.width;
    final height = width / kStandardCoverAspectRatio;
    final coverCacheWidth = coverCacheWidthForResolution(resolution);
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          SizedBox(
            width: width,
            height: height,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                LibraryLikeCardMetrics.coverRadius,
              ),
              child: AsyncLocalCoverImage(
                deferLoadDuringInteraction: true,
                onImageError: libraryFacade
                    .coverArtworkCacheService
                    .reportArtworkReadFailure,
                future: coverPathFuture,
                requestKey: widget.folderPath,
                initialPath: libraryFacade.resolvedCoverPathForFolder(
                  widget.folderPath,
                ),
                retryFutureBuilder: () => coverUi.deferredFolderCover(
                  widget.folderPath,
                  context: context,
                ),
                cacheWidth: coverCacheWidth,
                useDefaultCacheWidth: false,
                fit: BoxFit.cover,
              ),
            ),
          ),
          if (widget.duration != null && widget.duration! > Duration.zero)
            Positioned(
              right: 4,
              bottom: 4,
              child: DurationOverlay(duration: widget.duration!),
            ),
        ],
      ),
    );
  }
}

class LibraryTrackCoverThumbnail extends ConsumerStatefulWidget {
  const LibraryTrackCoverThumbnail({
    super.key,
    required this.track,
    this.width = 82,
    this.duration,
  });

  final MusicTrack track;
  final double width;
  final Duration? duration;

  @override
  ConsumerState<LibraryTrackCoverThumbnail> createState() =>
      _LibraryTrackCoverThumbnailState();
}

class _LibraryTrackCoverThumbnailState
    extends ConsumerState<LibraryTrackCoverThumbnail> {
  Future<String?>? _coverPathFuture;
  String? _lastTrackPath;
  Object? _lastCoverRevision;

  Future<String?> _coverFutureFor(
    LibraryCoverUiController coverUi,
    Object coverRevision,
  ) {
    if (_lastTrackPath != widget.track.path ||
        _lastCoverRevision != coverRevision) {
      _lastTrackPath = widget.track.path;
      _lastCoverRevision = coverRevision;
      _coverPathFuture =
          ref
              .read(libraryFacadeProvider)
              .coverArtworkCacheService
              .cachedFutureForTrack(widget.track) ??
          deferLibraryCardCoverLookup(
            isMounted: () => mounted,
            lookup: () =>
                coverUi.deferredTrackCover(widget.track, context: context),
          );
    }
    return _coverPathFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final libraryFacade = ref.read(libraryFacadeProvider);
    final cache = libraryFacade.coverArtworkCacheService;
    final coverRevision = ref.watch(
      coverGenerationProvider.select(
        (_) => cache.revisionForScope(
          cache.coverSearchKeyForTrack(widget.track) ?? widget.track.path,
        ),
      ),
    );
    final resolution = ref.watch(coverImageResolutionProvider);
    final coverUi = ref.read(libraryCoverUiControllerProvider);
    final coverPathFuture = _coverFutureFor(coverUi, coverRevision);
    final track = widget.track;

    final width = widget.width;
    final height = width / kStandardCoverAspectRatio;
    final coverCacheWidth = coverCacheWidthForResolution(resolution);
    return Stack(
      children: [
        SizedBox(
          width: width,
          height: height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              LibraryLikeCardMetrics.coverRadius,
            ),
            child: AsyncLocalCoverImage(
              deferLoadDuringInteraction: true,
              onImageError: libraryFacade
                  .coverArtworkCacheService
                  .reportArtworkReadFailure,
              future: coverPathFuture,
              requestKey: track.path,
              initialPath: libraryFacade.resolvedCoverPathForTrack(track),
              retryFutureBuilder: () =>
                  coverUi.deferredTrackCover(track, context: context),
              cacheWidth: coverCacheWidth,
              useDefaultCacheWidth: false,
              fit: BoxFit.cover,
            ),
          ),
        ),
        if (widget.duration != null && widget.duration! > Duration.zero)
          Positioned(
            right: 4,
            bottom: 4,
            child: DurationOverlay(duration: widget.duration!),
          ),
      ],
    );
  }
}

class RootFolderCardContent extends ConsumerWidget {
  const RootFolderCardContent({
    super.key,
    required this.folderPath,
    required this.folderName,
    required this.folderDuration,
    required this.detail,
    required this.detailLoading,
    this.isSelected = false,
    this.isPinned = false,
    this.index,
    this.trailingActions,
  });

  final String folderPath;
  final String folderName;
  final Duration folderDuration;
  final AudioDetail? detail;
  final bool detailLoading;
  final bool isSelected;
  final bool isPinned;
  final int? index;
  final Widget? trailingActions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displayMode = ref.watch(
      settingsStateProvider.select(
        (state) => state.value?.workNameDisplay ?? WorkNameDisplay.workTitle,
      ),
    );
    final workTitle = detail?.workTitle.trim() ?? '';
    return AudioDetailWorkCardContent(
      title: displayMode == WorkNameDisplay.workTitle && workTitle.isNotEmpty
          ? workTitle
          : folderName,
      detail: detail,
      detailLoading: detailLoading,
      index: index,
      trailingActions: trailingActions,
      coverBuilder: (coverWidth) {
        final rj = detail?.rjCode.trim() ?? '';
        final rjCode = rj.isNotEmpty
            ? rj
            : (AudioDetail.findRjCodeInText(folderName) ??
                  AudioDetail.findRjCodeInText(folderPath) ??
                  '');
        return Stack(
          clipBehavior: Clip.none,
          children: [
            LibraryCoverThumbnail(
              folderPath: folderPath,
              width: coverWidth,
              duration: detail?.duration ?? folderDuration,
            ),
            if (rjCode.isNotEmpty)
              Positioned(
                left: 4,
                top: 4,
                child: RjCodeOverlay(
                  rjCode: rjCode,
                  maxWidth: isPinned ? (coverWidth - 32) : (coverWidth - 8),
                ),
              ),
            Positioned(
              left: -2,
              bottom: -2,
              child: LibrarySelectionIndicator(
                path: folderPath,
                isSelected: isSelected,
              ),
            ),
            Positioned(
              right: -2,
              top: -2,
              child: LibraryPinnedIndicator(
                isPinned: isPinned,
                path: folderPath,
                isSelected: isSelected,
              ),
            ),
          ],
        );
      },
    );
  }
}

class AudioDetailWorkCardContent extends ConsumerWidget {
  const AudioDetailWorkCardContent({
    super.key,
    required this.title,
    required this.detail,
    required this.detailLoading,
    required this.coverBuilder,
    this.index,
    this.trailingActions,
  });

  final String title;
  final AudioDetail? detail;
  final bool detailLoading;
  final Widget Function(double coverWidth) coverBuilder;
  final int? index;
  final Widget? trailingActions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return LibraryLikeMetadataWorkCardContent(
      title: title,
      metadata: _audioDetailMetadata(detail),
      voiceActorLabel: i18n.tr('card_info_voice_actors'),
      circleLabel: i18n.tr('library_category_circles'),
      tagsLabel: i18n.tr('library_category_tags'),
      releaseDateLabel: i18n.tr('card_info_release_date'),
      ratingLabel: i18n.tr('card_info_rating'),
      loading: detailLoading || detail == null,
      trailingActions: trailingActions,
      coverBuilder: coverBuilder,
    );
  }
}

class SingleAudioFileCardContent extends ConsumerWidget {
  const SingleAudioFileCardContent({
    super.key,
    required this.title,
    required this.path,
    this.isPinned = false,
    this.isSelected = false,
    required this.detail,
    required this.detailLoading,
    this.trailingActions,
  });

  final String title;
  final String path;
  final bool isPinned;
  final bool isSelected;
  final AudioDetail? detail;
  final bool detailLoading;
  final Widget? trailingActions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final lines = (detailLoading || detail == null)
        ? const <LibraryLikeInfoLineData>[]
        : buildLibraryLikeInfoLines(
            metadata: _audioDetailMetadata(detail),
            voiceActorLabel: i18n.tr('card_info_voice_actors'),
            circleLabel: i18n.tr('library_category_circles'),
            tagsLabel: i18n.tr('library_category_tags'),
            releaseDateLabel: i18n.tr('card_info_release_date'),
            ratingLabel: i18n.tr('card_info_rating'),
          );
    // The text content bounds the selection overlay inside lazy lists.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        LibraryLikeSingleAudioCardContent(
          title: title,
          lines: lines,
          trailingActions: trailingActions,
          titleLeading: Padding(
            padding: EdgeInsets.only(right: isPinned ? AppSpacing.xs : 0),
            child: SizedBox(
              width: isPinned ? 22 : 0,
              height: LibraryLikeCardMetrics.contentHeight / 5,
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: 22,
                maxWidth: 22,
                minHeight: 22,
                maxHeight: 22,
                child: LibraryPinnedIndicator(
                  path: path,
                  isPinned: isPinned,
                  isSelected: isSelected,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: -2,
          bottom: -2,
          child: LibrarySelectionIndicator(path: path, isSelected: isSelected),
        ),
      ],
    );
  }
}

class SingleMediaFileCardContent extends StatelessWidget {
  const SingleMediaFileCardContent({
    super.key,
    required this.track,
    required this.title,
    required this.detail,
    required this.detailLoading,
    this.isSelected = false,
    this.isPinned = false,
    this.index,
    this.trailingActions,
  });

  final MusicTrack track;
  final String title;
  final AudioDetail? detail;
  final bool detailLoading;
  final bool isSelected;
  final bool isPinned;
  final int? index;
  final Widget? trailingActions;

  @override
  Widget build(BuildContext context) {
    return AudioDetailWorkCardContent(
      title: title,
      detail: detail,
      detailLoading: detailLoading,
      index: index,
      trailingActions: trailingActions,
      coverBuilder: (coverWidth) {
        final rj = detail?.rjCode.trim() ?? '';
        final rjCode = rj.isNotEmpty
            ? rj
            : (AudioDetail.findRjCodeInText(title) ??
                  AudioDetail.findRjCodeInText(track.path) ??
                  '');
        return Stack(
          clipBehavior: Clip.none,
          children: [
            LibraryTrackCoverThumbnail(
              track: track,
              width: coverWidth,
              duration: detail?.duration ?? track.duration,
            ),
            if (rjCode.isNotEmpty)
              Positioned(
                left: 4,
                top: 4,
                child: RjCodeOverlay(
                  rjCode: rjCode,
                  maxWidth: isPinned ? (coverWidth - 32) : (coverWidth - 8),
                ),
              ),
            Positioned(
              left: -2,
              bottom: -2,
              child: LibrarySelectionIndicator(
                path: track.path,
                isSelected: isSelected,
              ),
            ),
            Positioned(
              right: -2,
              top: -2,
              child: LibraryPinnedIndicator(
                isPinned: isPinned,
                path: track.path,
                isSelected: isSelected,
              ),
            ),
          ],
        );
      },
    );
  }
}

LibraryLikeInfoMetadata _audioDetailMetadata(AudioDetail? detail) {
  final d = detail;
  if (d == null) return const LibraryLikeInfoMetadata();
  return LibraryLikeInfoMetadata(
    voiceActors: d.voiceActors,
    circleName: d.circleName,
    tags: d.tags,
    releaseDate: d.releaseDate,
    rating: d.rating,
  );
}
