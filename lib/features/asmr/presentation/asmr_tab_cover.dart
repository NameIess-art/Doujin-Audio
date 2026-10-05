part of 'asmr_tab.dart';

class _AsmrWorkCover extends ConsumerWidget {
  const _AsmrWorkCover({
    required this.url,
    required this.width,
    this.isSelected = false,
    this.duration,
    this.rjCode = '',
  });

  final String url;
  final double width;
  final bool isSelected;
  final Duration? duration;
  final String rjCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = this.width;
    final height = width / kStandardCoverAspectRatio;
    final url = this.url.trim();
    final coverResolution = ref.watch(coverImageResolutionProvider);
    final coverCacheWidth = coverCacheWidthForResolution(coverResolution);
    final library = ref.read(libraryFacadeProvider);
    ref.watch(
      coverGenerationProvider.select(
        (_) => library.resolvedCoverPathForRemoteCover(url),
      ),
    );
    final coverUi = ref.read(libraryCoverUiControllerProvider);
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          SizedBox(
            width: width,
            height: height,
            child: ClipRRect(
              clipBehavior: Clip.hardEdge,
              borderRadius:
                  BorderRadius.circular(LibraryLikeCardMetrics.coverRadius),
              child: Stack(
                children: [
                  SizedBox(
                    width: width,
                    height: height,
                    child: url.isEmpty
                        ? CoverFallbackArtwork(seed: url, compact: true)
                        : AsyncRemoteCoverImage(
                            deferLoadDuringInteraction: true,
                            onImageError: library
                                .coverArtworkCacheService
                                .reportArtworkReadFailure,
                            url: url,
                            future: coverUi.deferredRemoteCover(
                              url,
                              context: context,
                            ),
                            initialPath:
                                library.resolvedCoverPathForRemoteCover(url),
                            retryFutureBuilder: () => coverUi
                                .deferredRemoteCover(url, context: context),
                            retryDelay: const Duration(seconds: 5),
                            maxRetryAttempts: 2,
                            fit: BoxFit.cover,
                            cacheWidth: coverCacheWidth,
                            useDefaultCacheWidth: false,
                            loadingBuilder: (_) => CoverLoadingArtwork(
                              placeholder: CoverFallbackArtwork(
                                seed: url,
                                compact: true,
                              ),
                            ),
                            fallbackBuilder: (_) =>
                                CoverFallbackArtwork(seed: url, compact: true),
                          ),
                  ),
                  if (duration != null && duration! > Duration.zero)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: DurationOverlay(duration: duration!),
                    ),
                ],
              ),
            ),
          ),
          if (rjCode.trim().isNotEmpty)
            Positioned(
              left: 4,
              top: 4,
              child: RjCodeOverlay(rjCode: rjCode, maxWidth: width - 8),
            ),
          Positioned(
            left: -2,
            bottom: -2,
            child: _AsmrSelectionIndicator(
              workId: rjCode.isNotEmpty ? rjCode : url,
              isSelected: isSelected,
            ),
          ),
        ],
      ),
    );
  }
}

String _asmrWorkListCoverUrl(AsmrWork work) {
  return work.preferredCoverUrl;
}
