import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart' hide Consumer;

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/audio_provider_riverpod.dart';
import '../providers/subtitle_settings_provider.dart';
import '../services/audio_state_services.dart';
import '../services/path_display.dart';
import '../services/path_matcher.dart';
import '../services/permission_action_controller.dart';
import '../services/subtitle_parser.dart';
import '../services/subtitle_overlay_controller.dart';
import '../services/time_text_formatters.dart';
import '../services/ui_interaction_coordinator.dart';
import '../theme/app_design_tokens.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_transitions.dart';
import '../widgets/async_cover_image.dart';
import '../widgets/confirm_action_dialog.dart';
import '../widgets/content_bound_reorder_area.dart';
import '../widgets/library_like_cards.dart';
import '../widgets/marquee_text.dart';
import '../widgets/mobile_overlay_inset.dart';
import '../widgets/playback_position_ui_gate.dart';
import '../widgets/reorder_auto_scroller.dart';
import '../widgets/scroll_activity_gate.dart';
import '../widgets/swipe_reveal_card.dart';
import '../widgets/target_countdown_builder.dart';
import '../widgets/top_page_header.dart';
import '../widgets/unified_popup_menu.dart';
import '../widgets/unified_dropdown.dart';
import '../models/asmr_models.dart';
import 'audio_detail_sheet.dart';
import 'asmr_work_detail_sheet.dart';
import 'screen_view_models.dart';
import 'timer_tab.dart';

part 'playlist_tab_list.dart';
part 'playlist_tab_detail.dart';
part 'playlist_tab_detail_content.dart';
part 'playlist_tab_media.dart';
part 'playlist_tab_loop.dart';
part 'playlist_tab_progress.dart';
part 'playlist_tab_segments.dart';
part 'playlist_tab_volume_timer.dart';
part 'playlist_tab_queue.dart';

// Four 48px Material tap targets plus the loop capsule padding and gaps.
const double _sessionDetailCapsuleWidth = 52;
const double _sessionDetailCapsuleHeight = 212;
const double _sessionDetailCapsuleAnchorOffsetY = 26;

Future<String?> _coverFutureForTrack(
  AudioProvider provider,
  MusicTrack? track, {
  bool cachedOnly = false,
}) {
  if (track == null) {
    return Future<String?>.value();
  }
  if (cachedOnly) {
    return SynchronousFuture<String?>(
      provider.resolvedCoverPathForTrack(track),
    );
  }
  return provider.coverPathFutureForTrack(track);
}

PageRoute<void> buildSessionDetailRoute({required String sessionId}) {
  return _SessionDetailRoute(sessionId: sessionId);
}

class _SessionDetailRoute extends PageRoute<void> {
  _SessionDetailRoute({required this.sessionId}) {
    _revealBehindNotifier.addListener(_handleRevealBehindChanged);
  }

  final String sessionId;
  final ValueNotifier<bool> _revealBehindNotifier = ValueNotifier<bool>(false);

  void _handleRevealBehindChanged() {
    if (overlayEntries.isNotEmpty) {
      overlayEntries.first.opaque = opaque;
    }
    changedInternalState();
  }

  @override
  bool get opaque => !_revealBehindNotifier.value;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return SessionDetailPage(
      sessionId: sessionId,
      revealBehindNotifier: _revealBehindNotifier,
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }

