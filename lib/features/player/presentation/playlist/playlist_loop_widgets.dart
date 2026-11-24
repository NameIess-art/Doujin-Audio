import 'dart:async';

import '../../../../core/widgets/app_transitions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/localization/app_language_provider.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../application/playback_facade.dart';
import '../../application/playback_session_snapshot.dart';
import '../../domain/playback_mode.dart';
import 'playlist_shared_helpers.dart';

Future<void> showLoopModeBottomSheet({
  required BuildContext context,
  required PlaybackSessionSnapshot session,
  required PlaybackFacade playback,
}) {
  return AppBottomSheet.show<void>(
    context: context,
    builder: (sheetContext) =>
        LoopModeSheet(session: session, playback: playback),
  );
}

class LoopModeSheet extends ConsumerStatefulWidget {
  const LoopModeSheet({
    super.key,
    required this.session,
    required this.playback,
  });

  final PlaybackSessionSnapshot session;
  final PlaybackFacade playback;

  @override
  ConsumerState<LoopModeSheet> createState() => _LoopModeSheetState();
}

class _LoopModeSheetState extends ConsumerState<LoopModeSheet> {
  late bool _single;
  late bool _pauseAfterPlay;
  late bool _shuffle;
  late bool _crossFolder;

  Set<_PlaybackOption> get _playbackOptions => <_PlaybackOption>{
    _shuffle ? _PlaybackOption.shuffle : _PlaybackOption.loop,
  };

  void _triggerSelectionFeedback() {
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
  }

  void _selectPlaybackOptions(Set<_PlaybackOption> selected) {
    if (selected.isEmpty) return;
    _triggerSelectionFeedback();
    setState(() {
      _shuffle = selected.first == _PlaybackOption.shuffle;
    });
  }

