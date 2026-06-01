part of 'asmr_tab.dart';

class _AsmrWorkCover extends StatelessWidget {
  const _AsmrWorkCover({required this.url, required this.width});

  final String url;
  final double width;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final width = this.width;
    final height = width * 0.8;
    final url = this.url.trim();
    return ClipRRect(
      clipBehavior: Clip.hardEdge,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: width,
        height: height,
        child: url.isEmpty
            ? _AsmrCoverFallback(colorScheme: cs)
            : RetryingNetworkImage(
                url: url,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                cacheWidth:
                    (width *
                            MediaQuery.devicePixelRatioOf(
                              context,
                            ).clamp(1.0, 1.5))
                        .round(),
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) {
                    return child;
                  }
                  return _AsmrCoverLoading(colorScheme: cs);
                },
                fallbackBuilder: (_) => _AsmrCoverFallback(colorScheme: cs),
              ),
      ),
    );
  }
}

String _asmrWorkListCoverUrl(AsmrWork work) {
  for (final url in <String>[
    work.thumbnailUrl,
    work.mainCoverUrl,
    work.coverUrl,
  ]) {
    final trimmed = url.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return '';
}

class _AsmrCoverLoading extends StatelessWidget {
  const _AsmrCoverLoading({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primaryContainer,
            colorScheme.secondaryContainer.withValues(alpha: 0.92),
          ],
        ),
      ),
      child: Center(
        child: SizedBox.square(
          dimension: 36,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            color: colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class _AsmrCoverFallback extends StatelessWidget {
  const _AsmrCoverFallback({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primaryContainer,
            colorScheme.secondaryContainer.withValues(alpha: 0.92),
          ],
        ),
      ),
      child: Icon(
        Icons.photo_album_rounded,
        color: colorScheme.onPrimaryContainer,
        size: 28,
      ),
    );
  }
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
