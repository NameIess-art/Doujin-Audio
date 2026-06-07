part of 'playlist_tab.dart';

class _SessionHeroArtwork extends ConsumerWidget {
  const _SessionHeroArtwork({
    required this.sessionId,
    required this.height,
    required this.track,
    required this.coverPathFuture,
  });

  final String sessionId;
  final double height;
  final MusicTrack? track;
  final Future<String?> coverPathFuture;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = ref.read(audioProviderFacadeProvider);
    final cs = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);

    Widget fallback({bool hideIcon = false}) {
      return CoverFallbackArtwork(
        seed: track?.displayName ?? track?.path ?? sessionId,
        showIcon: !hideIcon,
        iconSize: 56,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final displayWidth = constraints.maxWidth;
        final cacheW = (displayWidth * dpr).round();

        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: height),
          child: Container(
            width: displayWidth,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: cs.onSurface.withValues(alpha: 0.08),
                width: 0.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 48,
                  spreadRadius: 8,
                  offset: const Offset(0, 24),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Hero(
              tag: 'cover_$sessionId',
              flightShuttleBuilder:
                  (context, animation, direction, fromContext, toContext) =>
                      fromContext.widget,
              createRectTween: (begin, end) =>
                  MaterialRectCenterArcTween(begin: begin, end: end),
              child: Material(
                type: MaterialType.transparency,
                borderRadius: BorderRadius.circular(24),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (track?.remoteCoverUrl?.trim().isNotEmpty == true)
                      RetryingNetworkImage(
                        url: track!.remoteCoverUrl!,
                        fit: BoxFit.cover,
                        cacheWidth: (cacheW * dpr.clamp(1.0, 1.5) / dpr)
                            .round(),
                        loadingBuilder: (context, child, loadingProgress) =>
                            loadingProgress == null
                            ? child
                            : CoverLoadingIndicator(
                                size: 36,
                                strokeWidth: 3,
                                color: cs.onPrimaryContainer.withValues(
                                  alpha: 0.75,
                                ),
                              ),
                        fallbackBuilder: (_) => fallback(),
                      )
                    else
                      AsyncCoverImage(
                        duration: Duration.zero,
                        future: coverPathFuture,
                        initialPath: provider.resolvedCoverPathForTrack(track),
                        retryFutureBuilder: () =>
                            _coverFutureForTrack(provider, track),
                        fallbackBuilder: (_) => fallback(),
                        loadingBuilder: (_) => Stack(
                          fit: StackFit.expand,
                          children: [
                            fallback(hideIcon: true),
                            CoverLoadingIndicator(
                              size: 36,
                              strokeWidth: 3,
                              color: cs.onPrimaryContainer.withValues(
                                alpha: 0.75,
                              ),
                            ),
                          ],
                        ),
                        imageBuilder: (context, coverPath) {
                          return RepaintBoundary(
                            child: RetryingFileImage(
                              path: coverPath,
                              cacheWidth: (cacheW * dpr.clamp(1.0, 1.5) / dpr)
                                  .round(),
                              fit: BoxFit.cover,
                              fallbackBuilder: (_) => fallback(),
                            ),
                          );
                        },
                      ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.1),
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.2),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SessionCoverThumbnail extends ConsumerWidget {
  const _SessionCoverThumbnail({
    required this.sessionId,
    required this.track,
    required this.coverPathFuture,
  });

  final String sessionId;
  final MusicTrack? track;
  final Future<String?> coverPathFuture;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = ref.read(audioProviderFacadeProvider);
    final cs = Theme.of(context).colorScheme;

    Widget fallback({bool hideIcon = false}) {
      return CoverFallbackArtwork(
        seed: track?.displayName ?? track?.path ?? sessionId,
        showIcon: !hideIcon,
        compact: true,
        iconSize: 26,
      );
    }

    return Hero(
      tag: 'cover_$sessionId',
      placeholderBuilder: (context, heroSize, child) => child,
      flightShuttleBuilder:
          (context, animation, direction, fromContext, toContext) =>
              fromContext.widget,
      createRectTween: (begin, end) =>
          MaterialRectCenterArcTween(begin: begin, end: end),
      child: SizedBox(
        width: 96,
        height: 72,
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: track?.remoteCoverUrl?.trim().isNotEmpty == true
              ? RetryingNetworkImage(
                  url: track!.remoteCoverUrl!,
                  fit: BoxFit.cover,
                  cacheWidth:
                      (96 *
                              MediaQuery.devicePixelRatioOf(
                                context,
                              ).clamp(1.0, 1.5))
                          .round(),
                  loadingBuilder: (context, child, loadingProgress) =>
                      loadingProgress == null
                      ? child
                      : CoverLoadingIndicator(
                          color: cs.onPrimaryContainer.withValues(alpha: 0.75),
                        ),
                  fallbackBuilder: (_) => fallback(),
                )
              : AsyncCoverImage(
                  duration: Duration.zero,
                  future: coverPathFuture,
                  initialPath: provider.resolvedCoverPathForTrack(track),
                  retryFutureBuilder: () =>
                      _coverFutureForTrack(provider, track),
                  fallbackBuilder: (_) => fallback(),
                  loadingBuilder: (_) => Stack(
                    fit: StackFit.expand,
                    children: [
                      fallback(hideIcon: true),
                      CoverLoadingIndicator(
                        color: cs.onPrimaryContainer.withValues(alpha: 0.75),
                      ),
                    ],
                  ),
                  imageBuilder: (context, coverPath) {
                    final dpr = MediaQuery.devicePixelRatioOf(context);
                    return RetryingFileImage(
                      path: coverPath,
                      cacheWidth: (96 * dpr.clamp(1.0, 1.5)).round(),
                      fit: BoxFit.cover,
                      fallbackBuilder: (_) => fallback(),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _SessionMetaChip extends StatelessWidget {
  const _SessionMetaChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          Icon(
            icon,
            size: 11,
            color: cs.onSurfaceVariant.withValues(alpha: 0.65),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontStyle: FontStyle.italic,
                color: cs.onSurfaceVariant.withValues(alpha: 0.65),
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitcherSlot extends StatelessWidget {
  const _SwitcherSlot({
    required this.child,
    required this.width,
    required this.height,
    this.duration = const Duration(milliseconds: 150),
  });

  final Widget child;
  final double width;
  final double height;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) {
        return SizedBox(
          width: width,
          height: height,
          child: Center(
            child:
                currentChild ??
                (previousChildren.isNotEmpty
                    ? previousChildren.last
                    : const SizedBox.shrink()),
          ),
        );
      },
      transitionBuilder: (child, animation) {
        return ScaleTransition(
          scale: Tween<double>(begin: 0.4, end: 1.0).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
          ),
          child: FadeTransition(
            opacity: animation,
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

class _LoopModeButton extends StatelessWidget {
  const _LoopModeButton({
    this.icon,
    this.iconWidget,
    required this.onPressed,
    this.active = false,
  }) : assert(icon != null || iconWidget != null);

  final IconData? icon;
  final Widget? iconWidget;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final child =
        iconWidget ??
        Icon(
          icon,
          key: ValueKey<IconData?>(icon),
          size: 18,
          color: active ? cs.primary : cs.onSurfaceVariant,
        );
    return IconButton(
      onPressed: () {
        HapticFeedback.selectionClick();
        onPressed();
      },
      style: IconButton.styleFrom(
        minimumSize: const Size(40, 40),
        maximumSize: const Size(40, 40),
        backgroundColor: active
            ? cs.primaryContainer.withValues(alpha: 0.94)
            : cs.surfaceContainerHighest.withValues(alpha: 0.72),
        side: BorderSide(
          color: active
              ? cs.primary.withValues(alpha: 0.45)
              : cs.outlineVariant.withValues(alpha: 0.9),
        ),
      ),
      icon: _SwitcherSlot(
        width: 18,
        height: 18,
        duration: const Duration(milliseconds: 140),
        child: child,
      ),
    );
  }
}
