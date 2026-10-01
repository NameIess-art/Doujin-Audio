import 'library_providers.dart';
import '../../settings/presentation/settings_providers.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  int _lastCoverGeneration = -1;

  Future<String?> _coverFutureFor(
    LibraryCoverUiController coverUi,
    int coverGeneration,
  ) {
    if (_lastFolderPath != widget.folderPath ||
        _lastCoverGeneration != coverGeneration) {
      _lastFolderPath = widget.folderPath;
      _lastCoverGeneration = coverGeneration;
      _coverPathFuture = deferLibraryCardCoverLookup(
        isMounted: () => mounted,
        lookup: () =>
            coverUi.deferredFolderCover(widget.folderPath, context: context),
      );
    }
    return _coverPathFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final coverGeneration = ref.watch(coverGenerationProvider);
    final resolution = ref.watch(coverImageResolutionProvider);
    final libraryFacade = ref.read(libraryFacadeProvider);
    final coverUi = ref.read(libraryCoverUiControllerProvider);
    final coverPathFuture = _coverFutureFor(coverUi, coverGeneration);
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
                future: coverPathFuture,
                requestKey: widget.folderPath,
                initialPath: libraryFacade.resolvedCoverPathForFolder(
                  widget.folderPath,
                ),
                retryFutureBuilder: () => coverUi.deferredFolderCover(
                  widget.folderPath,
                  context: context,
                ),
                seed: widget.folderPath,
                cacheWidth: coverCacheWidth,
                useDefaultCacheWidth: false,
                fit: BoxFit.cover,
                compact: true,
                iconSize: 28,
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
  int _lastCoverGeneration = -1;

  Future<String?> _coverFutureFor(
    LibraryCoverUiController coverUi,
    int coverGeneration,
  ) {
    if (_lastTrackPath != widget.track.path ||
        _lastCoverGeneration != coverGeneration) {
      _lastTrackPath = widget.track.path;
      _lastCoverGeneration = coverGeneration;
      _coverPathFuture = deferLibraryCardCoverLookup(
        isMounted: () => mounted,
        lookup: () =>
            coverUi.deferredTrackCover(widget.track, context: context),
      );
    }
    return _coverPathFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final coverGeneration = ref.watch(coverGenerationProvider);
    final resolution = ref.watch(coverImageResolutionProvider);
    final libraryFacade = ref.read(libraryFacadeProvider);
    final coverUi = ref.read(libraryCoverUiControllerProvider);
    final coverPathFuture = _coverFutureFor(coverUi, coverGeneration);
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
              future: coverPathFuture,
              requestKey: track.path,
              initialPath: libraryFacade.resolvedCoverPathForTrack(track),
              retryFutureBuilder: () =>
                  coverUi.deferredTrackCover(track, context: context),
              seed: track.displayName,
              cacheWidth: coverCacheWidth,
              useDefaultCacheWidth: false,
              fit: BoxFit.cover,
              compact: true,
              iconSize: 28,
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
    required this.expanded,
    required this.hasChildren,
    required this.onPlay,
    this.isSelected = false,
    this.isPinned = false,
    this.index,
  });

  final String folderPath;
  final String folderName;
  final Duration folderDuration;
  final AudioDetail? detail;
  final bool detailLoading;
  final bool expanded;
  final bool hasChildren;
  final VoidCallback onPlay;
  final bool isSelected;
  final bool isPinned;
  final int? index;

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
      expanded: expanded,
      showExpandIndicator: hasChildren,
      onPlay: onPlay,
      index: index,
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
            if (isSelected)
              const Positioned(
                left: 4,
                bottom: 4,
                child: LibrarySelectionIndicator(),
              ),
            if (isPinned)
              Positioned(
                right: 4,
                top: 4,
                child: LibraryPinnedIndicator(path: folderPath),
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
    required this.onPlay,
    this.expanded = false,
    this.showExpandIndicator = false,
    this.index,
  });

  final String title;
  final AudioDetail? detail;
  final bool detailLoading;
  final Widget Function(double coverWidth) coverBuilder;
  final VoidCallback onPlay;
  final bool expanded;
  final bool showExpandIndicator;
  final int? index;

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
      coverBuilder: coverBuilder,
      onPlay: onPlay,
      expanded: expanded,
      showExpandIndicator: showExpandIndicator,
      playTooltip: i18n.tr('play'),
      enableMarquee: false,
      enableTitleMarquee: false,
    );
  }
}

class SingleAudioFileCardContent extends ConsumerWidget {
  const SingleAudioFileCardContent({
    super.key,
    required this.title,
    required this.detail,
    required this.detailLoading,
  });

  final String title;
  final AudioDetail? detail;
  final bool detailLoading;

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
    return LibraryLikeSingleAudioCardContent(
      title: title,
      lines: lines,
      enableMarquee: false,
      enableTitleMarquee: false,
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
    required this.onPlay,
    this.isSelected = false,
    this.isPinned = false,
    this.index,
  });

  final MusicTrack track;
  final String title;
  final AudioDetail? detail;
  final bool detailLoading;
  final VoidCallback onPlay;
  final bool isSelected;
  final bool isPinned;
  final int? index;

  @override
  Widget build(BuildContext context) {
    return AudioDetailWorkCardContent(
      title: title,
      detail: detail,
      detailLoading: detailLoading,
      onPlay: onPlay,
      index: index,
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
            if (isSelected)
              const Positioned(
                left: 4,
                bottom: 4,
                child: LibrarySelectionIndicator(),
              ),
            if (isPinned)
              Positioned(
                right: 4,
                top: 4,
                child: LibraryPinnedIndicator(path: track.path),
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