  @override
  void dispose() {
    _revealBehindNotifier.removeListener(_handleRevealBehindChanged);
    _revealBehindNotifier.dispose();
    super.dispose();
  }
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
  bool _isReordering = false;
  PlaylistListState? _reorderSnapshot;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _measureHeader();
      _scrollToTopListenable = ref
          .read(audioProviderFacadeProvider)
          .scrollToTopTabListenable;
      _scrollToTopListenable?.addListener(_handleScrollToTopSignal);
    });
  }

  void _handleScrollToTopSignal() {
    if (!mounted) return;
    if (_scrollToTopListenable?.value == 2) {
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
    if (box == null || !mounted) return;
    final nextHeight = box.size.height;
    if (nextHeight > 0 && nextHeight != _headerHeight) {
      setState(() => _headerHeight = nextHeight);
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
    if (!confirmed || !mounted) return;
    await provider.clearAllSessions();
    if (!mounted || !context.mounted) return;
    showAppSnackBar(
      context,
      i18n.tr('all_sessions_cleared'),
      tone: AppFeedbackTone.destructive,
      icon: Icons.delete_sweep_rounded,
    );
  }

  void _openSessionDetail(BuildContext context, String sessionId) {
    AppInteractionFeedback.trigger(
      AppInteractionFeedbackType.tap,
      context: context,
    );
    Navigator.of(context).push(buildSessionDetailRoute(sessionId: sessionId));
  }

  void _openQueueEditor(BuildContext context, String sessionId) {
    AppInteractionFeedback.trigger(
      AppInteractionFeedbackType.tap,
      context: context,
    );
    showPlaybackQueueEditPanel(context, sessionId);
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
    final PlaylistListState listState;
    if (_isReordering) {
      listState = _reorderSnapshot ?? ref.read(playlistListUiProvider);
    } else {
      listState = ref.watch(playlistListUiProvider);
    }
    final settingsState =
        (_isReordering
                ? ref.read(settingsStateProvider)
                : ref.watch(settingsStateProvider))
            .valueOrNull ??
        const SettingsState();
    final subtitleSettings = _isReordering
        ? ref.read(subtitleSettingsProvider)
        : ref.watch(subtitleSettingsProvider);
    final cardPositionsLocked = settingsState.cardPositionsLocked;
    final coverCacheWidth = coverCacheWidthForResolution(
      settingsState.coverImageResolution,
    );
    final listBottomInset = MobileOverlayInset.of(context);
    final listCacheExtent = (_headerHeight + 800)
        .clamp(_headerHeight + 4, 1600.0)
        .toDouble();
    final isWindows =
        Platform.isWindows ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    const double expansion = 320.0;
    const topPadding = 4.0 + expansion;
    const bottomPadding = 16.0 + expansion;

    Widget buildSessionItem(BuildContext context, int index) {
      if (index == listState.sessions.length) {
        return const SizedBox.shrink(key: ValueKey('bottom_spacing'));
      }
      final session = listState.sessions[index];
      final cardState = listState.cardStateFor(session.id);
      if (cardState == null) {
        return SizedBox.shrink(key: ValueKey(session.id));
      }
      final track = provider.trackByPath(cardState.trackPath);
      final coverPath = provider.resolvedCoverPathForTrack(track);
      if (!_isReordering && coverPath == null) {
        unawaited(_coverFutureForTrack(provider, track));
      }
      if (!_isReordering && session.isPlaybackQueue) {
        for (final entry in session.playbackQueue!.entries.take(4)) {
          if (entry.tracks.isEmpty) continue;
          final coverTrack = entry.tracks.first;
          if (provider.resolvedCoverPathForTrack(coverTrack) == null) {
            unawaited(_coverFutureForTrack(provider, coverTrack));
          }
        }
      }
      final child = RepaintBoundary(
        child: session.isPlaybackQueue
            ? _PlaybackQueueCard(
                session: session,
                cardState: cardState,
                provider: provider,
                index: index,
                cardPositionsLocked: cardPositionsLocked,
                coverCacheWidth: coverCacheWidth,
                onOpen: () => session.currentTrackPath.isEmpty
                    ? showAppSnackBar(
                        context,
                        i18n.tr('queue_add_audio_first'),
                        tone: AppFeedbackTone.warning,
                        icon: Icons.queue_music_rounded,
                      )
                    : _openSessionDetail(context, session.id),
                onEdit: () => _openQueueEditor(context, session.id),
              )
            : _SessionListCard(
                sessionId: session.id,
                cardState: cardState,
                track: track,
                coverPath: coverPath,
                coverCacheWidth: coverCacheWidth,
                showSubtitles: subtitleSettings.isGlobalEnabled(session.id),
                provider: provider,
                index: index,
                cardPositionsLocked: cardPositionsLocked,
                onOpen: () => _openSessionDetail(context, session.id),
              ),
      );
      return KeyedSubtree(key: ValueKey(session.id), child: child);
    }

    return ScrollActivityGate(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: EdgeInsets.only(
                top: _headerHeight + 4,
                bottom: listBottomInset,
                right: 4,
              ),
            ),
            child: ContentBoundReorderArea(
              headerHeight: _headerHeight,
              bottomInset: listBottomInset,
              topExpansion: expansion,
              bottomExpansion: expansion,
              scrollController: _scrollController,
              showScrollbar: isWindows,
              scrollbarMainAxisMargin: isWindows ? 12 : 0,
              child: !listState.isInitialized
                  ? const _PlaylistLoadingSkeleton(
                      key: ValueKey('initializing'),
                    )
                  : Stack(
                      clipBehavior: Clip.none,
                      children: [
                        if (!listState.hasSessions)
                          const _SessionsEmptyState(
                            key: ValueKey('empty_state'),
                            bottomInset: 100,
                            topInset: expansion + 64,
                          ),
                        if (listState.hasSessions)
                          Theme(
                            data: Theme.of(
                              context,
                            ).copyWith(canvasColor: Colors.transparent),
                            child: ReorderAutoScroller(
                              key: const ValueKey('session_list'),
                              scrollController: _scrollController,
                              isDragging: !cardPositionsLocked && _isReordering,
                              contentMarginTop: topPadding,
                              contentMarginBottom: bottomPadding,
                              child: cardPositionsLocked
                                  ? ListView.builder(
                                      controller: _scrollController,
                                      physics: const ClampingScrollPhysics(),
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        topPadding,
                                        16,
                                        bottomPadding,
                                      ),
                                      cacheExtent: listCacheExtent,
                                      clipBehavior: Clip.none,
                                      keyboardDismissBehavior:
                                          ScrollViewKeyboardDismissBehavior
                                              .onDrag,
                                      itemCount: listState.sessions.length + 1,
                                      itemBuilder: buildSessionItem,
                                    )
                                  : ReorderableListView.builder(
                                      scrollController: _scrollController,
                                      physics: const ClampingScrollPhysics(),
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        topPadding,
                                        16,
                                        bottomPadding,
                                      ),
                                      cacheExtent: listCacheExtent,
                                      clipBehavior: Clip.none,
                                      buildDefaultDragHandles: false,
                                      keyboardDismissBehavior:
                                          ScrollViewKeyboardDismissBehavior
                                              .onDrag,
                                      onReorder: (oldIndex, newIndex) {
                                        provider.reorderSessions(
                                          oldIndex,
                                          newIndex,
                                        );
                                        setState(() {
                                          _isReordering = false;
                                          _reorderSnapshot = null;
                                        });
                                      },
                                      onReorderStart: (_) {
                                        setState(() {
                                          _reorderSnapshot = listState;
                                          _isReordering = true;
                                        });
                                        unawaited(
                                          AppInteractionFeedback.trigger(
                                            AppInteractionFeedbackType
                                                .destructive,
                                          ),
                                        );
                                      },
                                      onReorderEnd: (_) {
                                        if (_isReordering) {
                                          setState(() {
                                            _isReordering = false;
                                            _reorderSnapshot = null;
                                          });
                                        }
                                      },
                                      proxyDecorator:
                                          (child, index, animation) =>
                                              _buildReorderProxy(
                                                context,
                                                child,
                                                animation,
                                              ),
                                      itemCount: listState.sessions.length + 1,
                                      itemBuilder: buildSessionItem,
                                    ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Consumer(
              builder: (context, ref, child) {
                final headerState = ref.watch(playlistHeaderUiProvider);
                final sessionSummary =
                    '${i18n.tr('sessions_count', {'count': headerState.sessionCount})} · '
                    '${i18n.tr('playing_count', {'count': headerState.playingCount})}';
                return TopPageHeader(
                  key: _headerKey,
                  icon: Icons.graphic_eq_rounded,
                  title: i18n.tr('playback_sessions'),
                  subtitle: sessionSummary,
                  subtitleFontSize: 11,
                  fitSubtitleToWidth: true,
                  collapseController: _scrollController,
                  floatingReveal: true,
                  floatingRevealDistance: 56,
                  trailing: SizedBox(
                    height: 44,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (headerState.hasTimer)
                          _TimerCountdownCapsule(
                            remaining:
                                headerState.timerRemaining ??
                                headerState.timerDuration ??
                                Duration.zero,
                            active: headerState.timerActive,
                            autoResumeAt: headerState.autoResumeAt,
                            onTap: widget.onTimerTap,
                          )
                        else
                          IconButton(
                            onPressed: widget.onTimerTap,
                            icon: const Icon(Icons.alarm_rounded),
                            tooltip: i18n.tr('timer'),
                          ),
                        UnifiedPopupMenuButton<String>(
                          icon: Icons.more_horiz_rounded,
                          tooltip: i18n.tr('more_actions'),
                          entries: [
                            UnifiedMenuEntry<String>.action(
                              value: 'add_playback_queue',
                              icon: Icons.playlist_add_rounded,
                              label: i18n.tr('add_playback_queue'),
                            ),
                            const UnifiedMenuEntry<String>.divider(),
                            UnifiedMenuEntry<String>.action(
                              value: 'pause_all',
                              icon: Icons.pause_circle_outline_rounded,
                              label: i18n.tr('pause_all_sessions'),
                              enabled: listState.hasSessions,
                            ),
                            UnifiedMenuEntry<String>.action(
                              value: 'clear_all',
                              icon: Icons.delete_sweep_rounded,
                              label: i18n.tr('clear_all_sessions'),
                              destructive: true,
                              enabled: listState.hasSessions,
                            ),
                            const UnifiedMenuEntry<String>.divider(),
                            UnifiedMenuEntry<String>.action(
                              value: 'toggle_card_positions_locked',
                              icon: Icons.push_pin_rounded,
                              label: i18n.tr('fixed_card_positions'),
                              trailing: cardPositionsLocked
                                  ? const Icon(Icons.check_rounded, size: 18)
                                  : null,
                            ),
                          ],
                          onSelected: (value) {
                            if (value == 'add_playback_queue') {
                              final queueCount = listState.sessions
                                  .where((session) => session.isPlaybackQueue)
                                  .length;
                              provider.createPlaybackQueue(
                                i18n.tr('default_playback_queue_name', {
                                  'number': queueCount + 1,
                                }),
                              );
                            } else if (value == 'pause_all') {
                              provider.pauseAllSessions();
                              showAppSnackBar(
                                context,
                                i18n.tr('all_paused'),
                                tone: AppFeedbackTone.warning,
                                icon: Icons.pause_circle_outline_rounded,
                              );
                            } else if (value == 'clear_all') {
                              _confirmClearAll(context, provider);
                            } else if (value ==
                                'toggle_card_positions_locked') {
                              unawaited(
                                provider.setCardPositionsLocked(
                                  !cardPositionsLocked,
                                ),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                );
              },
            ),
          ),
        ],
      ),
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
        final animValue = Curves.easeInOut.transform(animation.value);
        final scale = 1.0 + (0.012 * animValue);

        return Transform.scale(scale: scale, child: child);
      },
      child: child,
    );
  }
}
