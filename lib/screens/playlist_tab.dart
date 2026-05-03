import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
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
import '../widgets/top_page_header.dart';

Future<String?> _coverFutureForTrack(AudioProvider provider, MusicTrack? track) {
  if (track == null) {
    return Future<String?>.value();
  }
  return provider.coverPathFutureForTrack(track);
}

PageRoute<void> buildSessionDetailRoute({required String sessionId}) {
  return buildAppOverlayRoute(
    child: SessionDetailPage(sessionId: sessionId),
    beginOffset: const Offset(0, 0.028),
    reverseDuration: Duration.zero,
  );
}

class PlaylistTab extends StatefulWidget {
  const PlaylistTab({super.key});

  @override
  State<PlaylistTab> createState() => _PlaylistTabState();
}

class _PlaylistTabState extends State<PlaylistTab> {
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

    return SafeArea(
      child: Column(
        children: [
          TopPageHeader(
            icon: Icons.graphic_eq_rounded,
            title: i18n.tr('playback_sessions'),
            subtitle: sessionSummary,
            subtitleMaxLines: 1,
            subtitleFontSize: 9,
            fitSubtitleToWidth: true,
            trailing: SizedBox(
              width: 112,
              height: 44,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
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
            bottomSpacing: 10,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          ),
          Expanded(
            child: sessions.isEmpty
                ? _SessionsEmptyState(bottomInset: bottomInset)
                : ReorderableListView.builder(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, bottomInset),
                    cacheExtent: 720,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    buildDefaultDragHandles: false,
                    onReorder: provider.reorderSessions,
                    itemCount: sessions.length,
                    itemBuilder: (context, index) {
                      final session = sessions[index];
                      final track = provider.trackByPath(
                        session.currentTrackPath,
                      );
                      return ReorderableDelayedDragStartListener(
                        key: ValueKey(session.id),
                        index: index,
                        child: _SessionListCard(
                          session: session,
                          provider: provider,
                          coverPathFuture: _coverFutureForTrack(
                            provider,
                            track,
                          ),
                          onOpen: () => _openSessionDetail(context, session.id),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
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
  static const double _actionWidth = 128;

  double _revealedWidth = 0;

  bool get _isOpen => _revealedWidth > (_actionWidth * 0.5);

  @override
  void didUpdateWidget(covariant _SessionListCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.id != widget.session.id && _revealedWidth != 0) {
      _revealedWidth = 0;
    }
  }

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

  void _closeActionPane() {
    if (_revealedWidth == 0) return;
    setState(() {
      _revealedWidth = 0;
    });
  }

  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    final nextWidth = (_revealedWidth - details.delta.dx).clamp(
      0.0,
      _actionWidth,
    );
    if (nextWidth == _revealedWidth) return;
    if (_revealedWidth == 0 && nextWidth > 0) {
      HapticFeedback.selectionClick();
    }
    setState(() {
      _revealedWidth = nextWidth;
    });
  }

  void _handleHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final shouldOpen =
        velocity < -180 || (velocity.abs() < 180 && _revealedWidth > 44);
    setState(() {
      _revealedWidth = shouldOpen ? _actionWidth : 0;
    });
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
    final revealProgress = (_revealedWidth / _actionWidth).clamp(0.0, 1.0);

    return StreamBuilder<PlayerState>(
      stream: session.stateStream,
      initialData: session.state,
      builder: (context, snapshot) {
        final playerState = snapshot.data ?? session.state;
        final isPlaying = playerState.playing;
        final cardShape = RoundedRectangleBorder(
          side: BorderSide(
            color: isPlaying
                ? cs.primary.withValues(alpha: 0.3)
                : cs.outlineVariant.withValues(alpha: 0.82),
          ),
          borderRadius: BorderRadius.circular(22),
        );

        return TapRegion(
          onTapOutside: (_) => _closeActionPane(),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: _handleHorizontalDragUpdate,
              onHorizontalDragEnd: _handleHorizontalDragEnd,
              child: SizedBox(
                height: 88,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              cs.errorContainer.withValues(alpha: 0.94),
                              cs.errorContainer.withValues(alpha: 0.82),
                            ],
                          ),
                          shape: cardShape,
                        ),
                        child: Stack(
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  left: 18,
                                  right: 86,
                                ),
                                child: AnimatedOpacity(
                                  opacity: 0.24 + (revealProgress * 0.76),
                                  duration: const Duration(milliseconds: 160),
                                  curve: Curves.easeOutCubic,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: cs.error.withValues(
                                            alpha: 0.12,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          border: Border.all(
                                            color: cs.error.withValues(
                                              alpha: 0.18,
                                            ),
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.swipe_left_rounded,
                                              size: 14,
                                              color: cs.error,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              i18n.tr('remove'),
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .labelMedium
                                                  ?.copyWith(
                                                    color: cs.error,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        i18n.tr('remove_audio'),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: cs.onErrorContainer,
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 14),
                                child: AnimatedScale(
                                  scale: 0.92 + (revealProgress * 0.08),
                                  duration: const Duration(milliseconds: 180),
                                  curve: Curves.easeOutBack,
                                  child: IconButton.filled(
                                    onPressed: () {
                                      Feedback.forTap(context);
                                      HapticFeedback.mediumImpact();
                                      _closeActionPane();
                                      _confirmRemoveSession(context);
                                    },
                                    style: IconButton.styleFrom(
                                      backgroundColor: cs.error,
                                      foregroundColor: cs.onError,
                                      minimumSize: const Size(54, 54),
                                      maximumSize: const Size(54, 54),
                                    ),
                                    icon: const Icon(
                                      Icons.delete_outline_rounded,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      left: -_revealedWidth,
                      right: _revealedWidth,
                      top: 0,
                      bottom: 0,
                      child: Material(
                        color: Colors.transparent,
                        child: Card(
                          margin: EdgeInsets.zero,
                          clipBehavior: Clip.antiAlias,
                          shape: cardShape,
                          color: isPlaying
                              ? cs.surfaceContainerLow
                              : cs.surfaceContainer,
                          elevation: 0,
                          shadowColor: Colors.transparent,
                          child: InkWell(
                            onTap: _isOpen
                                ? _closeActionPane
                                : () {
                                    Feedback.forTap(context);
                                    widget.onOpen();
                                  },
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
                              child: Row(
                                children: [
                                  _SessionCoverThumbnail(
                                    coverPathFuture: provider
                                        .coverPathFutureForTrack(track),
                                    title: displayName,
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          folderName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: cs.onSurfaceVariant,
                                                fontWeight: FontWeight.w600,
                                                fontSize: 10.2,
                                              ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          displayName,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w900,
                                                fontSize: 14,
                                                height: 1.12,
                                              ),
                                        ),
                                        const SizedBox(height: 6),
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
                                            provider.toggleSessionPlayPause(
                                              session.id,
                                            );
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
                                            : cs.outlineVariant.withValues(
                                                alpha: 0.72,
                                              ),
                                      ),
                                    ),
                                    icon: _SwitcherSlot(
                                      width: 22,
                                      height: 22,
                                      duration: const Duration(
                                        milliseconds: 150,
                                      ),
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
                    if (_isOpen)
                      Positioned.fill(
                        right: _actionWidth,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: _closeActionPane,
                        ),
                      ),
                    if (_revealedWidth > 0)
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: true,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                color: cs.outlineVariant.withValues(
                                  alpha: 0.18,
                                ),
                              ),
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
    final heroHeight = min(300.0, max(210.0, mediaSize.height * 0.34));
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
    final shouldDismiss = _dismissController.value > 0.18 || velocity > 900;
    if (shouldDismiss) {
      await _animateDismissToEnd(velocity: velocity);
      if (mounted) {
        navigator.maybePop();
      }
      return;
    }
    await _animateDismissBack();
  }

  Future<void> _animateDismissToEnd({double velocity = 0}) {
    final remaining = (1 - _dismissController.value).clamp(0.0, 1.0);
    final velocityFactor = (velocity.abs() / 2200).clamp(0.0, 1.0);
    final durationMs = lerpDouble(170, 82, velocityFactor)! * remaining;
    return _dismissController.animateTo(
      1,
      duration: Duration(milliseconds: durationMs.round().clamp(72, 170)),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _animateDismissBack() {
    final progress = _dismissController.value.clamp(0.0, 1.0);
    final durationMs = lerpDouble(90, 190, progress)!;
    return _dismissController.animateBack(
      0,
      duration: Duration(milliseconds: durationMs.round().clamp(90, 190)),
      curve: Curves.easeOutCubic,
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
    final coverPathFuture = _coverFutureForTrack(
      provider,
      track,
    );
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
              MediaQuery.sizeOf(context).height * 0.54 * dismissProgress;
          final enterOffset = (1 - enterProgress) * 38;
          final backdropOpacity =
              (enterProgress * (1 - (dismissProgress * 0.94))).clamp(0.0, 1.0);

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
                  child: Opacity(
                    opacity: backdropOpacity,
                    child: const _SessionDetailBackdrop(),
                  ),
                ),
              ),
              Transform.translate(
                offset: Offset(0, enterOffset + dragDistance),
                child: child,
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
                  Navigator.of(context).maybePop();
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
  const _SessionDetailBackdrop();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                cs.surface.withValues(alpha: 0.08),
                cs.scrim.withValues(alpha: 0.08),
                cs.scrim.withValues(alpha: 0.14),
              ],
            ),
          ),
        ),
        ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: SizedBox.expand(),
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
      color: Colors.transparent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [cs.surface, cs.surfaceContainerLow, cs.surface],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final heroHeight = min(
                300.0,
                max(210.0, constraints.maxHeight * 0.34),
              );

              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Spacer(),
                        IconButton(
                          onPressed: () {
                            Feedback.forTap(context);
                            onClose();
                          },
                          icon: const Icon(Icons.expand_more_rounded, size: 28),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    RepaintBoundary(
                      child: _SessionHeroArtwork(
                        height: heroHeight,
                        coverPathFuture: coverPathFuture,
                        title: '',
                        folderName: '',
                        isPlaying: session.state.playing,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Expanded(
                      child: _SessionDetailContent(
                        session: session,
                        provider: provider,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
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
        Text(
          folderName,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          displayName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w900,
            fontSize: 20,
            height: 1,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _loopModeSummary(context, session.loopMode),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        _ProgressBar(session: session, provider: provider),
        const SizedBox(height: 14),
        SizedBox(
          height: 82,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: _ExpandableLoopOptions(
                  session: session,
                  provider: provider,
                ),
              ),
              Align(
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton.filledTonal(
                      onPressed: session.isLoading
                          ? null
                          : () {
                              Feedback.forTap(context);
                              provider.seekSessionToPrev(session.id);
                            },
                      icon: const Icon(Icons.skip_previous_rounded, size: 24),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(44, 44),
                        maximumSize: const Size(44, 44),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 74,
                      height: 74,
                      child: FilledButton(
                        onPressed: session.isLoading
                            ? null
                            : () {
                                Feedback.forTap(context);
                                provider.toggleSessionPlayPause(session.id);
                              },
                        style: FilledButton.styleFrom(
                          shape: const CircleBorder(),
                          padding: EdgeInsets.zero,
                        ),
                        child: _SwitcherSlot(
                          width: 42,
                          height: 42,
                          duration: const Duration(milliseconds: 150),
                          child: session.isLoading
                              ? const SizedBox(
                                  key: ValueKey<String>('loading'),
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
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
                                  size: 42,
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: session.isLoading
                          ? null
                          : () {
                              Feedback.forTap(context);
                              provider.seekSessionToNext(session.id);
                            },
                      icon: const Icon(Icons.skip_next_rounded, size: 24),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(44, 44),
                        maximumSize: const Size(44, 44),
                      ),
                    ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: IconButton.filledTonal(
                  onPressed: hasSiblings
                      ? () {
                          Feedback.forTap(context);
                          _showTrackSwitcher(context);
                        }
                      : null,
                  tooltip: context.read<AppLanguageProvider>().tr(
                    'switch_audio',
                  ),
                  icon: const Icon(Icons.queue_music_rounded, size: 20),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    maximumSize: const Size(44, 44),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _SessionVolumeSlider(session: session, provider: provider),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _SessionSubtitlePanel(session: session, provider: provider),
        const Spacer(),
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
      builder: (ctx) => ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.only(top: 16, bottom: 24),
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
    );
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

    return SizedBox(
      height: height,
      child: ClipRRect(
        clipBehavior: Clip.hardEdge,
        borderRadius: BorderRadius.circular(34),
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
                    filterQuality: FilterQuality.none,
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
                      Colors.black.withValues(alpha: 0.12),
                      Colors.black.withValues(alpha: 0.03),
                      Colors.black.withValues(alpha: 0.18),
                    ],
                    stops: const [0, 0.48, 1],
                  ),
                ),
              ),
            ),
          ],
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          Icon(
            icon,
            size: 12,
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
                color: cs.onSurfaceVariant.withValues(alpha: 0.65),
                fontSize: 9,
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
    required this.icon,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
        child: Icon(
          icon,
          key: ValueKey<IconData>(icon),
          size: 18,
          color: active ? cs.primary : cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ExpandableLoopOptions extends StatefulWidget {
  const _ExpandableLoopOptions({required this.session, required this.provider});

  final PlaybackSession session;
  final AudioProvider provider;

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

  bool get _singleActive => widget.session.loopMode == SessionLoopMode.single;
  bool get _shuffleActive => _isShuffle(widget.session.loopMode);
  bool get _crossFolderActive => _isCross(widget.session.loopMode);

  IconData get _mainIcon {
    if (_singleActive) return Icons.repeat_one_rounded;
    if (_shuffleActive) return Icons.shuffle_rounded;
    return _crossFolderActive
        ? Icons.folder_copy_rounded
        : Icons.repeat_rounded;
  }

  @override
  void initState() {
    super.initState();
    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      reverseDuration: const Duration(milliseconds: 220),
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
                    curve: Curves.easeOutBack,
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
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh.withValues(alpha: 0.96),
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
                            icon: _shuffleActive
                                ? Icons.shuffle_rounded
                                : Icons.repeat_rounded,
                            active: _shuffleActive,
                            onPressed: _toggleShuffleLoop,
                            start: 0.28,
                            end: 0.74,
                          ),
                          const SizedBox(height: 4),
                          animatedBubble(
                            icon: _crossFolderActive
                                ? Icons.folder_copy_rounded
                                : Icons.folder_rounded,
                            active: _crossFolderActive,
                            onPressed: _toggleCrossFolderLoop,
                            start: 0.4,
                            end: 0.9,
                          ),
                          const SizedBox(height: 4),
                          _LoopModeButton(
                            icon: _mainIcon,
                            active: true,
                            onPressed: _toggleExpanded,
                          ),
                        ],
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
        width: 44,
        height: 82,
        child: IgnorePointer(
          ignoring: _expanded,
          child: Opacity(
            opacity: _expanded ? 0 : 1,
            child: Align(
              alignment: Alignment.center,
              child: _LoopModeButton(
                icon: _mainIcon,
                active: _singleActive || _shuffleActive || _crossFolderActive,
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
  const _ProgressBar({required this.session, required this.provider});

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  double? _dragValueMs;
  bool _isDragging = false;

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
                var position = snapshot.data ?? Duration.zero;
                if (hasKnownDuration && position > effectiveDuration) {
                  position = effectiveDuration;
                }

                final buffered = bufferedSnapshot.data ?? Duration.zero;
                final durationMs = hasKnownDuration
                    ? max(1, effectiveDuration.inMilliseconds)
                    : max(1, max(position.inMilliseconds, buffered.inMilliseconds));
                final maxMillis = durationMs.toDouble();
                final basePositionMs = position.inMilliseconds
                    .clamp(0, durationMs)
                    .toDouble();
                final sliderValue = (_isDragging
                        ? (_dragValueMs ?? basePositionMs)
                        : basePositionMs)
                    .clamp(0.0, maxMillis);
                final bufferedValue = (_isDragging
                        ? max(buffered.inMilliseconds, sliderValue.round())
                        : buffered.inMilliseconds)
                    .clamp(0, durationMs)
                    .toDouble();
                final shownPosition = Duration(
                  milliseconds: sliderValue.round().clamp(0, durationMs),
                );
                final remaining = hasKnownDuration
                    ? (effectiveDuration - shownPosition)
                    : Duration.zero;
                final canSeek = hasKnownDuration && effectiveDuration.inMilliseconds > 0;

                return Column(
                  children: [
                    SliderTheme(
                      data: Theme.of(context).sliderTheme.copyWith(
                        trackHeight: 5,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 8.5,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 16,
                        ),
                      ),
                      child: Slider(
                        min: 0,
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
                          _TimecodeLabel(text: _fmt(shownPosition)),
                          _TimecodeLabel(
                            text: hasKnownDuration
                                ? '-${_fmt(remaining.isNegative ? Duration.zero : remaining)}'
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

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
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
    const accent = Color(0xFFFF2D55);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.12),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: cs.onSurface,
          fontWeight: FontWeight.w700,
          height: 1.18,
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
              min: 0,
              max: 1,
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
        color: cs.onSurfaceVariant,
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
