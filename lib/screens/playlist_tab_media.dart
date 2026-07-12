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
    final coverCacheWidth = coverCacheWidthForResolution(
      ref.watch(
        settingsStateProvider.select(
          (s) =>
              s.valueOrNull?.coverImageResolution ??
              CoverImageResolution.balanced,
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final displayWidth = constraints.maxWidth;

        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: height),
          child: Container(
            width: displayWidth,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              border: Border.all(
                color: cs.onSurface.withValues(alpha: 0.12),
                width: 0.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 56,
                  spreadRadius: 4,
                  offset: const Offset(0, 28),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 24,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Material(
              type: MaterialType.transparency,
              borderRadius: BorderRadius.circular(32),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AsyncLocalCoverImage(
                    future: coverPathFuture,
                    requestKey: sessionId,
                    initialPath: provider.resolvedPlaybackCoverPathForTrack(
                      track,
                    ),
                    retryFutureBuilder: () =>
                        _coverFutureForTrack(provider, track),
                    seed: track?.displayName ?? track?.path ?? sessionId,
                    cacheWidth: coverCacheWidth,
                    useDefaultCacheWidth: coverCacheWidth != null,
                    fit: BoxFit.cover,
                    iconSize: 56,
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
        );
      },
    );
  }
}

class _SessionCoverThumbnail extends StatefulWidget {
  const _SessionCoverThumbnail({
    required this.sessionId,
    required this.track,
    required this.coverPath,
    required this.coverGeneration,
    required this.coverCacheWidth,
    this.duration,
  });

  static const double _width = 96;
  static const double _height = 72;

  final String sessionId;
  final MusicTrack? track;
  final String? coverPath;
  final int coverGeneration;
  final int? coverCacheWidth;
  final Duration? duration;

  @override
  State<_SessionCoverThumbnail> createState() => _SessionCoverThumbnailState();
}

class _SessionCoverThumbnailState extends State<_SessionCoverThumbnail> {
  Future<String?>? _coverFuture;
  String? _lastTrackPath;
  int _lastCoverGeneration = -1;

  Future<String?> _futureFor(AudioProvider provider) {
    final trackPath = widget.track?.path;
    if (_coverFuture == null ||
        _lastTrackPath != trackPath ||
        _lastCoverGeneration != widget.coverGeneration) {
      _lastTrackPath = trackPath;
      _lastCoverGeneration = widget.coverGeneration;
      _coverFuture = _coverFutureForTrack(provider, widget.track);
    }
    return _coverFuture!;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SizedBox(
          width: _SessionCoverThumbnail._width,
          height: _SessionCoverThumbnail._height,
          child: Material(
            type: MaterialType.transparency,
            borderRadius: BorderRadius.circular(LibraryLikeCardMetrics.coverRadius),
            clipBehavior: Clip.antiAlias,
            child: AsyncLocalCoverImage(
              future: _futureFor(context.read<AudioProvider>()),
              initialPath: widget.coverPath,
              retryFutureBuilder: () =>
                  _coverFutureForTrack(context.read<AudioProvider>(), widget.track),
              seed:
                  widget.track?.displayName ??
                  widget.track?.path ??
                  widget.sessionId,
              cacheWidth: widget.coverCacheWidth,
              useDefaultCacheWidth: widget.coverCacheWidth != null,
              fit: BoxFit.cover,
              compact: true,
              iconSize: 26,
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
          child: FadeTransition(opacity: animation, child: child),
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
        AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
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