  Future<void> _confirm() async {
    final targetNonSingleMode = _crossFolder
        ? (_pauseAfterPlay
              ? (_shuffle
                    ? SessionLoopMode.crossRandomOnce
                    : SessionLoopMode.crossOnce)
              : (_shuffle
                    ? SessionLoopMode.crossRandom
                    : SessionLoopMode.crossSequential))
        : (_pauseAfterPlay
              ? (_shuffle
                    ? SessionLoopMode.folderRandomOnce
                    : SessionLoopMode.folderOnce)
              : (_shuffle
                    ? SessionLoopMode.folderRandom
                    : SessionLoopMode.folderSequential));

    if (_single) {
      await widget.playback.setSessionLoopMode(
        widget.session.id,
        targetNonSingleMode,
      );
      await widget.playback.setSessionLoopMode(
        widget.session.id,
        SessionLoopMode.single,
      );
    } else {
      await widget.playback.setSessionLoopMode(
        widget.session.id,
        targetNonSingleMode,
      );
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void initState() {
    super.initState();
    final loopMode = widget.session.loopMode;
    final nonSingleMode = widget.session.nonSingleLoopMode;
    _single = loopMode == SessionLoopMode.single;
    final baseMode = _single ? nonSingleMode : loopMode;
    _pauseAfterPlay = baseMode.isOneShot;
    _shuffle = baseMode.isShuffle;
    _crossFolder = baseMode.isCrossFolder;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        return SafeArea(
          child: Padding(
            padding: AppBottomSheet.contentPadding,
            child: SizedBox(
              width: constraints.maxWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppBottomSheetHeader(
                    icon: Icons.repeat_rounded,
                    iconKey: const ValueKey('loop_mode_header_icon'),
                    title: i18n.tr('loop_mode_title'),
                  ),
                  const SizedBox(height: 18),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SegmentedButton<bool>(
                            key: const ValueKey('loop_mode_single_row'),
                            segments: [
                              ButtonSegment<bool>(
                                value: true,
                                icon: const Icon(Icons.repeat_one_rounded),
                                label: Text(i18n.tr('single_loop')),
                              ),
                            ],
                            emptySelectionAllowed: true,
                            selected: _single
                                ? const <bool>{true}
                                : const <bool>{},
                            onSelectionChanged: (selected) {
                              _triggerSelectionFeedback();
                              setState(() {
                                _single = selected.isNotEmpty;
                              });
                            },
                          ),
                          AnimatedOpacity(
                            curve: kAppFadeCurve,
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : kAppFadeDuration,
                            opacity: _single ? 0.38 : 1.0,
                            child: IgnorePointer(
                              ignoring: _single,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const SizedBox(height: 12),
                                  SegmentedButton<bool>(
                                    key: const ValueKey(
                                      'loop_mode_pause_after_round_row',
                                    ),
                                    segments: [
                                      ButtonSegment<bool>(
                                        value: true,
                                        icon: const Icon(
                                          Icons.pause_circle_outline_rounded,
                                        ),
                                        label: Text(
                                          i18n.tr('pause_after_playback'),
                                        ),
                                      ),
                                    ],
                                    emptySelectionAllowed: true,
                                    selected: _pauseAfterPlay
                                        ? const <bool>{true}
                                        : const <bool>{},
                                    onSelectionChanged: (selected) {
                                      _triggerSelectionFeedback();
                                      setState(() {
                                        _pauseAfterPlay = selected.isNotEmpty;
                                      });
                                    },
                                  ),
                                  const SizedBox(height: 12),
                                  SegmentedButton<bool>(
                                    key: const ValueKey('loop_mode_scope_row'),
                                    segments: [
                                      ButtonSegment<bool>(
                                        value: false,
                                        icon: const Icon(Icons.folder_rounded),
                                        label: Text(
                                          i18n.tr('current_folder'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      ButtonSegment<bool>(
                                        value: true,
                                        icon: const Icon(
                                          Icons.folder_copy_rounded,
                                        ),
                                        label: Text(
                                          i18n.tr('cross_folder'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                    selected: {_crossFolder},
                                    onSelectionChanged: (selected) {
                                      _triggerSelectionFeedback();
                                      setState(() {
                                        _crossFolder = selected.first;
                                      });
                                    },
                                    expandedInsets: EdgeInsets.zero,
                                  ),
                                  const SizedBox(height: 12),
                                  SegmentedButton<_PlaybackOption>(
                                    key: const ValueKey(
                                      'loop_mode_playback_row',
                                    ),
                                    segments: [
                                      ButtonSegment<_PlaybackOption>(
                                        value: _PlaybackOption.loop,
                                        icon: const Icon(Icons.repeat_rounded),
                                        label: Text(
                                          i18n.tr('loop_playback'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      ButtonSegment<_PlaybackOption>(
                                        value: _PlaybackOption.shuffle,
                                        icon: const Icon(Icons.shuffle_rounded),
                                        label: Text(
                                          i18n.tr('shuffle_playback'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                    selected: _playbackOptions,
                                    onSelectionChanged: _selectPlaybackOptions,
                                    expandedInsets: EdgeInsets.zero,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ).withWindowsSmoothScroll(),
                  ),
                  AppBottomSheetActions(
                    key: const ValueKey('loop_mode_actions'),
                    cancelKey: const ValueKey('loop_mode_cancel'),
                    confirmKey: const ValueKey('loop_mode_confirm'),
                    cancelLabel: i18n.tr('cancel'),
                    confirmLabel: i18n.tr('confirm'),
                    onCancel: () => Navigator.of(context).pop(),
                    onConfirm: _confirm,
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

enum _PlaybackOption { loop, shuffle }

class SessionLoopModeButton extends ConsumerWidget {
  const SessionLoopModeButton({
    super.key,
    required this.session,
    required this.playback,
  });

  final PlaybackSessionSnapshot session;
  final PlaybackFacade playback;

  IconData _orderIcon(SessionLoopMode mode) {
    if (mode.isShuffle) return Icons.shuffle_rounded;
    if (mode.isOneShot) return Icons.play_arrow_rounded;
    return Icons.repeat_rounded;
  }

  IconData _scopeIcon(SessionLoopMode mode) =>
      mode.isCrossFolder ? Icons.folder_copy_rounded : Icons.folder_rounded;

  Widget _buildIcon(BuildContext context, SessionLoopMode mode) {
    final cs = Theme.of(context).colorScheme;
    if (mode == SessionLoopMode.single) {
      return Icon(
        Icons.repeat_one_rounded,
        key: const ValueKey<String>('single_main'),
        size: 20,
        color: sessionDetailForeground(cs, SessionDetailForegroundLevel.muted),
      );
    }
    return SizedBox(
      key: ValueKey<String>(
        'composite_${_orderIcon(mode).codePoint}_${_scopeIcon(mode).codePoint}',
      ),
      width: 20,
      height: 20,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Opacity(
              opacity: 0.28,
              child: Icon(
                _scopeIcon(mode),
                size: 20,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          Center(
            child: Icon(_orderIcon(mode), size: 13, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  String _modeSummary(
    AppLanguageProvider i18n,
    SessionLoopMode mode,
  ) {
    if (mode == SessionLoopMode.single) {
      return i18n.tr('single_loop');
    }
    final parts = <String>[
      i18n.tr(mode.isShuffle ? 'shuffle_playback' : 'loop_playback'),
      if (mode.isCrossFolder) i18n.tr('cross_folder'),
      if (mode.isOneShot) i18n.tr('pause_after_playback'),
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final loopMode =
        ref.watch(
          sessionDetailTransportProvider(
            session.id,
          ).select((state) => state?.loopMode),
        ) ??
        session.loopMode;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);

    return IconButton(
      key: const ValueKey('session_loop_button_anchor'),
      constraints: playbackSecondaryControlButtonConstraints,
      padding: EdgeInsets.zero,
      tooltip: '${i18n.tr('loop_mode_title')}: ${_modeSummary(i18n, loopMode)}',
      style: playbackSecondaryControlButtonStyle(
        foregroundColor: sessionDetailForeground(
          Theme.of(context).colorScheme,
          SessionDetailForegroundLevel.muted,
        ),
      ),
      onPressed: () {
        showLoopModeBottomSheet(
          context: context,
          session: playback.sessionSnapshotById(session.id) ?? session,
          playback: playback,
        );
      },
      icon: _buildIcon(context, loopMode),
    );
  }
}
