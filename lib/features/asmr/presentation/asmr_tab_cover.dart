part of 'asmr_tab.dart';

class _AsmrWorkCover extends ConsumerWidget {
  const _AsmrWorkCover({
    required this.url,
    required this.width,
    required this.isActive,
    this.duration,
  });

  final String url;
  final double width;
  final bool isActive;
  final Duration? duration;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = this.width;
    final height = width / kStandardCoverAspectRatio;
    final url = this.url.trim();
    final coverResolution = isActive
        ? ref.watch(coverImageResolutionProvider)
        : ref.read(coverImageResolutionProvider);
    final coverCacheWidth = coverCacheWidthForResolution(coverResolution);
    final library = ref.read(libraryFacadeProvider);
    final coverUi = ref.read(libraryCoverUiControllerProvider);
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        clipBehavior: Clip.hardEdge,
        borderRadius: BorderRadius.circular(LibraryLikeCardMetrics.coverRadius),
        child: Stack(
          children: [
            SizedBox(
              width: width,
              height: height,
              child: url.isEmpty
                  ? CoverFallbackArtwork(
                      seed: url,
                      compact: true,
                      icon: Icons.graphic_eq_rounded,
                      iconSize: 28,
                    )
                  : AsyncRemoteCoverImage(
                      url: url,
                      future: coverUi.deferredRemoteCover(url),
                      initialPath: library.resolvedCoverPathForRemoteCover(url),
                      retryFutureBuilder: () => coverUi.deferredRemoteCover(url),
                      retryDelay: const Duration(seconds: 5),
                      maxRetryAttempts: 2,
                      fit: BoxFit.cover,
                      cacheWidth: coverCacheWidth,
                      useDefaultCacheWidth: coverCacheWidth != null,
                      loadingBuilder: (_) => CoverLoadingArtwork(
                        placeholder: CoverFallbackArtwork(
                          seed: url,
                          showIcon: false,
                          compact: true,
                        ),
                      ),
                      fallbackBuilder: (_) => CoverFallbackArtwork(
                        seed: url,
                        compact: true,
                        icon: Icons.graphic_eq_rounded,
                        iconSize: 28,
                      ),
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
    );
  }
}

String _asmrWorkListCoverUrl(AsmrWork work) {
  return work.preferredCoverUrl;
}
