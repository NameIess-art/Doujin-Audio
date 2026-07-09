part of 'asmr_tab.dart';

class _AsmrWorkCover extends StatelessWidget {
  const _AsmrWorkCover({required this.url, required this.width});

  final String url;
  final double width;

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
      child: SizedBox(
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
    );
  }
}

String _asmrWorkListCoverUrl(AsmrWork work) {
  return work.preferredCoverUrl;
}

class _AsmrWorkSkeletonCard extends StatelessWidget {
  const _AsmrWorkSkeletonCard();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final fallbackColor = cs.surfaceContainerLow;

    final cardShape = RoundedRectangleBorder(
      side: BorderSide(
        color: cs.outlineVariant.withValues(alpha: isDark ? 0.26 : 0.42),
      ),
      borderRadius: BorderRadius.circular(14),
    );

    const infoBlockHeight = LibraryLikeCardMetrics.infoBlockHeight;
    const coverWidth =
        infoBlockHeight * LibraryLikeCardMetrics.coverAspectRatio;

    return Card(
      margin: EdgeInsets.zero,
      shape: cardShape,
      color: fallbackColor,
      elevation: 0,
      child: SizedBox(
        height: 158,
        width: double.infinity,
        child: ShimmerLoader(
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ShimmerContainer(
                      width: coverWidth,
                      height: infoBlockHeight,
                      borderRadius: LibraryLikeCardMetrics.coverRadius,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(height: 4),
                          ShimmerContainer(height: 12, borderRadius: 6),
                          SizedBox(height: 8),
                          ShimmerContainer(
                            width: 140,
                            height: 12,
                            borderRadius: 6,
                          ),
                          SizedBox(height: 8),
                          ShimmerContainer(
                            width: 100,
                            height: 12,
                            borderRadius: 6,
                          ),
                          SizedBox(height: 8),
                          ShimmerContainer(
                            width: 160,
                            height: 12,
                            borderRadius: 6,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                const ShimmerContainer(width: 220, height: 16, borderRadius: 8),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
