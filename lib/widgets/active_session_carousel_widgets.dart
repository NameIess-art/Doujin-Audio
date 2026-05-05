part of 'active_session_carousel.dart';

class _ActiveSessionCard extends StatelessWidget {
  const _ActiveSessionCard({
    required this.session,
    required this.track,
    required this.provider,
    required this.coverPathFuture,
    required this.onOpen,
  });

  final PlaybackSession session;
  final MusicTrack? track;
  final AudioProvider provider;
  final Future<String?> coverPathFuture;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const cardRadius = 20.0;

    return StreamBuilder<PlayerState>(
      stream: session.stateStream,
      initialData: session.state,
      builder: (context, stateSnapshot) {
        final playerState = stateSnapshot.data ?? session.state;
        final isPlaying = playerState.playing;
        final currentTrack = provider.trackByPath(session.currentTrackPath);
        final displayName =
            currentTrack?.displayName ??
            path.basenameWithoutExtension(session.currentTrackPath);

        return Semantics(
          button: true,
          label: displayName,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(cardRadius),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(cardRadius),
                  onTap: onOpen,
                  child: Ink(
                    height: 74,
                    decoration: BoxDecoration(
                      color:
                          (isPlaying
                                  ? cs.surfaceContainerLow
                                  : cs.surfaceContainer)
                              .withValues(alpha: 0.52),
                      borderRadius: BorderRadius.circular(cardRadius),
                      boxShadow: [
                        BoxShadow(
                          color: cs.shadow.withValues(
                            alpha: isPlaying ? 0.1 : 0.06,
                          ),
                          blurRadius: isPlaying ? 22 : 16,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 6, 8, 4),
                          child: Row(
                            children: [
                              _ActiveSessionCover(
                                coverPathFuture: coverPathFuture,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: FutureBuilder<SubtitleTrack?>(
                                  future: provider.subtitleTrackForPath(
                                    session.currentTrackPath,
                                  ),
                                  builder: (context, snapshot) {
                                    final subtitleTrack = snapshot.data;
                                    return StreamBuilder<Duration>(
                                      stream: session.positionStream,
                                      initialData: session.position,
                                      builder: (context, positionSnapshot) {
                                        final subtitleText = provider
                                            .subtitleTextForTrackAt(
                                              session.currentTrackPath,
                                              positionSnapshot.data ??
                                                  session.position,
                                              subtitleTrack: subtitleTrack,
                                            );

                                        return Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              displayName,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleSmall
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w900,
                                                    fontSize: 14,
                                                    height: 1.08,
                                                  ),
                                            ),
                                            if (subtitleText != null) ...[
                                              const SizedBox(height: 2),
                                              Text(
                                                subtitleText,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.copyWith(
                                                      color:
                                                          cs.onSurfaceVariant,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      fontSize: 10.2,
                                                      height: 1.15,
                                                    ),
                                              ),
                                            ],
                                          ],
                                        );
                                      },
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filledTonal(
                                onPressed: session.isLoading
                                    ? null
                                    : () {
                                        HapticFeedback.mediumImpact();
                                        provider.toggleSessionPlayPause(
                                          session.id,
                                        );
                                      },
                                style: IconButton.styleFrom(
                                  minimumSize: const Size(48, 48),
                                  maximumSize: const Size(48, 48),
                                  backgroundColor: isPlaying
                                      ? cs.primaryContainer
                                      : cs.surfaceContainerLow,
                                  foregroundColor: isPlaying
                                      ? cs.onPrimaryContainer
                                      : cs.onSurface,
                                  shape: const CircleBorder(),
                                  side: BorderSide(
                                    color: isPlaying
                                        ? cs.primary.withValues(alpha: 0.24)
                                        : cs.outlineVariant.withValues(
                                            alpha: 0.72,
                                          ),
                                  ),
                                ),
                                icon: _CarouselSwitcherSlot(
                                  width: 22,
                                  height: 22,
                                  child: Icon(
                                    isPlaying
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    key: ValueKey<IconData>(
                                      isPlaying
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        StreamBuilder<Duration>(
                          stream: session.positionStream,
                          initialData: session.position,
                          builder: (context, posSnapshot) {
                            final pos = posSnapshot.data ?? session.position;
                            final dur = session.duration;
                            if (dur == null || dur.inMilliseconds <= 0) {
                              return const SizedBox(height: 3);
                            }
                            final fraction =
                                pos.inMilliseconds / dur.inMilliseconds;
                            return Center(
                              child: FractionallySizedBox(
                                widthFactor: 0.8,
                                child: ClipRRect(
                                  borderRadius: const BorderRadius.only(
                                    bottomLeft: Radius.circular(cardRadius - 1),
                                    bottomRight: Radius.circular(
                                      cardRadius - 1,
                                    ),
                                  ),
                                  child: LinearProgressIndicator(
                                    value: fraction.clamp(0.0, 1.0),
                                    minHeight: 3,
                                    backgroundColor: cs.surfaceContainerHighest,
                                    color: cs.primary.withValues(alpha: 0.7),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ActiveSessionCover extends StatelessWidget {
  const _ActiveSessionCover({required this.coverPathFuture});

  final Future<String?> coverPathFuture;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget fallback() {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              cs.primaryContainer,
              cs.secondaryContainer.withValues(alpha: 0.92),
            ],
          ),
        ),
        child: Center(
          child: Icon(
            Icons.photo_album_rounded,
            size: 24,
            color: cs.onPrimaryContainer,
          ),
        ),
      );
    }

    return SizedBox(
      width: 58,
      height: 58,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: FutureBuilder<String?>(
          future: coverPathFuture,
          builder: (context, snapshot) {
            final coverPath = snapshot.data;
            if (coverPath == null || coverPath.isEmpty) {
              return fallback();
            }
            return Image.file(
              File(coverPath),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback(),
            );
          },
        ),
      ),
    );
  }
}

class _CarouselSwitcherSlot extends StatelessWidget {
  const _CarouselSwitcherSlot({
    required this.child,
    required this.width,
    required this.height,
  });

  final Widget child;
  final double width;
  final double height;
  final Duration duration = const Duration(milliseconds: 180);

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
        final opacity = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: opacity,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.92, end: 1).animate(opacity),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
