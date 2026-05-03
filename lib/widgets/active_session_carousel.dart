import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../services/subtitle_parser.dart';
import '../screens/playlist_tab.dart';

Future<String?> _sessionCoverFutureForTrack(
  Map<String, Future<String?>> cache,
  AudioProvider provider,
  MusicTrack? track,
) {
  return provider.coverPathFutureForTrack(track);
}

class ActiveSessionCarousel extends StatefulWidget {
  const ActiveSessionCarousel({
    super.key,
    this.sessions,
    this.provider,
    this.i18n,
    this.onOpenSession,
    this.compactForFab = false,
  });

  final List<PlaybackSession>? sessions;
  final AudioProvider? provider;
  final AppLanguageProvider? i18n;
  final ValueChanged<String>? onOpenSession;
  final bool compactForFab;

  @override
  State<ActiveSessionCarousel> createState() => _ActiveSessionCarouselState();
}

class _ActiveSessionCarouselState extends State<ActiveSessionCarousel> {
  final Map<String, Future<String?>> _coverFutures = {};
  late PageController _pageController;

  double _page = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 1);
    _pageController.addListener(_handlePageTick);
  }

  @override
  void didUpdateWidget(covariant ActiveSessionCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.compactForFab == widget.compactForFab) return;

    final currentPage = _pageController.hasClients
        ? (_pageController.page ?? _page).round()
        : _page.round();
    _pageController
      ..removeListener(_handlePageTick)
      ..dispose();
    _pageController = PageController(
      initialPage: currentPage,
      viewportFraction: 1,
    );
    _pageController.addListener(_handlePageTick);
  }

  @override
  void dispose() {
    _pageController
      ..removeListener(_handlePageTick)
      ..dispose();
    super.dispose();
  }

  void _handlePageTick() {
    final nextPage = _pageController.hasClients
        ? (_pageController.page ?? _page)
        : _page;
    if ((nextPage - _page).abs() < 0.001) return;
    setState(() {
      _page = nextPage;
    });
  }

  void _openSessionDetail(BuildContext context, PlaybackSession session) {
    Feedback.forTap(context);
    final onOpenSession = widget.onOpenSession;
    if (onOpenSession != null) {
      onOpenSession(session.id);
      return;
    }
    Navigator.of(context).push(buildSessionDetailRoute(sessionId: session.id));
  }

  void _ensureValidPage(int length) {
    if (!_pageController.hasClients || length == 0) return;
    final maxPage = length - 1;
    final currentPage = (_pageController.page ?? 0).round();
    if (currentPage <= maxPage) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      _pageController.jumpToPage(maxPage);
      setState(() {
        _page = maxPage.toDouble();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = widget.provider ?? context.read<AudioProvider>();
    final sessions =
        widget.sessions ??
        context.select<AudioProvider, List<PlaybackSession>>(
          (value) => value.activeSessions,
        );
    if (sessions.isEmpty) {
      return const SizedBox.shrink();
    }

    _ensureValidPage(sessions.length);

    return SizedBox(
      height: 88,
      child: PageView.builder(
        controller: _pageController,
        clipBehavior: Clip.none,
        padEnds: false,
        physics: sessions.length == 1
            ? const NeverScrollableScrollPhysics()
            : const BouncingScrollPhysics(),
        itemCount: sessions.length,
        itemBuilder: (context, index) {
          final session = sessions[index];
          final pageDelta = index - _page;
          final selectedness = (1 - pageDelta.abs()).clamp(0.0, 1.0);
          final scale = lerpDouble(0.972, 1.0, selectedness) ?? 1.0;
          final translateX = pageDelta * 5;
          final translateY = lerpDouble(4, 0, selectedness) ?? 0;
          final track = provider.trackByPath(session.currentTrackPath);

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Transform.translate(
              offset: Offset(translateX, translateY),
              child: Transform.scale(
                scale: scale,
                alignment: Alignment.centerLeft,
                child: _ActiveSessionCard(
                  session: session,
                  track: track,
                  provider: provider,
                  coverPathFuture: _sessionCoverFutureForTrack(
                    _coverFutures,
                    provider,
                    track,
                  ),
                  onOpen: () => _openSessionDetail(context, session),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

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
    final displayName =
        track?.displayName ??
        path.basenameWithoutExtension(session.currentTrackPath);
    const cardRadius = 20.0;

    return Semantics(
      button: true,
      label: displayName,
      child: StreamBuilder<PlayerState>(
        stream: session.stateStream,
        initialData: session.state,
        builder: (context, stateSnapshot) {
          final playerState = stateSnapshot.data ?? session.state;
          final isPlaying = playerState.playing;

          return Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(cardRadius),
              onTap: onOpen,
              child: Ink(
                height: 74,
                decoration: BoxDecoration(
                  color: isPlaying
                      ? cs.surfaceContainerLow
                      : cs.surfaceContainer,
                  borderRadius: BorderRadius.circular(cardRadius),
                  border: Border.all(
                    color: isPlaying
                        ? cs.primary.withValues(alpha: 0.32)
                        : cs.outlineVariant.withValues(alpha: 0.8),
                  ),
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
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
                  child: Row(
                    children: [
                      _ActiveSessionCover(coverPathFuture: coverPathFuture),
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
                                      positionSnapshot.data ?? session.position,
                                      subtitleTrack: subtitleTrack,
                                    );

                                return Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                                              color: cs.onSurfaceVariant,
                                              fontWeight: FontWeight.w600,
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
                                Feedback.forTap(context);
                                provider.toggleSessionPlayPause(session.id);
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
                                : cs.outlineVariant.withValues(alpha: 0.72),
                          ),
                        ),
                        icon: _CarouselSwitcherSlot(
                          width: 22,
                          height: 22,
                          duration: const Duration(milliseconds: 150),
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
              ),
            ),
          );
        },
      ),
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
