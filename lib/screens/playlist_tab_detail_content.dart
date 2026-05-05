part of 'playlist_tab.dart';

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
      ),
    );
  }
}
