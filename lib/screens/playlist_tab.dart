import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../services/subtitle_parser.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_transitions.dart';
import '../widgets/confirm_action_dialog.dart';
import '../widgets/mobile_overlay_inset.dart';
import '../widgets/swipe_reveal_card.dart';
import '../widgets/top_page_header.dart';

Future<String?> _coverFutureForTrack(
  AudioProvider provider,
  MusicTrack? track,
) {
  if (track == null) {
    return Future<String?>.value();
  }
  return provider.coverPathFutureForTrack(track);
}

PageRoute<void> buildSessionDetailRoute({required String sessionId}) {
  return buildAppOverlayRoute(
    child: SessionDetailPage(sessionId: sessionId),
    beginOffset: const Offset(0, 1.0),
    reverseDuration: Duration.zero,
  );
}

class PlaylistTab extends StatefulWidget {
  const PlaylistTab({super.key, this.onTimerTap});

  final VoidCallback? onTimerTap;

  @override
  State<PlaylistTab> createState() => _PlaylistTabState();
}

class _PlaylistTabState extends State<PlaylistTab> {
  final GlobalKey _headerKey = GlobalKey();
  double _headerHeight = 90;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureHeader());
  }

  void _measureHeader() {
    final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && mounted) {
      final h = box.size.height;
      if (h > 0 && h != _headerHeight) {
        setState(() => _headerHeight = h);
      }
    }
  }

  Future<void> _confirmClearAll(
    BuildContext context,
    AudioProvider provider,
  ) async {
    final i18n = context.read<AppLanguageProvider>();
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('clear_all_sessions'),
      message: i18n.tr('stop_remove_all_sessions'),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('clear'),
      icon: Icons.delete_sweep_rounded,
    );
    if (confirmed == true) {
      await provider.clearAllSessions();
      if (context.mounted) {
        showAppSnackBar(
          context,
          i18n.tr('all_sessions_cleared'),
          tone: AppFeedbackTone.destructive,
          icon: Icons.delete_sweep_rounded,
        );
      }
    }
  }

  void _openSessionDetail(BuildContext context, String sessionId) {
    Feedback.forTap(context);
    Navigator.of(context).push(buildSessionDetailRoute(sessionId: sessionId));
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    final bottomInset = MobileOverlayInset.of(context);
    final sessions = context.select<AudioProvider, List<PlaybackSession>>(
      (value) => value.activeSessions,
    );
    final playingCount = context.select<AudioProvider, int>(
      (value) => value.playingSessionCount,
    );
    final sessionSummary =
        '${i18n.tr('sessions_count', {'count': sessions.length})} · '
        '${i18n.tr('playing_count', {'count': playingCount})}';
    final timerDuration = context.select<AudioProvider, Duration?>(
      (value) => value.timerDuration,
    );
    final timerRemaining = context.select<AudioProvider, Duration?>(
      (value) => value.timerRemaining,
    );
    final timerActive = context.select<AudioProvider, bool>(
      (value) => value.timerActive,
    );
    final topTotalHeight = _headerHeight + 4;

    return Stack(
      children: [
        sessions.isEmpty
            ? Column(
                children: [
                  SizedBox(height: topTotalHeight),
                  Expanded(
                    child: _SessionsEmptyState(bottomInset: bottomInset),
                  ),
                ],
              )
            : ReorderableListView.builder(
                padding: EdgeInsets.fromLTRB(
                  16,
                  topTotalHeight,
                  16,
                  bottomInset,
                ),
                cacheExtent: 720,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                onReorder: provider.reorderSessions,
                itemCount: sessions.length,
                itemBuilder: (context, index) {
                  final session = sessions[index];
                  final track = provider.trackByPath(session.currentTrackPath);
                  return ReorderableDelayedDragStartListener(
                    key: ValueKey(session.id),
                    index: index,
                    child: _SessionListCard(
                      session: session,
                      provider: provider,
                      coverPathFuture: _coverFutureForTrack(provider, track),
                      onOpen: () => _openSessionDetail(context, session.id),
                    ),
                  );
                },
              ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: TopPageHeader(
            key: _headerKey,
            icon: Icons.graphic_eq_rounded,
            title: i18n.tr('playback_sessions'),
            subtitle: sessionSummary,
            subtitleMaxLines: 1,
            subtitleFontSize: 11,
            fitSubtitleToWidth: true,
            trailing: SizedBox(
              width: 168,
              height: 44,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (timerDuration != null)
                    _TimerCountdownCapsule(
                      remaining: timerRemaining ?? timerDuration,
                      active: timerActive,
                      onTap: widget.onTimerTap,
                    )
                  else
                    IconButton(
                      onPressed: widget.onTimerTap,
                      icon: const Icon(Icons.alarm_rounded),
                      tooltip: i18n.tr('timer'),
                    ),
                  IconButton(
                    onPressed: sessions.isEmpty
                        ? null
                        : () {
                            provider.pauseAllSessions();
                            showAppSnackBar(
                              context,
                              i18n.tr('all_paused'),
                              tone: AppFeedbackTone.warning,
                              icon: Icons.pause_circle_outline_rounded,
                            );
                          },
                    icon: const Icon(Icons.pause_circle_outline_rounded),
                    tooltip: i18n.tr('pause_all_sessions'),
                  ),
                  IconButton(
                    onPressed: sessions.isEmpty
                        ? null
                        : () => _confirmClearAll(context, provider),
                    icon: const Icon(Icons.delete_sweep_rounded),
                    tooltip: i18n.tr('clear_all_sessions'),
                  ),
                ],
              ),
            ),
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          ),
        ),
      ],
    );
  }
}

