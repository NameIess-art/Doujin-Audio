import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart' hide Consumer;

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/audio_provider_riverpod.dart';
import '../services/audio_state_services.dart';
import '../services/subtitle_parser.dart';
import '../providers/subtitle_settings_provider.dart';
import '../widgets/floating_subtitle_window.dart';
import '../widgets/marquee_text.dart';
import '../widgets/app_feedback.dart';
import '../widgets/async_cover_image.dart';
import '../widgets/app_transitions.dart';
import '../widgets/confirm_action_dialog.dart';
import '../widgets/content_bound_reorder_area.dart';
import '../widgets/mobile_overlay_inset.dart';
import '../widgets/reorderable_hold_drag_listener.dart';
import '../widgets/swipe_reveal_card.dart';
import '../widgets/top_page_header.dart';
import '../widgets/unified_popup_menu.dart';

part 'playlist_tab_list.dart';
part 'playlist_tab_detail.dart';
part 'playlist_tab_detail_content.dart';
part 'playlist_tab_media.dart';
part 'playlist_tab_loop.dart';
part 'playlist_tab_progress.dart';
part 'playlist_tab_volume_timer.dart';

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

class PlaylistTab extends ConsumerStatefulWidget {
  const PlaylistTab({super.key, this.onTimerTap});

  final VoidCallback? onTimerTap;

  @override
  ConsumerState<PlaylistTab> createState() => _PlaylistTabState();
}

class _PlaylistTabState extends ConsumerState<PlaylistTab>
    with AutomaticKeepAliveClientMixin {
  final GlobalKey _headerKey = GlobalKey();
  double _headerHeight = 90;
  final ScrollController _scrollController = ScrollController();
  ValueListenable<int?>? _scrollToTopListenable;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _measureHeader();
        _scrollToTopListenable = ref
            .read(audioProviderFacadeProvider)
            .scrollToTopTabListenable;
        _scrollToTopListenable?.addListener(_handleScrollToTopSignal);
      }
    });
  }

  void _handleScrollToTopSignal() {
    if (!mounted) return;
    final index = _scrollToTopListenable?.value;
    if (index == 1) {
      // 1 is PlaylistTab
      _jumpPlaylistToTop();
    }
  }

  void _jumpPlaylistToTop() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
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
  void dispose() {
    _scrollToTopListenable?.removeListener(_handleScrollToTopSignal);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final i18n = context.watch<AppLanguageProvider>();
    final provider = ref.read(audioProviderFacadeProvider);
    final bottomInset = MobileOverlayInset.of(context);
    final playbackState =
        ref.watch(playbackStateProvider).valueOrNull ??
        const PlaybackStateSliceData();
    final sessions = playbackState.activeSessions;
    final playingCount = playbackState.playingSessionCount;
    final sessionSummary =
        '${i18n.tr('sessions_count', {'count': sessions.length})} · '
        '${i18n.tr('playing_count', {'count': playingCount})}';
    final timerState =
        ref.watch(timerStateProvider).valueOrNull ??
        const TimerStateSliceData();
    final timerDuration = timerState.duration;
    final timerRemaining = timerState.remaining;
    final timerActive = timerState.active;
    final topTotalHeight = _headerHeight + 4;
    final listBottomInset = bottomInset + 8;
    final viewportHeight = MediaQuery.sizeOf(context).height;
    // Massive cacheExtent to ensure items are pre-rendered far outside the viewport.
    final listCacheExtent = (topTotalHeight + listBottomInset + 1200)
        .clamp(viewportHeight * 3.0, viewportHeight * 5.0)
        .toDouble();

    return Stack(
      children: [
        // Viewport restricted to content area so drag-to-reorder auto-scroll
        // triggers at content edges rather than screen edges.
        ContentBoundReorderArea(
          headerHeight: _headerHeight,
          bottomInset: listBottomInset,
          child: sessions.isEmpty
              ? _SessionsEmptyState(bottomInset: 0, topInset: 4)
              : ReorderableListView.builder(
                  scrollController: _scrollController,
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                  cacheExtent: listCacheExtent,
                  clipBehavior: Clip.none,
                  buildDefaultDragHandles: false,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  onReorder: provider.reorderSessions,
                  onReorderStart: (index) =>
                      unawaited(HapticFeedback.heavyImpact()),
                  proxyDecorator: (child, index, animation) =>
                      _buildReorderProxy(context, child, animation),
                  itemCount: sessions.length + 1,
                  itemBuilder: (context, index) {
                    if (index == sessions.length) {
                      return const SizedBox(
                        key: ValueKey('bottom_spacing'),
                        height: 12,
                      );
                    }
                    final session = sessions[index];
                    return ReorderableHoldDragStartListener(
                      key: ValueKey(session.id),
                      index: index,
                      child: RepaintBoundary(
                        child: _SessionListCard(
                          session: session,
                          provider: provider,
                          onOpen: () => _openSessionDetail(context, session.id),
                        ),
                      ),
                    );
                  },
                ),
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

  Widget _buildReorderProxy(
    BuildContext context,
    Widget child,
    Animation<double> animation,
  ) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final double animValue = Curves.easeInOut.transform(animation.value);
        final double scale = 1.0 + (0.012 * animValue);
        final double elevation = 3.0 * animValue;

        return Transform.scale(
          scale: scale,
          child: Material(
            elevation: elevation,
            color: Colors.transparent,
            shadowColor: Theme.of(
              context,
            ).colorScheme.shadow.withValues(alpha: 0.12),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
