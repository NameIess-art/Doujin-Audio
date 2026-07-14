part of 'asmr_tab.dart';

class _AsmrWorkCover extends StatelessWidget {
  const _AsmrWorkCover({required this.url, required this.width, this.duration});

  final String url;
  final double width;
  final Duration? duration;

  @override
  Widget build(BuildContext context) {
    final width = this.width;
    final height = width * 0.8;
    final url = this.url.trim();
    final coverCacheWidth = coverCacheWidthForResolution(
      context.select<AudioProvider, CoverImageResolution>(
        (provider) => provider.coverImageResolution,
      ),
    );
    final provider = context.read<AudioProvider>();
    return ClipRRect(
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
                    future: provider.coverPathFutureForRemoteCover(url),
                    initialPath: provider.resolvedCoverPathForRemoteCover(url),
                    retryFutureBuilder: () =>
                        provider.coverPathFutureForRemoteCover(url),
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
    );
  }
}

String _asmrWorkListCoverUrl(AsmrWork work) {
  return work.preferredCoverUrl;
}