class _SessionsEmptyState extends StatelessWidget {
  const _SessionsEmptyState({required this.bottomInset});

  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: EdgeInsets.fromLTRB(24, 16, 24, bottomInset),
      physics: const BouncingScrollPhysics(),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    Icons.queue_music_rounded,
                    size: 30,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  i18n.tr('no_active_sessions'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  i18n.tr('go_library_hint'),
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SessionListCard extends StatefulWidget {
  const _SessionListCard({
    required this.session,
    required this.provider,
    required this.coverPathFuture,
    required this.onOpen,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final Future<String?> coverPathFuture;
  final VoidCallback onOpen;

  @override
  State<_SessionListCard> createState() => _SessionListCardState();
}

class _SessionListCardState extends State<_SessionListCard> {
  Future<void> _confirmRemoveSession(BuildContext context) async {
    final i18n = context.read<AppLanguageProvider>();
    final track = widget.provider.trackByPath(widget.session.currentTrackPath);
    final displayName =
        track?.displayName ??
        path.basenameWithoutExtension(widget.session.currentTrackPath);
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('remove_audio'),
      message: displayName,
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('remove'),
      icon: Icons.delete_outline_rounded,
    );
    if (confirmed && context.mounted) {
      await widget.provider.removeSession(widget.session.id);
    }
  }

  String _loopModeSummary(BuildContext context, SessionLoopMode mode) {
    final i18n = context.read<AppLanguageProvider>();
    if (mode == SessionLoopMode.single) return i18n.tr('single_loop');
    final scope =
        mode == SessionLoopMode.crossRandom ||
            mode == SessionLoopMode.crossSequential
        ? i18n.tr('cross_folder')
        : i18n.tr('current_folder');
    final order =
        mode == SessionLoopMode.crossRandom ||
            mode == SessionLoopMode.folderRandom
        ? i18n.tr('random_order')
        : i18n.tr('sequential_order');
    return '$order - $scope';
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final session = widget.session;
    final provider = widget.provider;
    final sessionView = context
        .select<
          AudioProvider,
          ({
            MusicTrack? track,
            String trackPath,
            SessionLoopMode loopMode,
            bool isLoading,
          })
        >((value) {
          final currentSession =
              value.sessionById(widget.session.id) ?? session;
          return (
            track: value.trackByPath(currentSession.currentTrackPath),
            trackPath: currentSession.currentTrackPath,
            loopMode: currentSession.loopMode,
            isLoading: currentSession.isLoading,
          );
        });
    final track = sessionView.track;
    final displayName =
        track?.displayName ??
        path.basenameWithoutExtension(sessionView.trackPath);
    final folderName = (track != null && !track.isSingle)
        ? track.groupTitle
        : i18n.tr('imported_files');

    return StreamBuilder<PlayerState>(
      stream: session.stateStream,
      initialData: session.state,
      builder: (context, snapshot) {
        final playerState = snapshot.data ?? session.state;
        final isPlaying = playerState.playing;
        final cardShape = RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        );

        return SwipeRevealCard(
          key: ValueKey(session.id),
          margin: const EdgeInsets.only(bottom: 6),
          shape: cardShape,
          actionLabel: i18n.tr('remove'),
          removeTooltip: i18n.tr('remove_audio'),
          onRemove: () => _confirmRemoveSession(context),
          child: SizedBox(
            height: 96,
            child: Material(
              color: Colors.transparent,
              child: Card(
                margin: EdgeInsets.zero,
                clipBehavior: Clip.antiAlias,
                shape: cardShape,
                color: isPlaying
                    ? Color.alphaBlend(
                        cs.primaryContainer.withValues(alpha: 0.35),
                        cs.surfaceContainerHigh,
                      )
                    : cs.surfaceContainerHigh,
                elevation: 0,
                shadowColor: Colors.transparent,
                child: Semantics(
                  button: true,
                  label: displayName,
                  child: InkWell(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      widget.onOpen();
                    },
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 7, 10, 6),
                      child: Row(
                        children: [
                          _SessionCoverThumbnail(
                            coverPathFuture: provider.coverPathFutureForTrack(
                              track,
                            ),
                            title: displayName,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  folderName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: cs.onSurfaceVariant,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 12,
                                      ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  displayName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(
                                        fontWeight: FontWeight.w900,
                                        fontSize: 14,
                                        height: 1.12,
                                      ),
                                ),
                                const SizedBox(height: 4),
                                SizedBox(
                                  width: double.infinity,
                                  child: _SessionMetaChip(
                                    icon: Icons.repeat_rounded,
                                    text: _loopModeSummary(
                                      context,
                                      sessionView.loopMode,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          IconButton.filledTonal(
                            onPressed: sessionView.isLoading
                                ? null
                                : () {
                                    Feedback.forTap(context);
                                    provider.toggleSessionPlayPause(session.id);
                                  },
                            style: IconButton.styleFrom(
                              backgroundColor: isPlaying
                                  ? cs.primaryContainer
                                  : cs.surfaceContainerLow,
                              foregroundColor: isPlaying
                                  ? cs.onPrimaryContainer
                                  : cs.onSurface,
                              side: BorderSide(
                                color: isPlaying
                                    ? cs.primary.withValues(alpha: 0.2)
                                    : cs.outlineVariant.withValues(alpha: 0.72),
                              ),
                            ),
                            icon: _SwitcherSlot(
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

class SessionDetailPage extends StatefulWidget {
  const SessionDetailPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  State<SessionDetailPage> createState() => _SessionDetailPageState();
}

class _SessionDetailPageState extends State<SessionDetailPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dismissController;
  late String _currentSessionId;
  String? _lastPrecachingCoverKey;
  double _horizontalDragDelta = 0;

  @override
  void initState() {
    super.initState();
    _currentSessionId = widget.sessionId;
    _dismissController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: 0,
    );
  }

  @override
  void dispose() {
    _dismissController.dispose();
    super.dispose();
  }

  void _primeCoverArtwork(Future<String?> coverPathFuture) {
    final mediaSize = MediaQuery.sizeOf(context);
    final heroHeight = min(250.0, max(180.0, mediaSize.height * 0.28));
    final dpr = min(MediaQuery.devicePixelRatioOf(context), 2.0);
    final cacheWidth = (mediaSize.width * dpr).round();
    final cacheHeight = (heroHeight * dpr).round();
    final precacheKey = '$_currentSessionId:$cacheWidth:$cacheHeight';
    if (_lastPrecachingCoverKey == precacheKey) {
      return;
    }
    _lastPrecachingCoverKey = precacheKey;

    unawaited(
      Future<void>.microtask(() async {
        final coverPath = await coverPathFuture;
        if (!mounted || coverPath == null || coverPath.isEmpty) {
          return;
        }
        try {
          await precacheImage(
            ResizeImage.resizeIfNeeded(
              cacheWidth,
              cacheHeight,
              FileImage(File(coverPath)),
            ),
            context,
          );
        } catch (_) {}
      }),
    );
  }

  Future<void> _handleVerticalDragEnd(
    DragEndDetails details,
    BuildContext context,
  ) async {
    final navigator = Navigator.of(context);
    final velocity = details.primaryVelocity ?? 0;
    final shouldDismiss = _dismissController.value > 0.15 || velocity > 800;
    if (shouldDismiss) {
      await _animateDismissToEnd(velocity: velocity);
      if (mounted) {
        await navigator.maybePop();
      }
      return;
    }
    await _animateDismissBack();
  }

  Future<void> _animateDismissToEnd({double velocity = 0}) {
    final remaining = (1 - _dismissController.value).clamp(0.0, 1.0);
    final velocityFactor = (velocity.abs() / 2200).clamp(0.0, 1.0);
    final durationMs = lerpDouble(320, 200, velocityFactor)! * remaining;
    return _dismissController.animateTo(
      1,
      duration: Duration(milliseconds: durationMs.round().clamp(180, 340)),
    );
  }

  Future<void> _animateDismissBack() {
    final progress = _dismissController.value.clamp(0.0, 1.0);
    final durationMs = lerpDouble(140, 260, progress)!;
    return _dismissController.animateBack(
      0,
      duration: Duration(milliseconds: durationMs.round().clamp(140, 280)),
      curve: Curves.easeOutQuart,
    );
  }

  void _changeSessionByOffset(AudioProvider provider, int offset) {
    final sessions = provider.activeSessions;
    if (sessions.length < 2) return;
    final currentIndex = sessions.indexWhere(
      (session) => session.id == _currentSessionId,
    );
    if (currentIndex < 0) return;
    final nextIndex = (currentIndex + offset)
        .clamp(0, sessions.length - 1)
        .toInt();
    if (nextIndex == currentIndex) return;
    HapticFeedback.selectionClick();
    setState(() {
      _currentSessionId = sessions[nextIndex].id;
      _horizontalDragDelta = 0;
    });
  }

  void _handleHorizontalDragEnd(
    DragEndDetails details,
    AudioProvider provider,
  ) {
    final velocity = details.primaryVelocity ?? 0;
    final shouldGoPrevious = _horizontalDragDelta > 56 || velocity > 520;
    final shouldGoNext = _horizontalDragDelta < -56 || velocity < -520;
    _horizontalDragDelta = 0;
    if (shouldGoPrevious) {
      _changeSessionByOffset(provider, -1);
      return;
    }
    if (shouldGoNext) {
      _changeSessionByOffset(provider, 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selection = context
        .select<
          AudioProvider,
          ({
            PlaybackSession? session,
            String? fallbackSessionId,
            String sessionIds,
            String? trackPath,
            bool? loading,
            bool? playing,
            ProcessingState? processingState,
            SessionLoopMode? loopMode,
            double? volume,
          })
        >((provider) {
          final sessions = provider.activeSessions;
          final session = sessions.cast<PlaybackSession?>().firstWhere(
            (candidate) => candidate?.id == _currentSessionId,
            orElse: () => null,
          );
          return (
            session: session,
            fallbackSessionId: sessions.isEmpty ? null : sessions.first.id,
            sessionIds: sessions.map((session) => session.id).join('\u0001'),
            trackPath: session?.currentTrackPath,
            loading: session?.isLoading,
            playing: session?.state.playing,
            processingState: session?.state.processingState,
            loopMode: session?.loopMode,
            volume: session?.volume,
          );
        });
    final provider = context.read<AudioProvider>();
    final session = selection.session;

    if (session == null) {
      final fallbackSessionId = selection.fallbackSessionId;
      if (fallbackSessionId == null) {
        return const Scaffold(body: SizedBox.shrink());
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _currentSessionId = fallbackSessionId;
        });
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    final track = provider.trackByPath(session.currentTrackPath);
    final coverPathFuture = _coverFutureForTrack(provider, track);
    _primeCoverArtwork(coverPathFuture);
    final routeAnimation = ModalRoute.of(context)?.animation;
    final animatedListenable = routeAnimation == null
        ? _dismissController
        : Listenable.merge([routeAnimation, _dismissController]);

    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: animatedListenable,
        builder: (context, child) {
          final enterProgress = Curves.easeOutCubic.transform(
            (routeAnimation?.value ?? 1).clamp(0.0, 1.0),
          );
          final dismissProgress = Curves.easeOutCubic.transform(
            _dismissController.value.clamp(0.0, 1.0),
          );
          final dragDistance =
              MediaQuery.sizeOf(context).height * dismissProgress;
          final enterOffset = (1 - enterProgress) * 60;
          final backdropProgress = (enterProgress * pow(1 - dismissProgress, 3))
              .clamp(0.0, 1.0);

          return Stack(
            fit: StackFit.expand,
            children: [
              const Positioned.fill(
                child: ModalBarrier(
                  dismissible: false,
                  color: Colors.transparent,
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: _SessionDetailBackdrop(progress: backdropProgress),
                ),
              ),
              Opacity(
                opacity: (1 - dismissProgress).clamp(0.0, 1.0),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: 1.0,
                    child: Transform.translate(
                      offset: Offset(0, enterOffset + dragDistance),
                      child: child,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
        child: RepaintBoundary(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (details) {
              _horizontalDragDelta += details.primaryDelta ?? 0;
            },
            onHorizontalDragEnd: (details) =>
                _handleHorizontalDragEnd(details, provider),
            onHorizontalDragCancel: () {
              _horizontalDragDelta = 0;
            },
            onVerticalDragUpdate: (details) {
              final screenHeight = MediaQuery.sizeOf(context).height;
              if (screenHeight <= 0) return;
              final nextValue =
                  _dismissController.value +
                  (((details.primaryDelta ?? 0) / screenHeight) * 0.92);
              _dismissController.value = nextValue.clamp(0.0, 1.0);
            },
            onVerticalDragEnd: (details) =>
                _handleVerticalDragEnd(details, context),
            onVerticalDragCancel: () {
              _animateDismissBack();
            },
            child: _SessionDetailScaffold(
              session: session,
              provider: provider,
              coverPathFuture: coverPathFuture,
              onClose: () async {
                await _animateDismissToEnd();
                if (context.mounted) {
                  await Navigator.of(context).maybePop();
                }
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionDetailBackdrop extends StatelessWidget {
  const _SessionDetailBackdrop({this.progress = 1.0});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final blurSigma = lerpDouble(0, 16, progress) ?? 0;
    final gradientAlpha = lerpDouble(0, 1, progress) ?? 0;

    if (blurSigma < 0.1 && gradientAlpha < 0.01) return const SizedBox.shrink();

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                cs.surface.withValues(alpha: 0.08 * gradientAlpha),
                cs.scrim.withValues(alpha: 0.08 * gradientAlpha),
                cs.scrim.withValues(alpha: 0.14 * gradientAlpha),
              ],
            ),
          ),
        ),
        if (blurSigma > 0)
          ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
              child: const SizedBox.expand(),
            ),
          ),
      ],
    );
  }
}

class _SessionDetailScaffold extends StatelessWidget {
  const _SessionDetailScaffold({
    required this.session,
    required this.provider,
    required this.coverPathFuture,
    required this.onClose,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final Future<String?> coverPathFuture;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Material(
      color: cs.surface,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Dynamic Blurred Background
          Positioned.fill(
            child: FutureBuilder<String?>(
              future: coverPathFuture,
              builder: (context, snapshot) {
                final path = snapshot.data;
                if (path == null || path.isEmpty) {
                  return ColoredBox(color: cs.surfaceDim);
                }
                return Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  color: cs.surface.withValues(alpha: 0.45),
                  colorBlendMode: BlendMode.darken,
                );
              },
            ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 45, sigmaY: 45),
              child: const SizedBox.expand(),
            ),
          ),
          // Content
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Column(
                  children: [
                    // Top Bar
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: onClose,
                            icon: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: cs.onSurface,
                              size: 32,
                            ),
                          ),
                          const Spacer(),
                        ],
                      ),
                    ),
                    // Large Artwork
                    Expanded(
                      flex: 6,
                      child: Center(
                        child: RepaintBoundary(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: _SessionHeroArtwork(
                              height: constraints.maxHeight * 0.48,
                              coverPathFuture: coverPathFuture,
                              title: '',
                              folderName: '',
                              isPlaying: session.state.playing,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Detail Content
                    Expanded(
                      flex: 5,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
                        child: _SessionDetailContent(
                          session: session,
                          provider: provider,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionDetailContent extends StatefulWidget {
  const _SessionDetailContent({required this.session, required this.provider});

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  State<_SessionDetailContent> createState() => _SessionDetailContentState();
}

class _SessionDetailContentState extends State<_SessionDetailContent> {
  bool _isSingleLoop(SessionLoopMode mode) => mode == SessionLoopMode.single;

  bool _isShuffleLoop(SessionLoopMode mode) {
    return mode == SessionLoopMode.crossRandom ||
        mode == SessionLoopMode.folderRandom;
  }

  bool _isCrossFolderLoop(SessionLoopMode mode) {
    return mode == SessionLoopMode.crossRandom ||
        mode == SessionLoopMode.crossSequential;
  }

  String _loopModeSummary(BuildContext context, SessionLoopMode mode) {
    final i18n = context.read<AppLanguageProvider>();
    if (_isSingleLoop(mode)) return i18n.tr('single_loop');
    final scope = _isCrossFolderLoop(mode)
        ? i18n.tr('cross_folder')
        : i18n.tr('current_folder');
    final order = _isShuffleLoop(mode)
        ? i18n.tr('random_order')
        : i18n.tr('sequential_order');
    return '$order - $scope';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final provider = widget.provider;
    final session = widget.session;
    final track = provider.trackByPath(session.currentTrackPath);
    final displayName =
        track?.displayName ??
        path.basenameWithoutExtension(session.currentTrackPath);
    final folderName = (track != null && !track.isSingle)
        ? track.groupTitle
        : context.read<AppLanguageProvider>().tr('imported_files');
    final hasSiblings =
        provider.tracksInSameGroup(session.currentTrackPath).length > 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                folderName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.8),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _loopModeSummary(context, session.loopMode),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.7),
                fontWeight: FontWeight.w600,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          displayName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w900,
            fontSize: 24,
            color: cs.onSurface,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 8),
        _SessionSubtitlePanel(session: session, provider: provider),
        const Spacer(),
        _ProgressBar(
          key: ValueKey(session.id),
          session: session,
          provider: provider,
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 84,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 390;
              final gap = compact ? 4.0 : 8.0;
              final skipIconSize = compact ? 38.0 : 44.0;
              final playIconSize = compact ? 56.0 : 64.0;
              final loadingSize = compact ? 28.0 : 32.0;

              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _ExpandableLoopOptions(
                    session: session,
                    provider: provider,
                    compact: compact,
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        constraints: BoxConstraints.tightFor(
                          width: compact ? 42 : 48,
                          height: compact ? 42 : 48,
                        ),
                        padding: EdgeInsets.zero,
                        onPressed: session.isLoading
                            ? null
                            : () {
                                HapticFeedback.lightImpact();
                                provider.seekSessionToPrev(session.id);
                              },
                        icon: Icon(
                          Icons.skip_previous_rounded,
                          size: skipIconSize,
                          color: cs.onSurface,
                        ),
                      ),
                      SizedBox(width: gap),
                      IconButton(
                        constraints: BoxConstraints.tightFor(
                          width: compact ? 58 : 68,
                          height: compact ? 58 : 68,
                        ),
                        padding: EdgeInsets.zero,
                        onPressed: session.isLoading
                            ? null
                            : () {
                                HapticFeedback.mediumImpact();
                                provider.toggleSessionPlayPause(session.id);
                              },
                        iconSize: playIconSize,
                        icon: _SwitcherSlot(
                          width: playIconSize,
                          height: playIconSize,
                          child: session.isLoading
                              ? SizedBox(
                                  key: const ValueKey<String>('loading'),
                                  width: loadingSize,
                                  height: loadingSize,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    color: cs.onSurface,
                                  ),
                                )
                              : Icon(
                                  session.state.playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  key: ValueKey<IconData>(
                                    session.state.playing
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                  ),
                                  size: playIconSize,
                                  color: cs.onSurface,
                                ),
                        ),
                      ),
                      SizedBox(width: gap),
                      IconButton(
                        constraints: BoxConstraints.tightFor(
                          width: compact ? 42 : 48,
                          height: compact ? 42 : 48,
                        ),
                        padding: EdgeInsets.zero,
                        onPressed: session.isLoading
                            ? null
                            : () {
                                HapticFeedback.lightImpact();
                                provider.seekSessionToNext(session.id);
                              },
                        icon: Icon(
                          Icons.skip_next_rounded,
                          size: skipIconSize,
                          color: cs.onSurface,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _SessionVolumeButton(
                        session: session,
                        provider: provider,
                        compact: compact,
                      ),
                      SizedBox(width: compact ? 0 : 4),
                      IconButton(
                        constraints: BoxConstraints.tightFor(
                          width: compact ? 40 : 48,
                          height: compact ? 40 : 48,
                        ),
                        padding: EdgeInsets.zero,
                        onPressed: hasSiblings
                            ? () {
                                HapticFeedback.selectionClick();
                                _showTrackSwitcher(context);
                              }
                            : null,
                        tooltip: context.read<AppLanguageProvider>().tr(
                          'switch_audio',
                        ),
                        icon: Icon(
                          Icons.queue_music_rounded,
                          size: compact ? 22 : 24,
                          color: cs.onSurface,
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  void _showTrackSwitcher(BuildContext context) {
    final i18n = context.read<AppLanguageProvider>();
    final siblings = widget.provider.tracksInSameGroup(
      widget.session.currentTrackPath,
    );
    if (siblings.isEmpty) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.5,
        ),
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          cacheExtent: 480,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          itemCount: siblings.length,
          itemBuilder: (_, i) {
          final track = siblings[i];
          final isCurrent = track.path == widget.session.currentTrackPath;
          return ListTile(
            leading: Icon(
              isCurrent ? Icons.volume_up_rounded : Icons.music_note_rounded,
            ),
            title: Text(track.displayName, maxLines: 2),
            trailing: isCurrent ? const Icon(Icons.check_rounded) : null,
            onTap: () {
              Feedback.forTap(ctx);
              Navigator.of(ctx).pop();
              if (!isCurrent) {
                widget.provider.switchSessionTrack(
                  widget.session.id,
                  track.path,
                );
                showAppSnackBar(
                  context,
                  i18n.tr('switch_audio'),
                  tone: AppFeedbackTone.success,
                  icon: Icons.queue_music_rounded,
                );
              }
            },
          );
        },
      ),
    ));
  }
}

class _SessionHeroArtwork extends StatelessWidget {
  const _SessionHeroArtwork({
    required this.height,
    required this.coverPathFuture,
    required this.title,
    required this.folderName,
    required this.isPlaying,
  });

  final double height;
  final Future<String?> coverPathFuture;
  final String title;
  final String folderName;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final availableWidth = max(1.0, MediaQuery.sizeOf(context).width - 32);
    final dpr = min(MediaQuery.devicePixelRatioOf(context), 2.0);
    final cacheWidth = max(1, (availableWidth * dpr).round());
    final cacheHeight = max(1, (height * dpr).round());

    Widget fallback() {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              cs.primaryContainer,
              cs.tertiaryContainer.withValues(alpha: 0.9),
            ],
          ),
        ),
        child: Center(
          child: Icon(
            Icons.photo_album_rounded,
            size: 56,
            color: cs.onPrimaryContainer,
          ),
        ),
      );
    }

    return Center(
      child: Container(
        width: height,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 40,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: Stack(
            fit: StackFit.expand,
            children: [
              FutureBuilder<String?>(
                future: coverPathFuture,
                builder: (context, snapshot) {
                  final coverPath = snapshot.data;
                  if (coverPath == null || coverPath.isEmpty) {
                    return fallback();
                  }
                  return RepaintBoundary(
                    child: Image.file(
                      File(coverPath),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      cacheWidth: cacheWidth,
                      cacheHeight: cacheHeight,
                      errorBuilder: (_, _, _) => fallback(),
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
    );
  }
}

class _SessionCoverThumbnail extends StatelessWidget {
  const _SessionCoverThumbnail({
    required this.coverPathFuture,
    required this.title,
  });

  final Future<String?> coverPathFuture;
  final String title;

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
            size: 28,
            color: cs.onPrimaryContainer,
          ),
        ),
      );
    }

    return SizedBox(
      width: 78,
      height: 78,
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
      onPressed: onPressed,
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

class _ExpandableLoopOptions extends StatefulWidget {
  const _ExpandableLoopOptions({
    required this.session,
    required this.provider,
    this.compact = false,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final bool compact;

  @override
  State<_ExpandableLoopOptions> createState() => _ExpandableLoopOptionsState();
}

class _ExpandableLoopOptionsState extends State<_ExpandableLoopOptions>
    with SingleTickerProviderStateMixin {
  final LayerLink _anchorLink = LayerLink();
  OverlayEntry? _overlayEntry;
  late final AnimationController _expandController;

  bool get _expanded => _overlayEntry != null;

  bool _isCross(SessionLoopMode mode) {
    return mode == SessionLoopMode.crossRandom ||
        mode == SessionLoopMode.crossSequential;
  }

  bool _isShuffle(SessionLoopMode mode) {
    return mode == SessionLoopMode.crossRandom ||
        mode == SessionLoopMode.folderRandom;
  }

  SessionLoopMode get _effectiveNonSingleMode {
    if (widget.session.loopMode == SessionLoopMode.single) {
      return widget.session.nonSingleLoopMode;
    }
    return widget.session.loopMode;
  }

  bool get _singleActive => widget.session.loopMode == SessionLoopMode.single;
  bool get _shuffleActive => _isShuffle(_effectiveNonSingleMode);
  bool get _crossFolderActive => _isCross(_effectiveNonSingleMode);

  bool get _shuffleButtonHighlighted => !_singleActive;
  bool get _scopeButtonHighlighted => !_singleActive;

  IconData get _orderIcon =>
      _shuffleActive ? Icons.shuffle_rounded : Icons.repeat_rounded;
  IconData get _scopeIcon =>
      _crossFolderActive ? Icons.folder_copy_rounded : Icons.folder_rounded;

  Widget _collapsedCompositeIcon(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      key: ValueKey<String>(
        'composite_${_orderIcon.codePoint}_${_scopeIcon.codePoint}',
      ),
      width: 20,
      height: 20,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Opacity(
              opacity: 0.28,
              child: Icon(_scopeIcon, size: 20, color: cs.onSurfaceVariant),
            ),
          ),
          Center(child: Icon(_orderIcon, size: 13, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      reverseDuration: const Duration(milliseconds: 260),
    );
  }

  Future<void> _toggleExpanded() async {
    if (_expanded) {
      await _hideOverlay();
    } else {
      _showOverlay();
    }
  }

  void _showOverlay() {
    if (_overlayEntry != null) return;
    final overlay = Overlay.of(context);
    _overlayEntry = OverlayEntry(builder: _buildOverlay);
    overlay.insert(_overlayEntry!);
    _expandController.forward(from: 0);
    setState(() {});
  }

  Future<void> _hideOverlay() async {
    if (_overlayEntry == null) return;
    await _expandController.reverse();
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _refreshImmediately(Future<void> future) async {
    _overlayEntry?.markNeedsBuild();
    if (mounted) {
      setState(() {});
    }
    await future;
    _overlayEntry?.markNeedsBuild();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _toggleSingleLoop() async {
    await _refreshImmediately(
      widget.provider.toggleSessionSingleLoop(widget.session.id),
    );
  }

  Future<void> _toggleShuffleLoop() async {
    final current = widget.session.loopMode == SessionLoopMode.single
        ? widget.session.nonSingleLoopMode
        : widget.session.loopMode;
    final isCrossFolder = _isCross(current);
    final isShuffle = _isShuffle(current);
    final nextMode = isShuffle
        ? (isCrossFolder
              ? SessionLoopMode.crossSequential
              : SessionLoopMode.folderSequential)
        : (isCrossFolder
              ? SessionLoopMode.crossRandom
              : SessionLoopMode.folderRandom);
    await _refreshImmediately(
      widget.provider.setSessionLoopMode(widget.session.id, nextMode),
    );
  }

  Future<void> _toggleCrossFolderLoop() async {
    final current = widget.session.loopMode == SessionLoopMode.single
        ? widget.session.nonSingleLoopMode
        : widget.session.loopMode;
    final isCrossFolder = _isCross(current);
    final isShuffle = _isShuffle(current);
    final nextMode = isCrossFolder
        ? (isShuffle
              ? SessionLoopMode.folderRandom
              : SessionLoopMode.folderSequential)
        : (isShuffle
              ? SessionLoopMode.crossRandom
              : SessionLoopMode.crossSequential);
    await _refreshImmediately(
      widget.provider.setSessionLoopMode(widget.session.id, nextMode),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              _hideOverlay();
            },
          ),
        ),
        CompositedTransformFollower(
          link: _anchorLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.center,
          followerAnchor: Alignment.bottomCenter,
          // The capsule bottom sits slightly below the button center so the
          // bottom action button stays locked to the collapsed position.
          offset: const Offset(0, 26),
          child: Material(
            color: Colors.transparent,
            child: AnimatedBuilder(
              animation: _expandController,
              builder: (context, _) {
                final containerProgress = Curves.easeOutCubic
                    .transform(_expandController.value)
                    .clamp(0.0, 1.0);

                Widget animatedBubble({
                  required IconData icon,
                  required bool active,
                  required VoidCallback onPressed,
                  required double start,
                  required double end,
                }) {
                  final progress = Interval(
                    start,
                    end,
                    curve: Curves.easeOutCubic,
                  ).transform(_expandController.value).clamp(0.0, 1.0);
                  return Opacity(
                    opacity: progress,
                    child: Transform.translate(
                      offset: Offset(0, (1 - progress) * 18),
                      child: Transform.scale(
                        scale: 0.82 + (progress * 0.18),
                        child: _LoopModeButton(
                          icon: icon,
                          active: active,
                          onPressed: onPressed,
                        ),
                      ),
                    ),
                  );
                }

                return Opacity(
                  opacity: 0.4 + (containerProgress * 0.6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHigh.withValues(alpha: 0.38),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: cs.outlineVariant.withValues(alpha: 0.92),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: cs.shadow.withValues(alpha: 0.18),
                              blurRadius: 16,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 4,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              animatedBubble(
                                icon: Icons.repeat_one_rounded,
                                active: _singleActive,
                                onPressed: _toggleSingleLoop,
                                start: 0.16,
                                end: 0.58,
                              ),
                              const SizedBox(height: 4),
                              animatedBubble(
                                icon: _orderIcon,
                                active: _shuffleButtonHighlighted,
                                onPressed: _toggleShuffleLoop,
                                start: 0.28,
                                end: 0.74,
                              ),
                              const SizedBox(height: 4),
                              animatedBubble(
                                icon: _scopeIcon,
                                active: _scopeButtonHighlighted,
                                onPressed: _toggleCrossFolderLoop,
                                start: 0.4,
                                end: 0.9,
                              ),
                              const SizedBox(height: 4),
                              _LoopModeButton(
                                iconWidget: _singleActive
                                    ? Icon(
                                        Icons.repeat_one_rounded,
                                        key: const ValueKey<String>('single_main'),
                                        size: 18,
                                        color: cs.primary,
                                      )
                                    : _collapsedCompositeIcon(context),
                                active: true,
                                onPressed: _toggleExpanded,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _expandController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _anchorLink,
      child: SizedBox(
        width: widget.compact ? 40 : 44,
        height: widget.compact ? 74 : 82,
        child: IgnorePointer(
          ignoring: _expanded,
          child: Opacity(
            opacity: _expanded ? 0 : 1,
            child: Align(
              child: _LoopModeButton(
                iconWidget: _singleActive
                    ? Icon(
                        Icons.repeat_one_rounded,
                        key: const ValueKey<String>('single_main_collapsed'),
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : _collapsedCompositeIcon(context),
                active: true,
                onPressed: _toggleExpanded,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatefulWidget {
  const _ProgressBar({
    super.key,
    required this.session,
    required this.provider,
  });

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastReportedPosition = Duration.zero;
  DateTime _lastReportTime = DateTime.now();
  bool _isDragging = false;
  double? _dragValueMs;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    if (_isDragging) return;
    if (mounted) setState(() {});
  }

  Duration _getSmoothPosition(Duration streamPosition, bool isPlaying) {
    if (!isPlaying) {
      _lastReportedPosition = streamPosition;
      _lastReportTime = DateTime.now();
      return streamPosition;
    }

    final now = DateTime.now();
    if (streamPosition != _lastReportedPosition) {
      _lastReportedPosition = streamPosition;
      _lastReportTime = now;
      return streamPosition;
    }

    final diff = now.difference(_lastReportTime);
    return streamPosition + diff;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration?>(
      stream: widget.session.durationStream,
      initialData: widget.session.duration,
      builder: (context, snapshot) {
        final duration = snapshot.data;
        return StreamBuilder<Duration>(
          stream: widget.session.positionStream,
          initialData: widget.session.position,
          builder: (context, snapshot) {
            return StreamBuilder<Duration>(
              stream: widget.session.bufferedPositionStream,
              initialData: widget.session.bufferedPosition,
              builder: (context, bufferedSnapshot) {
                final hasKnownDuration = duration != null;
                final effectiveDuration = duration ?? Duration.zero;
                final buffered = bufferedSnapshot.data ?? Duration.zero;
                final isPlaying = widget.session.state.playing;
                var position = _getSmoothPosition(
                  snapshot.data ?? Duration.zero,
                  isPlaying,
                );
                if (hasKnownDuration && position > effectiveDuration) {
                  position = effectiveDuration;
                }
                final durationMs = hasKnownDuration
                    ? max(1, effectiveDuration.inMilliseconds)
                    : max(
                        1,
                        max(position.inMilliseconds, buffered.inMilliseconds),
                      );
                final maxMillis = durationMs.toDouble();
                final basePositionMs = position.inMilliseconds
                    .clamp(0, durationMs)
                    .toDouble();
                final sliderValue =
                    (_isDragging
                            ? (_dragValueMs ?? basePositionMs)
                            : basePositionMs)
                        .clamp(0.0, maxMillis);
                final bufferedValue =
                    (_isDragging
                            ? max(buffered.inMilliseconds, sliderValue.round())
                            : buffered.inMilliseconds)
                        .clamp(0, durationMs)
                        .toDouble();
                final shownSeconds = hasKnownDuration
                    ? (sliderValue ~/ 1000).clamp(
                        0,
                        effectiveDuration.inSeconds,
                      )
                    : (sliderValue ~/ 1000);
                final remainingSeconds = hasKnownDuration
                    ? (effectiveDuration.inSeconds - shownSeconds).clamp(
                        0,
                        effectiveDuration.inSeconds,
                      )
                    : 0;
                final canSeek =
                    hasKnownDuration && effectiveDuration.inMilliseconds > 0;
                final cs = Theme.of(context).colorScheme;

                return Column(
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2.2,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                        activeTrackColor: cs.onSurface,
                        inactiveTrackColor: cs.onSurface.withValues(
                          alpha: 0.25,
                        ),
                        thumbColor: cs.onSurface,
                        overlayColor: cs.onSurface.withValues(alpha: 0.12),
                      ),
                      child: Slider(
                        max: maxMillis,
                        value: sliderValue,
                        secondaryTrackValue: bufferedValue,
                        onChangeStart: !canSeek
                            ? null
                            : (value) {
                                HapticFeedback.selectionClick();
                                setState(() {
                                  _isDragging = true;
                                  _dragValueMs = value;
                                });
                              },
                        onChanged: !canSeek
                            ? null
                            : (value) {
                                setState(() {
                                  _dragValueMs = value;
                                });
                              },
                        onChangeEnd: !canSeek
                            ? null
                            : (value) {
                                HapticFeedback.selectionClick();
                                setState(() {
                                  _isDragging = false;
                                  _dragValueMs = null;
                                });
                                widget.provider.seekSession(
                                  widget.session.id,
                                  Duration(milliseconds: value.round()),
                                );
                              },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _TimecodeLabel(text: _fmtSeconds(shownSeconds)),
                          _TimecodeLabel(
                            text: hasKnownDuration
                                ? '-${_fmtSeconds(remainingSeconds)}'
                                : '--:--',
                            alignEnd: true,
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  String _fmtSeconds(int totalSeconds) {
    final clamped = totalSeconds < 0 ? 0 : totalSeconds;
    final h = clamped ~/ 3600;
    final m = (clamped ~/ 60).remainder(60).toString().padLeft(2, '0');
    final s = clamped.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '${h.toString().padLeft(2, '0')}:$m:$s';
    return '$m:$s';
  }
}

class _SessionSubtitlePanel extends StatelessWidget {
  const _SessionSubtitlePanel({required this.session, required this.provider});

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SubtitleTrack?>(
      future: provider.subtitleTrackForPath(session.currentTrackPath),
      builder: (context, subtitleSnapshot) {
        final subtitleTrack = subtitleSnapshot.data;
        return StreamBuilder<Duration>(
          stream: session.positionStream,
          initialData: session.position,
          builder: (context, positionSnapshot) {
            final subtitleText = provider.subtitleTextForTrackAt(
              session.currentTrackPath,
              positionSnapshot.data ?? session.position,
              subtitleTrack: subtitleTrack,
            );
            if (subtitleText == null) {
              return const SizedBox.shrink();
            }
            return _SubtitleChip(text: subtitleText);
          },
        );
      },
    );
  }
}

class _SubtitleChip extends StatelessWidget {
  const _SubtitleChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: cs.onSurface.withValues(alpha: 0.85),
          fontWeight: FontWeight.w600,
          fontSize: 16,
          height: 1.3,
        ),
      ),
    );
  }
}

class _SessionVolumeSlider extends StatefulWidget {
  const _SessionVolumeSlider({required this.session, required this.provider});

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  State<_SessionVolumeSlider> createState() => _SessionVolumeSliderState();
}

class _SessionVolumeSliderState extends State<_SessionVolumeSlider> {
  static const Duration _previewCommitDelay = Duration(milliseconds: 48);

  double? _dragVolume;
  Timer? _previewCommitTimer;
  double? _queuedPreviewVolume;

  @override
  void didUpdateWidget(covariant _SessionVolumeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.id != widget.session.id) {
      _cancelPreviewCommit();
      _dragVolume = null;
    }
  }

  void _cancelPreviewCommit() {
    _previewCommitTimer?.cancel();
    _previewCommitTimer = null;
    _queuedPreviewVolume = null;
  }

  void _schedulePreviewCommit(double value) {
    _queuedPreviewVolume = value;
    if (_previewCommitTimer != null) return;
    _previewCommitTimer = Timer(_previewCommitDelay, () {
      final queued = _queuedPreviewVolume;
      _previewCommitTimer = null;
      _queuedPreviewVolume = null;
      if (queued == null) return;
      widget.provider.setSessionVolume(
        widget.session.id,
        queued,
        persist: false,
        notify: false,
      );
    });
  }

  @override
  void dispose() {
    _cancelPreviewCommit();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final volume = (_dragVolume ?? widget.session.volume).clamp(0.0, 1.0);
    final volumePercent = (volume * 100).round();

    return Row(
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeOutCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(scale: animation, child: child),
          ),
          child: Icon(
            volume == 0
                ? Icons.volume_off_rounded
                : volume < 0.45
                ? Icons.volume_down_rounded
                : Icons.volume_up_rounded,
            key: ValueKey<int>((volume * 10).round()),
            size: 20,
            color: cs.onSurfaceVariant,
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: Theme.of(context).sliderTheme.copyWith(
              trackHeight: 5,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8.5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              value: volume,
              onChangeStart: (value) {
                HapticFeedback.selectionClick();
                setState(() {
                  _dragVolume = value;
                });
              },
              onChanged: (value) {
                setState(() {
                  _dragVolume = value;
                });
                _schedulePreviewCommit(value);
              },
              onChangeEnd: (value) {
                HapticFeedback.selectionClick();
                _cancelPreviewCommit();
                setState(() {
                  _dragVolume = null;
                });
                widget.provider.setSessionVolume(widget.session.id, value);
              },
            ),
          ),
        ),
        SizedBox(
          width: 44,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 140),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeOutCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.18),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: Text(
              '$volumePercent%',
              key: ValueKey<int>(volumePercent),
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SessionVolumeButton extends StatefulWidget {
  const _SessionVolumeButton({
    required this.session,
    required this.provider,
    this.compact = false,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final bool compact;

  @override
  State<_SessionVolumeButton> createState() => _SessionVolumeButtonState();
}

class _SessionVolumeButtonState extends State<_SessionVolumeButton> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlay;

  void _toggleVolume() {
    if (_overlay != null) {
      _overlay?.remove();
      _overlay = null;
    } else {
      final overlay = Overlay.of(context);
      _overlay = OverlayEntry(
        builder: (context) => _VerticalVolumeSlider(
          link: _link,
          session: widget.session,
          provider: widget.provider,
          onClose: () {
            _overlay?.remove();
            _overlay = null;
            if (mounted) setState(() {});
          },
        ),
      );
      overlay.insert(_overlay!);
    }
    setState(() {});
  }

  @override
  void dispose() {
    _overlay?.remove();
    _overlay = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final volume = widget.session.volume;
    final icon = volume == 0
        ? Icons.volume_off_rounded
        : volume < 0.45
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;

    final cs = Theme.of(context).colorScheme;
    return CompositedTransformTarget(
      link: _link,
      child: IconButton(
        constraints: BoxConstraints.tightFor(
          width: widget.compact ? 40 : 48,
          height: widget.compact ? 40 : 48,
        ),
        padding: EdgeInsets.zero,
        onPressed: _toggleVolume,
        icon: Icon(icon, size: widget.compact ? 19 : 20, color: cs.onSurface),
      ),
    );
  }
}

class _VerticalVolumeSlider extends StatefulWidget {
  const _VerticalVolumeSlider({
    required this.link,
    required this.session,
    required this.provider,
    required this.onClose,
  });

  final LayerLink link;
  final PlaybackSession session;
  final AudioProvider provider;
  final VoidCallback onClose;

  @override
  State<_VerticalVolumeSlider> createState() => _VerticalVolumeSliderState();
}

class _VerticalVolumeSliderState extends State<_VerticalVolumeSlider> {
  double? _dragVolume;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final volume = (_dragVolume ?? widget.session.volume).clamp(0.0, 1.0);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: const ColoredBox(color: Colors.transparent),
          ),
        ),
        CompositedTransformFollower(
          link: widget.link,
          followerAnchor: Alignment.bottomCenter,
          targetAnchor: Alignment.topCenter,
          offset: const Offset(0, -8),
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 44,
              height: 180,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: 0.8),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                children: [
                  Text(
                    '${(volume * 100).round()}%',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 6,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 8,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 14,
                          ),
                        ),
                        child: Slider(
                          value: volume,
                          onChanged: (v) {
                            setState(() => _dragVolume = v);
                            widget.provider.setSessionVolume(
                              widget.session.id,
                              v,
                              persist: false,
                            );
                          },
                          onChangeEnd: (v) {
                            setState(() => _dragVolume = null);
                            widget.provider.setSessionVolume(
                              widget.session.id,
                              v,
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TimerCountdownCapsule extends StatelessWidget {
  const _TimerCountdownCapsule({
    required this.remaining,
    required this.active,
    required this.onTap,
  });

  final Duration remaining;
  final bool active;
  final VoidCallback? onTap;

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '${h.toString().padLeft(2, '0')}:$m:$s';
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasRemaining = remaining > Duration.zero;

    return Material(
      color: cs.primaryContainer.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () {
          Feedback.forTap(context);
          HapticFeedback.selectionClick();
          onTap?.call();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: cs.primary.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                active
                    ? Icons.timer_rounded
                    : hasRemaining
                    ? Icons.timer_rounded
                    : Icons.alarm_off_rounded,
                size: 14,
                color: cs.onPrimaryContainer,
              ),
              const SizedBox(width: 5),
              Text(
                hasRemaining ? _fmt(remaining) : '00:00',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: cs.onPrimaryContainer,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimecodeLabel extends StatelessWidget {
  const _TimecodeLabel({required this.text, this.alignEnd = false});

  final String text;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Text(
      text,
      textAlign: alignEnd ? TextAlign.end : TextAlign.start,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: cs.onSurface.withValues(alpha: 0.7),
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
