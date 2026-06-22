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
            : RetryingNetworkImage(
                url: url,
                fit: BoxFit.cover,
                cacheWidth: coverCacheWidthForDisplay(
                  context,
                  width,
                  maxMobileDpr: 1.5,
                ),
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) {
                    return child;
                  }
                  return CoverLoadingArtwork(
                    placeholder: CoverFallbackArtwork(
                      seed: url,
                      showIcon: false,
                      compact: true,
                    ),
                    size: 36,
                    strokeWidth: 3,
                  );
                },
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
  for (final url in <String>[
    work.mainCoverUrl,
    work.coverUrl,
    work.thumbnailUrl,
  ]) {
    final trimmed = url.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return '';
}

class _AsmrWorkSkeletonCard extends StatelessWidget {
  const _AsmrWorkSkeletonCard();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cardShape = RoundedRectangleBorder(
      side: BorderSide(color: cs.outlineVariant),
      borderRadius: BorderRadius.circular(14),
    );

    return Card(
      margin: EdgeInsets.zero,
      shape: cardShape,
      color: cs.surface,
      child: const Padding(
        padding: EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: SizedBox(
          height: 136,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShimmerContainer(width: 110, height: 136, borderRadius: 12),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(height: 4),
                    ShimmerContainer(width: 90, height: 14, borderRadius: 4),
                    SizedBox(height: 12),
                    ShimmerContainer(width: 140, height: 14, borderRadius: 4),
                    SizedBox(height: 12),
                    ShimmerContainer(width: 110, height: 14, borderRadius: 4),
                    Spacer(),
                    ShimmerContainer(
                      width: double.infinity,
                      height: 26,
                      borderRadius: 6,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
