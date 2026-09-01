part of 'playlist_tab.dart';

Future<void> showLoopModeBottomSheet({
  required BuildContext context,
  required PlaybackSessionSnapshot session,
  required PlaybackFacade playback,
}) {
  return AppBottomSheet.show<void>(
    context: context,
    builder: (sheetContext) =>
        _LoopModeSheet(session: session, playback: playback),
  );
}

class _LoopModeSheet extends StatefulWidget {
  const _LoopModeSheet({required this.session, required this.playback});

  final PlaybackSessionSnapshot session;
  final PlaybackFacade playback;

  @override
  State<_LoopModeSheet> createState() => _LoopModeSheetState();
}

class _LoopModeSheetState extends State<_LoopModeSheet> {
  late bool _single;
  late bool _pauseAfterPlay;
  late bool _shuffle;
  late bool _crossFolder;

  Set<_PlaybackOption> get _playbackOptions => <_PlaybackOption>{
    if (_pauseAfterPlay) _PlaybackOption.pauseAfterPlayback,
    _shuffle ? _PlaybackOption.shuffle : _PlaybackOption.loop,
  };

  void _selectPlaybackOptions(Set<_PlaybackOption> selected) {
    final loopSelected = selected.contains(_PlaybackOption.loop);
    final shuffleSelected = selected.contains(_PlaybackOption.shuffle);
    if (!loopSelected && !shuffleSelected) return;
    setState(() {
      _pauseAfterPlay = selected.contains(_PlaybackOption.pauseAfterPlayback);
      _shuffle = loopSelected && shuffleSelected ? !_shuffle : shuffleSelected;
    });
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
    final theme = Theme.of(context);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: SizedBox(
              width: constraints.maxWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            i18n.tr('loop_mode_title'),
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 18),
                          SegmentedButton<bool>(
                            key: const ValueKey('loop_mode_single_row'),
                            segments: [
                              ButtonSegment<bool>(
                                value: true,
                                label: Text(i18n.tr('single_loop')),
                              ),
                            ],
                            emptySelectionAllowed: true,
                            selected: _single
                                ? const <bool>{true}
                                : const <bool>{},
                            onSelectionChanged: (selected) {
                              setState(() {
                                _single = selected.isNotEmpty;
                              });
                            },
                            expandedInsets: EdgeInsets.zero,
                          ),
                          AnimatedOpacity(
                            duration: const Duration(milliseconds: 200),
                            opacity: _single ? 0.38 : 1.0,
                            child: IgnorePointer(
                              ignoring: _single,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const SizedBox(height: 12),
                                  SegmentedButton<bool>(
                                    key: const ValueKey('loop_mode_scope_row'),
                                    segments: [
                                      ButtonSegment<bool>(
                                        value: false,
                                        label: Text(i18n.tr('current_folder')),
                                      ),
                                      ButtonSegment<bool>(
                                        value: true,
                                        label: Text(i18n.tr('cross_folder')),
                                      ),
                                    ],
                                    selected: {_crossFolder},
                                    onSelectionChanged: (selected) {
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
                                        value:
                                            _PlaybackOption.pauseAfterPlayback,
                                        label: Text(
                                          i18n.tr('pause_after_playback'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      ButtonSegment<_PlaybackOption>(
                                        value: _PlaybackOption.loop,
                                        label: Text(
                                          i18n.tr('loop_playback'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      ButtonSegment<_PlaybackOption>(
                                        value: _PlaybackOption.shuffle,
                                        label: Text(
                                          i18n.tr('shuffle_playback'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                    multiSelectionEnabled: true,
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
                    ),
                  ),
                  SizedBox(
                    key: const ValueKey('loop_mode_actions'),
                    width: double.infinity,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          key: const ValueKey('loop_mode_cancel'),
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(i18n.tr('cancel')),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          key: const ValueKey('loop_mode_confirm'),
                          onPressed: () async {
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
                                            : SessionLoopMode
                                                  .folderSequential));

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
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                          },
                          child: Text(i18n.tr('confirm')),
                        ),
                      ],
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

enum _PlaybackOption { pauseAfterPlayback, loop, shuffle }

class _SessionLoopModeButton extends StatelessWidget {
  const _SessionLoopModeButton({required this.session, required this.playback});

  final PlaybackSessionSnapshot session;
  final PlaybackFacade playback;

  IconData get _orderIcon {
    if (session.loopMode.isShuffle) return Icons.shuffle_rounded;
    if (session.loopMode.isOneShot) return Icons.play_arrow_rounded;
    return Icons.repeat_rounded;
  }

  IconData get _scopeIcon => session.loopMode.isCrossFolder
      ? Icons.folder_copy_rounded
      : Icons.folder_rounded;

  Widget _buildIcon(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (session.loopMode == SessionLoopMode.single) {
      return Icon(
        Icons.repeat_one_rounded,
        key: const ValueKey<String>('single_main'),
        size: 20,
        color: _sessionDetailForeground(
          cs,
          _SessionDetailForegroundLevel.muted,
        ),
      );
    }
    if (session.isPlaybackQueue) {
      return Icon(
        _orderIcon,
        key: ValueKey<String>('queue_order_${_orderIcon.codePoint}'),
        size: 20,
        color: cs.onSurfaceVariant,
      );
    }
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
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: IconButton(
        key: const ValueKey('session_loop_button_anchor'),
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
        padding: EdgeInsets.zero,
        tooltip: i18n.tr('loop_mode_title'),
        style: IconButton.styleFrom(
          shape: const CircleBorder(),
          backgroundColor: Colors.transparent,
          foregroundColor: _sessionDetailForeground(
            Theme.of(context).colorScheme,
            _SessionDetailForegroundLevel.muted,
          ),
        ),
        onPressed: () {
          AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
          showLoopModeBottomSheet(
            context: context,
            session: session,
            playback: playback,
          );
        },
        icon: _buildIcon(context),
      ),
    );
  }
}
