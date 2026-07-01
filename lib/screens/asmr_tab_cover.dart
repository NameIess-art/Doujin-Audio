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

    final fallbackColor = isDark
        ? cs.surfaceContainerHigh
        : cs.surfaceContainerHighest;

    final cardShape = RoundedRectangleBorder(
      side: BorderSide(color: cs.outlineVariant),
      borderRadius: BorderRadius.circular(14),
    );

    return Card(
      margin: EdgeInsets.zero,
      shape: cardShape,
      color: fallbackColor,
      elevation: 0,
      child: const SizedBox(
        height: 158,
        width: double.infinity,
      ),
    );
  }
}
