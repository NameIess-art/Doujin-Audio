part of 'playlist_tab.dart';

class _TransportPlaybackControlPanel extends ConsumerWidget {
  const _TransportPlaybackControlPanel({
    super.key,
    required this.session,
    required this.playback,
    required this.paths,
    required this.hasSiblings,
    required this.segmentPanelExpanded,
    required this.hasSubtitle,
    required this.subtitleEnabled,
    required this.subtitleGlobalEnabled,
    required this.onShowTrackSwitcher,
    required this.onToggleSegments,
    this.onToggleSubtitle,
    this.onToggleGlobalSubtitle,
    this.onOpenTimer,
    this.onShowAudioDetail,
  });

  final PlaybackSession session;
  final PlaybackFacade playback;
  final AudioPathCoordinator paths;
  final bool hasSiblings;
  final bool segmentPanelExpanded;
  final bool hasSubtitle;
  final bool subtitleEnabled;
  final bool subtitleGlobalEnabled;
  final VoidCallback onShowTrackSwitcher;
  final VoidCallback onToggleSegments;
  final VoidCallback? onToggleSubtitle;
  final VoidCallback? onToggleGlobalSubtitle;
  final VoidCallback? onOpenTimer;
  final VoidCallback? onShowAudioDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transport = ref.watch(sessionDetailTransportProvider(session.id));
    return _PlaybackControlPanel(
      session: session,
      playback: playback,
      paths: paths,
      showPauseIcon:
          transport?.showPauseIcon ??
          (session.effectivePlaying ||
              session.isLoading ||
              session.playbackError != null),
      hasSiblings: hasSiblings,
      segmentPanelExpanded: segmentPanelExpanded,
      hasSubtitle: hasSubtitle,
      subtitleEnabled: subtitleEnabled,
      subtitleGlobalEnabled: subtitleGlobalEnabled,
      onShowTrackSwitcher: onShowTrackSwitcher,
      onToggleSegments: onToggleSegments,
      onToggleSubtitle: onToggleSubtitle,
      onToggleGlobalSubtitle: onToggleGlobalSubtitle,
      onOpenTimer: onOpenTimer,
      onShowAudioDetail: onShowAudioDetail,
    );
  }
}

class _PlaybackControlPanel extends StatelessWidget {
  const _PlaybackControlPanel({
    required this.session,
    required this.playback,
    required this.paths,
    required this.showPauseIcon,
    required this.hasSiblings,
    required this.segmentPanelExpanded,
    required this.hasSubtitle,
    required this.subtitleEnabled,
    required this.subtitleGlobalEnabled,
    required this.onShowTrackSwitcher,
    required this.onToggleSegments,
    this.onToggleSubtitle,
    this.onToggleGlobalSubtitle,
    this.onOpenTimer,
    this.onShowAudioDetail,
  });

  final PlaybackSession session;
  final PlaybackFacade playback;
  final AudioPathCoordinator paths;
  final bool showPauseIcon;
  final bool hasSiblings;
  final bool segmentPanelExpanded;
  final bool hasSubtitle;
  final bool subtitleEnabled;
  final bool subtitleGlobalEnabled;
  final VoidCallback onShowTrackSwitcher;
  final VoidCallback onToggleSegments;
  final VoidCallback? onToggleSubtitle;
  final VoidCallback? onToggleGlobalSubtitle;
  final VoidCallback? onOpenTimer;
  final VoidCallback? onShowAudioDetail;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _PlaybackPrimaryControls(
          session: session,
          playback: playback,
          paths: paths,
          showPauseIcon: showPauseIcon,
        ),
        _PlaybackSecondaryControls(
          session: session,
          playback: playback,
          hasSiblings: hasSiblings,
          segmentPanelExpanded: segmentPanelExpanded,
          hasSubtitle: hasSubtitle,
          subtitleEnabled: subtitleEnabled,
          subtitleGlobalEnabled: subtitleGlobalEnabled,
          onShowTrackSwitcher: onShowTrackSwitcher,
          onToggleSegments: onToggleSegments,
          onToggleSubtitle: onToggleSubtitle,
          onToggleGlobalSubtitle: onToggleGlobalSubtitle,
          onOpenTimer: onOpenTimer,
          onShowAudioDetail: onShowAudioDetail,
        ),
      ],
    );
  }
}

class _PlaybackPrimaryControls extends StatelessWidget {
  const _PlaybackPrimaryControls({
    required this.session,
    required this.playback,
    required this.paths,
    required this.showPauseIcon,
  });

