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
