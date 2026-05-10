part of 'playlist_tab.dart';

class _SessionDetailContent extends StatefulWidget {
  const _SessionDetailContent({
    required this.session,
    required this.provider,
    this.filenameKey,
    this.progressBarKey,
    this.subtitleFontSize = 16,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final GlobalKey? filenameKey;
  final GlobalKey? progressBarKey;
  final double subtitleFontSize;

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
    final rootFolderName = provider.getRootFolderName(session.currentTrackPath);
    final folderName = rootFolderName.isNotEmpty
        ? rootFolderName
        : context.read<AppLanguageProvider>().tr('imported_files');
    final hasSiblings =
        provider.tracksInSameGroup(session.currentTrackPath).length > 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: MarqueeText(
                text: folderName,
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
        SizedBox(
          key: widget.filenameKey,
          height: 36,
          child: MarqueeText(
            text: displayName,
            pauseDuration: const Duration(seconds: 1),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
              height: 1.1,
            ),
          ),
        ),
        const SizedBox(height: 8),
        const SizedBox(height: 8),
        SizedBox(height: widget.subtitleFontSize * 3), // scales with font size
        Container(
          key: widget.progressBarKey,
          child: _ProgressBar(
            key: ValueKey(session.id),
            session: session,
            provider: provider,
          ),
        ),
        const SizedBox(height: 0),
        SizedBox(
          height: 92,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 400;
              final gap = compact ? 8.0 : 16.0;
              final skipIconSize = compact ? 48.0 : 54.0;
              final playIconSize = compact ? 76.0 : 86.0;
              final loadingSize = compact ? 38.0 : 44.0;

              return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      constraints: BoxConstraints.tightFor(
                        width: compact ? 56 : 64,
                        height: compact ? 56 : 64,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: session.isLoading
                          ? null
                          : () {
                              HapticFeedback.selectionClick();
                              provider.seekSessionToPrev(session.id);
                            },
                      icon: Icon(
                        Icons.skip_previous_rounded,
                        size: skipIconSize,
                        color: cs.onSurface,
                      ),
                    ),
                    IconButton(
                      constraints: BoxConstraints.tightFor(
                        width: compact ? 56 : 64,
                        height: compact ? 56 : 64,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: session.isLoading
                          ? null
                          : () {
                              HapticFeedback.selectionClick();
                              final newPos =
                                  session.position - const Duration(seconds: 5);
                              provider.seekSession(
                                session.id,
                                newPos < Duration.zero ? Duration.zero : newPos,
                              );
                            },
                      icon: Icon(
                        Icons.replay_5_rounded,
                        size: skipIconSize * 0.8,
                        color: cs.onSurface,
                      ),
                    ),
                    IconButton(
                      constraints: BoxConstraints.tightFor(
                        width: compact ? 80 : 92,
                        height: compact ? 80 : 92,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: session.isLoading
                          ? null
                          : () {
                              HapticFeedback.mediumImpact();
                              provider.toggleSessionPlayPause(session.id);
                            },
                      iconSize: playIconSize,
                      icon: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          return FadeTransition(
                            opacity: animation,
                            child: ScaleTransition(
                              scale: Tween<double>(
                                begin: 0.92,
                                end: 1,
                              ).animate(animation),
                              child: child,
                            ),
                          );
                        },
                        child: session.isLoading
                            ? SizedBox(
                                key: const ValueKey('loading'),
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
                                key: ValueKey(session.state.playing),
                                size: playIconSize,
                                color: cs.onSurface,
                              ),
                      ),
                    ),
                    IconButton(
                      constraints: BoxConstraints.tightFor(
                        width: compact ? 56 : 64,
                        height: compact ? 56 : 64,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: session.isLoading
                          ? null
                          : () {
                              HapticFeedback.selectionClick();
                              provider.seekSession(
                                session.id,
                                session.position + const Duration(seconds: 5),
                              );
                            },
                      icon: Icon(
                        Icons.forward_5_rounded,
                        size: skipIconSize * 0.8,
                        color: cs.onSurface,
                      ),
                    ),
                    IconButton(
                      constraints: BoxConstraints.tightFor(
                        width: compact ? 56 : 64,
                        height: compact ? 56 : 64,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: session.isLoading
                          ? null
                          : () {
                              HapticFeedback.selectionClick();
                              provider.seekSessionToNext(session.id);
                            },
                      icon: Icon(
                        Icons.skip_next_rounded,
                        size: skipIconSize,
                        color: cs.onSurface,
                      ),
                    ),
                  ],
                );
            },
          ),
        ),
        const SizedBox(height: 0),
        Container(
          margin: const EdgeInsets.only(top: 8),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.15),
              width: 1.0,
            ),
            boxShadow: [
              // Bottom rim highlight for inset depth
              BoxShadow(
                color: Colors.white.withValues(alpha: 0.12),
                offset: const Offset(0, 1),
                blurRadius: 0,
              ),
              // Top inner shadow simulation
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                offset: const Offset(0, 1),
                blurRadius: 4,
                spreadRadius: -2,
              ),
            ],
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.06),
                Colors.transparent,
              ],
              stops: const [0.0, 0.15],
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: SizedBox(
            height: 52,
            child: Row(
              children: [
                _ExpandableLoopOptions(
                  session: session,
                  provider: provider,
                  compact: false,
                ),
                const SizedBox(width: 8),
                IconButton(
                  constraints: const BoxConstraints.tightFor(
                    width: 48,
                    height: 48,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: hasSiblings
                      ? () {
                          HapticFeedback.selectionClick();
                          _showTrackSwitcher(context);
                        }
                      : null,
                  tooltip: context.read<AppLanguageProvider>().tr('switch_audio'),
                  icon: Icon(
                    Icons.queue_music_rounded,
                    size: 24,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _SessionVolumeSlider(
                    session: session,
                    provider: provider,
                  ),
                ),
              ],
            ),
          ),
        ),
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