  final PlaybackSession session;
  final PlaybackFacade playback;
  final AudioPathCoordinator paths;
  final bool showPauseIcon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final enabled = session.currentTrackPath.isNotEmpty;
    final track = paths.trackByPath(session.currentTrackPath);
    final isAsmr = track?.remoteMetadataKind == 'asmr.one';
    final primaryColor = isAsmr
        ? AppDesignTokens.of(context).asmrAccent
        : cs.primary;
    final onPrimaryColor = isAsmr
        ? AppDesignTokens.of(context).onAsmrAccent
        : cs.onPrimary;
    final hasPrevious = playback.hasSessionAdjacentTrack(
      session.id,
      forward: false,
    );
    final hasNext = playback.hasSessionAdjacentTrack(session.id, forward: true);
    final canPrevious =
        enabled && (session.position.inSeconds > 3 || hasPrevious);
    final canNext = enabled && hasNext;

    return SizedBox(
      height: 92,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 400;
          final skipIconSize = compact ? 48.0 : 54.0;
          final playIconSize = compact ? 76.0 : 86.0;
          final sideBox = BoxConstraints.tightFor(
            width: compact ? 56 : 64,
            height: compact ? 56 : 64,
          );

          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _PrimaryTransportButton(
                tooltip: i18n.tr('previous_track'),
                constraints: sideBox,
                enabled: canPrevious,
                icon: Icons.skip_previous_rounded,
                iconSize: skipIconSize,
                onPressed: () {
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.selection,
                  );
                  playback.seekSessionToPrev(session.id);
                },
              ),
              _PrimaryTransportButton(
                constraints: sideBox,
                enabled: enabled,
                icon: Icons.replay_5_rounded,
                iconSize: skipIconSize * 0.8,
                onPressed: () {
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.selection,
                  );
                  final newPos = session.position - const Duration(seconds: 5);
                  playback.seekSession(
                    session.id,
                    newPos < Duration.zero ? Duration.zero : newPos,
                  );
                },
              ),
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: enabled ? primaryColor : cs.surfaceContainerHighest,
                ),
                child: IconButton(
                  tooltip: showPauseIcon ? i18n.tr('pause') : i18n.tr('play'),
                  constraints: BoxConstraints.tightFor(
                    width: compact ? 80 : 92,
                    height: compact ? 80 : 92,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: enabled
                      ? () {
                          AppInteractionFeedback.trigger(
                            AppInteractionFeedbackType.confirmation,
                          );
                          playback.toggleSessionPlayPause(session.id);
                        }
                      : null,
                  iconSize: playIconSize,
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 120),
                    transitionBuilder: (child, animation) {
                      return ScaleTransition(
                        scale: Tween<double>(begin: 0.4, end: 1.0).animate(
                          CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutBack,
                          ),
                        ),
                        child: FadeTransition(opacity: animation, child: child),
                      );
                    },
                    child: Icon(
                      showPauseIcon
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      key: ValueKey(showPauseIcon),
                      size: playIconSize * 0.75,
                      color: enabled
                          ? onPrimaryColor
                          : cs.onSurface.withValues(alpha: 0.35),
                    ),
                  ),
                ),
              ),
              _PrimaryTransportButton(
                constraints: sideBox,
                enabled: enabled,
                icon: Icons.forward_5_rounded,
                iconSize: skipIconSize * 0.8,
                onPressed: () {
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.selection,
                  );
                  playback.seekSession(
                    session.id,
                    session.position + const Duration(seconds: 5),
                  );
                },
              ),
              _PrimaryTransportButton(
                tooltip: i18n.tr('next_track'),
                constraints: sideBox,
                enabled: canNext,
                icon: Icons.skip_next_rounded,
                iconSize: skipIconSize,
                onPressed: () {
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.selection,
                  );
                  playback.seekSessionToNext(session.id);
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PlaybackSecondaryControls extends StatelessWidget {
  const _PlaybackSecondaryControls({
    required this.session,
    required this.playback,
    required this.hasSiblings,
    required this.segmentPanelExpanded,
    required this.hasSubtitle,
    required this.subtitleEnabled,
    required this.subtitleGlobalEnabled,
    required this.onShowTrackSwitcher,
    required this.onToggleSegments,
    this.onToggleSubtitle,
    this.onToggleGlobalSubtitle,
    this.onOpenTimer,
    this.onShowAudioDetail,
  });

  final PlaybackSession session;
  final PlaybackFacade playback;
  final bool hasSiblings;
  final bool segmentPanelExpanded;
  final bool hasSubtitle;
  final bool subtitleEnabled;
  final bool subtitleGlobalEnabled;
  final VoidCallback onShowTrackSwitcher;
  final VoidCallback onToggleSegments;
  final VoidCallback? onToggleSubtitle;
  final VoidCallback? onToggleGlobalSubtitle;
  final VoidCallback? onOpenTimer;
  final VoidCallback? onShowAudioDetail;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);

    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 4, right: 4),
      child: SizedBox(
        height: 56,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(16),
          ),
          child: _WindowsHorizontalWheelScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                _ExpandableLoopOptions(session: session, playback: playback),
                _SessionVolumeButton(session: session, playback: playback),
                _SecondaryControlButton(
                  icon: Icons.alarm_rounded,
                  tooltip: i18n.tr('timer'),
                  onPressed: onOpenTimer,
                ),
                if (hasSubtitle)
                  _SecondaryControlButton(
                    icon: subtitleEnabled
                        ? Icons.subtitles_rounded
                        : Icons.subtitles_off_rounded,
                    tooltip: subtitleEnabled
                        ? i18n.tr('turn_off_subtitle')
                        : i18n.tr('turn_on_subtitle'),
                    active: subtitleEnabled,
                    onPressed: onToggleSubtitle,
                  ),
                if (hasSubtitle && subtitleEnabled)
                  _SecondaryControlButton(
                    icon: subtitleGlobalEnabled
                        ? Icons.check_rounded
                        : Icons.layers_rounded,
                    tooltip: i18n.tr('subtitle_global_display'),
                    active: subtitleGlobalEnabled,
                    onPressed: onToggleGlobalSubtitle,
                  ),
                _SecondaryControlButton(
                  icon: Icons.tune_rounded,
                  tooltip: i18n.tr('audio_features'),
                  active: segmentPanelExpanded,
                  onPressed: onToggleSegments,
                ),
                _SecondaryControlButton(
                  icon: Icons.queue_music_rounded,
                  tooltip: i18n.tr('switch_audio'),
                  onPressed: hasSiblings
                      ? () {
                          AppInteractionFeedback.trigger(
                            AppInteractionFeedbackType.selection,
                          );
                          onShowTrackSwitcher();
                        }
                      : null,
                ),
                _SecondaryControlButton(
                  icon: Icons.info_outline_rounded,
                  tooltip: i18n.tr('audio_detail'),
                  onPressed: onShowAudioDetail,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WindowsHorizontalWheelScrollView extends StatefulWidget {
  const _WindowsHorizontalWheelScrollView({
    required this.padding,
    required this.child,
  });

  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  State<_WindowsHorizontalWheelScrollView> createState() =>
      _WindowsHorizontalWheelScrollViewState();
}

class _WindowsHorizontalWheelScrollViewState
    extends State<_WindowsHorizontalWheelScrollView> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (defaultTargetPlatform != TargetPlatform.windows ||
        event is! PointerScrollEvent ||
        !_controller.hasClients) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (signal) {
      if (signal is! PointerScrollEvent || !_controller.hasClients) return;
      final delta = signal.scrollDelta.dy.abs() >= signal.scrollDelta.dx.abs()
          ? signal.scrollDelta.dy
          : signal.scrollDelta.dx;
      if (delta == 0) return;
      final position = _controller.position;
      final target = (_controller.offset + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (target == _controller.offset) return;
      unawaited(
        _controller.animateTo(
          target,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _handlePointerSignal,
      child: SingleChildScrollView(
        key: const ValueKey('playback_secondary_controls_horizontal_scroll'),
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: widget.padding,
        child: widget.child,
      ),
    );
  }
}

class _PrimaryTransportButton extends StatelessWidget {
  const _PrimaryTransportButton({
    required this.constraints,
    required this.enabled,
    required this.icon,
    required this.iconSize,
    required this.onPressed,
    this.tooltip,
  });

  final BoxConstraints constraints;
  final bool enabled;
  final IconData icon;
  final double iconSize;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return IconButton(
      tooltip: tooltip,
      constraints: constraints,
      padding: EdgeInsets.zero,
      onPressed: enabled ? onPressed : null,
      icon: Icon(
        icon,
        size: iconSize,
        color: enabled ? color : color.withValues(alpha: 0.35),
      ),
    );
  }
}

class _SecondaryControlButton extends StatelessWidget {
  const _SecondaryControlButton({
    required this.icon,
    required this.tooltip,
    this.active = false,
    this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: IconButton(
        constraints: const BoxConstraints.tightFor(width: 46, height: 46),
        padding: EdgeInsets.zero,
        tooltip: tooltip,
        style: IconButton.styleFrom(
          backgroundColor: active
              ? cs.primaryContainer.withValues(alpha: 0.65)
              : Colors.transparent,
          foregroundColor: active ? cs.onPrimaryContainer : cs.onSurface,
          disabledForegroundColor: cs.onSurface.withValues(alpha: 0.35),
        ),
        onPressed: onPressed != null
            ? () {
                AppInteractionFeedback.trigger(
                  AppInteractionFeedbackType.selection,
                );
                onPressed!();
              }
            : null,
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, animation) {
            return ScaleTransition(
              scale: Tween<double>(begin: 0.4, end: 1.0).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
              ),
              child: FadeTransition(opacity: animation, child: child),
            );
          },
          child: Icon(
            icon,
            key: ValueKey(icon),
            size: 20,
            color: enabled ? null : null,
          ),
        ),
      ),
    );
  }
}
