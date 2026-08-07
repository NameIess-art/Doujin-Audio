part of 'playlist_tab.dart';

class _SessionHeroArtwork extends ConsumerWidget {
  const _SessionHeroArtwork({
    required this.session,
    required this.height,
    required this.track,
    required this.coverPathFuture,
    this.videoSurfaceEnabled = true,
    this.deferCoverLoading = false,
  });

  final PlaybackSession session;
  final double height;
  final MusicTrack? track;
  final Future<String?> coverPathFuture;
  final bool videoSurfaceEnabled;
  final bool deferCoverLoading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.read(libraryFacadeProvider);
    final sessionId = session.id;
    final cs = Theme.of(context).colorScheme;
    final coverCacheWidth = coverCacheWidthForResolution(
      ref.watch(
        settingsStateProvider.select(
          (s) => s.value?.coverImageResolution ?? CoverImageResolution.balanced,
        ),
      ),
    );
    final initialCoverPath = library.resolvedPlaybackCoverPathForTrack(track);
    final coverPoster = Stack(
      fit: StackFit.expand,
      children: [
        TickerMode(
          // Do not freeze a cover image's loading fade mid-frame while the
          // detail route is being dragged.
          enabled: true,
          child: AsyncLocalCoverImage(
            future: deferCoverLoading
                ? Future<String?>.value(initialCoverPath)
                : coverPathFuture,
            requestKey: sessionId,
            deferCommitDuringInteraction: true,
            initialPath: initialCoverPath,
            retryFutureBuilder: () => track == null
                ? Future<String?>.value()
                : library.playbackCoverPathFutureForTrack(track),
            seed: track?.displayName ?? track?.path ?? sessionId,
            cacheWidth: coverCacheWidth,
            useDefaultCacheWidth: coverCacheWidth != null,
            fit: BoxFit.cover,
            iconSize: 56,
          ),
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
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final displayWidth = constraints.maxWidth;

        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: height),
          child: Container(
            key: ValueKey('session_detail_cover_$sessionId'),
            width: displayWidth,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
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
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: SessionVideoViewport(
                videoReady:
                    videoSurfaceEnabled && _isSessionVideoReady(session, track),
                surfaceBuilder: (_) =>
                    NativeSessionVideoSurface(sessionId: sessionId),
                onFullscreen: () => _showSessionVideoFullscreen(
                  context,
                  ref,
                  sessionId: sessionId,
                  trackPath: track!.path,
                ),
                fullscreenTooltip: ref
                    .read(appLanguageProviderInstanceProvider)
                    .tr('fullscreen'),
                poster: track?.isVideo == true
                    ? SessionVideoBlurredBackdrop(child: coverPoster)
                    : coverPoster,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SessionCoverThumbnail extends ConsumerStatefulWidget {
  const _SessionCoverThumbnail({
    required this.sessionId,
    required this.track,
    required this.coverPath,
    required this.coverGeneration,
    required this.coverCacheWidth,
    this.freezeDynamicContent = false,
    this.duration,
    this.detailDuration,
  });

  final String sessionId;
  final MusicTrack? track;
  final String? coverPath;
  final int coverGeneration;
  final int? coverCacheWidth;
  final bool freezeDynamicContent;
  final Duration? duration;
  final Duration? detailDuration;

  @override
  ConsumerState<_SessionCoverThumbnail> createState() =>
      _SessionCoverThumbnailState();
}

class _SessionCoverThumbnailState
    extends ConsumerState<_SessionCoverThumbnail> {
  Future<String?>? _coverFuture;
  String? _lastTrackPath;
  int _lastCoverGeneration = -1;

  Future<String?> _futureFor(LibraryFacade library) {
    final trackPath = widget.track?.path;
    if (_coverFuture == null ||
        _lastTrackPath != trackPath ||
        _lastCoverGeneration != widget.coverGeneration) {
      _lastTrackPath = trackPath;
      _lastCoverGeneration = widget.coverGeneration;
      _coverFuture = library.playbackCoverPathFutureForTrack(widget.track);
    }
    return _coverFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final session = ref
        .read(playbackFacadeProvider)
        .sessionById(widget.sessionId);
    final library = ref.read(libraryFacadeProvider);
    final cover = widget.freezeDynamicContent
        ? LocalCoverImage(
            path: widget.coverPath,
            seed: widget.track?.displayName ?? widget.sessionId,
            cacheWidth: widget.coverCacheWidth,
            useDefaultCacheWidth: widget.coverCacheWidth != null,
            fit: BoxFit.cover,
            displayMode: CoverImageDisplayMode.fill,
            compact: true,
            iconSize: 26,
          )
        : AsyncLocalCoverImage(
            future: _futureFor(library),
            initialPath: widget.coverPath,
            retryFutureBuilder: () =>
                library.playbackCoverPathFutureForTrack(widget.track),
            seed: widget.track?.displayName ?? widget.sessionId,
            cacheWidth: widget.coverCacheWidth,
            useDefaultCacheWidth: widget.coverCacheWidth != null,
            fit: BoxFit.cover,
            displayMode: CoverImageDisplayMode.fill,
            compact: true,
            iconSize: 26,
          );
    return Stack(
      children: [
        SizedBox(
          key: ValueKey<String>('playlist_cover_${widget.sessionId}'),
          width: _playlistCoverSize,
          height: _playlistCoverSize,
          child: Material(
            type: MaterialType.transparency,
            borderRadius: BorderRadius.circular(
              LibraryLikeCardMetrics.coverRadius,
            ),
            clipBehavior: Clip.antiAlias,
            child: cover,
          ),
        ),
        Positioned(
          right: 4,
          bottom: 4,
          child: StreamBuilder<Duration?>(
            stream: widget.freezeDynamicContent
                ? null
                : session?.durationStream,
            initialData: session?.duration ?? widget.duration,
            builder: (context, snapshot) {
              final duration = widget.freezeDynamicContent
                  ? widget.detailDuration ?? widget.duration
                  : widget.detailDuration ?? snapshot.data;
              if (duration == null || duration <= Duration.zero) {
                return const SizedBox.shrink();
              }
              return DurationOverlay(duration: duration);
            },
          ),
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
