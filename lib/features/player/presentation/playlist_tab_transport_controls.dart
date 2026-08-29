part of 'playlist_tab.dart';

// Seven 50px controls plus the scroll view's 8px horizontal insets.
const double _kPlaybackSecondaryControlsWidth = 366;

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
    this.onShowAudioDetail,
  });

  final PlaybackSessionSnapshot session;
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
  final VoidCallback? onShowAudioDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transport = ref.watch(sessionDetailTransportProvider(session.id));
    return _PlaybackControlPanel(
      session: session,
      playback: playback,
      paths: paths,
      showPauseIcon: transport?.showPauseIcon ?? session.playbackRequested,
      isLoading:
          transport?.isLoading ??
          (session.isPlaybackLoading && session.playbackRequested),
      hasSiblings: hasSiblings,
      segmentPanelExpanded: segmentPanelExpanded,
      hasSubtitle: hasSubtitle,
      subtitleEnabled: subtitleEnabled,
      subtitleGlobalEnabled: subtitleGlobalEnabled,
      onShowTrackSwitcher: onShowTrackSwitcher,
      onToggleSegments: onToggleSegments,
      onToggleSubtitle: onToggleSubtitle,
      onToggleGlobalSubtitle: onToggleGlobalSubtitle,
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
    required this.isLoading,
    required this.hasSiblings,
    required this.segmentPanelExpanded,
    required this.hasSubtitle,
    required this.subtitleEnabled,
    required this.subtitleGlobalEnabled,
    required this.onShowTrackSwitcher,
    required this.onToggleSegments,
    this.onToggleSubtitle,
    this.onToggleGlobalSubtitle,
    this.onShowAudioDetail,
  });

  final PlaybackSessionSnapshot session;
  final PlaybackFacade playback;
  final AudioPathCoordinator paths;
  final bool showPauseIcon;
  final bool isLoading;
  final bool hasSiblings;
  final bool segmentPanelExpanded;
  final bool hasSubtitle;
  final bool subtitleEnabled;
  final bool subtitleGlobalEnabled;
  final VoidCallback onShowTrackSwitcher;
  final VoidCallback onToggleSegments;
  final VoidCallback? onToggleSubtitle;
  final VoidCallback? onToggleGlobalSubtitle;
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
          isLoading: isLoading,
        ),
        if (!segmentPanelExpanded)
          AnimatedSwitcher(
            duration: kAppMotionSlow,
            reverseDuration: kAppMotionStandard,
            transitionBuilder: (child, animation) => buildAppFadeTransition(
              context: context,
              animation: animation,
              child: child,
            ),
            child: KeyedSubtree(
              key: ValueKey('secondary_${session.id}'),
              child: _PlaybackSecondaryControls(
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
                onShowAudioDetail: onShowAudioDetail,
              ),
            ),
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
    required this.isLoading,
  });

  final PlaybackSessionSnapshot session;
  final PlaybackFacade playback;
  final AudioPathCoordinator paths;
  final bool showPauseIcon;
  final bool isLoading;

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
                  playback.seekSessionByOffset(
                    session.id,
                    const Duration(seconds: -5),
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
                  icon: isLoading
                      ? SizedBox(
                          key: const ValueKey('loading'),
                          width: playIconSize * 0.48,
                          height: playIconSize * 0.48,
                          child: CircularProgressIndicator(
                            strokeWidth: 3.0,
                            color: enabled
                                ? onPrimaryColor
                                : cs.onSurface.withValues(alpha: 0.35),
                          ),
                        )
                      : Icon(
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
              _PrimaryTransportButton(
                constraints: sideBox,
                enabled: enabled,
                icon: Icons.forward_5_rounded,
                iconSize: skipIconSize * 0.8,
                onPressed: () {
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.selection,
                  );
                  playback.seekSessionByOffset(
                    session.id,
                    const Duration(seconds: 5),
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

class _PlaybackSecondaryControls extends StatefulWidget {
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
    this.onShowAudioDetail,
  });

  final PlaybackSessionSnapshot session;
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
  final VoidCallback? onShowAudioDetail;

  @override
  State<_PlaybackSecondaryControls> createState() =>
      _PlaybackSecondaryControlsState();
}

class _PlaybackSecondaryControlsState
    extends State<_PlaybackSecondaryControls> {
  bool _volumeMode = false;
  double? _dragVolume;
  double? _preMuteVolume;

  IconData _getIconForVolume(double volume) {
    return volume == 0
        ? Icons.volume_off_rounded
        : volume < 0.45
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;
  }

  void _toggleMute() {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    final currentVolume = (_dragVolume ?? widget.session.volume)
        .clamp(0.0, PlaybackFacade.maxSessionVolume)
        .toDouble();
    if (currentVolume > 0.001) {
      _preMuteVolume = currentVolume;
      setState(() => _dragVolume = 0.0);
      widget.playback.setSessionVolume(widget.session.id, 0.0);
    } else {
      final restored = (_preMuteVolume != null && _preMuteVolume! > 0.001)
          ? _preMuteVolume!
          : 1.0;
      _preMuteVolume = null;
      setState(() => _dragVolume = restored);
      widget.playback.setSessionVolume(widget.session.id, restored);
    }
  }

  void _showVolumeInputDialog(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    var inputValue =
        '${(sessionVolumeDisplayValueFromGain(_dragVolume ?? widget.session.volume) * 100).round()}';
    unawaited(
      showAppDialog<void>(
        context: context,
        builder: (dialogContext) => AppDialog(
          title: i18n.tr('volume'),
          icon: Icons.volume_up_rounded,
          content: TextFormField(
            initialValue: inputValue,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
              hintText: i18n.tr('volume_range_hint'),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onFieldSubmitted: (text) {
              _applyVolumeInput(text, dialogContext);
            },
            onChanged: (text) => inputValue = text,
          ),
          actions: AppDialogActions(
            children: [
              AppSecondaryButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                label: i18n.tr('cancel'),
              ),
              AppPrimaryButton(
                onPressed: () {
                  _applyVolumeInput(inputValue, dialogContext);
                },
                label: i18n.tr('confirm'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _applyVolumeInput(String text, BuildContext dialogContext) {
    final parsed = int.tryParse(text.trim());
    if (parsed == null ||
        parsed < 0 ||
        parsed > sessionVolumeDisplayMaximumPercent) {
      return;
    }
    final volumeGain = sessionVolumeGainFromDisplayValue(parsed / 100);
    Navigator.of(dialogContext).pop();
    setState(() => _dragVolume = volumeGain);
    widget.playback.setSessionVolume(widget.session.id, volumeGain);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);

    final volumeGain = (_dragVolume ?? widget.session.volume)
        .clamp(0.0, PlaybackFacade.maxSessionVolume)
        .toDouble();
    final displayVolume = sessionVolumeDisplayValueFromGain(volumeGain);
    final isBoosted = volumeGain > 1.0;

    Widget buildVolumeBar() {
      return Padding(
        key: const ValueKey('playback_volume_controls_row'),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('session_volume_exit_button'),
              constraints: const BoxConstraints.tightFor(width: 44, height: 44),
              padding: EdgeInsets.zero,
              tooltip: i18n.tr('close'),
              icon: Icon(
                Icons.close_rounded,
                size: 20,
                color: _sessionDetailForeground(
                  cs,
                  _SessionDetailForegroundLevel.muted,
                ),
              ),
              onPressed: () {
                AppInteractionFeedback.trigger(
                  AppInteractionFeedbackType.selection,
                );
                setState(() {
                  _volumeMode = false;
                  _dragVolume = null;
                });
              },
            ),
            IconButton(
              key: const ValueKey('session_volume_mute_button'),
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: EdgeInsets.zero,
              tooltip: volumeGain == 0 ? i18n.tr('unmute') : i18n.tr('mute'),
              icon: Icon(
                _getIconForVolume(volumeGain),
                key: ValueKey(_getIconForVolume(volumeGain)),
                size: 18,
                color: isBoosted
                    ? cs.primary
                    : _sessionDetailForeground(
                        cs,
                        _SessionDetailForegroundLevel.muted,
                      ),
              ),
              onPressed: _toggleMute,
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 6,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                  activeTrackColor: isBoosted ? cs.primary : null,
                ),
                child: Slider(
                  key: const ValueKey('session_volume_slider'),
                  value: displayVolume,
                  max: sessionVolumeDisplayMaximum,
                  onChanged: (displayValue) {
                    final newGain = sessionVolumeGainFromDisplayValue(
                      displayValue,
                    );
                    setState(() => _dragVolume = newGain);
                    AppInteractionFeedback.continuous(
                      (displayValue * 100).round(),
                    );
                    UiInteractionCoordinator.instance.scheduleThrottledCommit(
                      key: 'session_volume:${widget.session.id}',
                      commit: () => widget.playback.setSessionVolume(
                        widget.session.id,
                        newGain,
                        persist: false,
                      ),
                    );
                  },
                  onChangeEnd: (displayValue) {
                    final newGain = sessionVolumeGainFromDisplayValue(
                      displayValue,
                    );
                    setState(() => _dragVolume = newGain);
                    AppInteractionFeedback.resetContinuous();
                    UiInteractionCoordinator.instance.cancelThrottledCommit(
                      'session_volume:${widget.session.id}',
                    );
                    widget.playback.setSessionVolume(
                      widget.session.id,
                      newGain,
                    );
                  },
                ),
              ),
            ),
            GestureDetector(
              key: const ValueKey('session_volume_percent_text'),
              onTap: () => _showVolumeInputDialog(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  '${(displayVolume * 100).round()}%',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                    color: isBoosted ? cs.primary : null,
                    decoration: TextDecoration.underline,
                    decorationColor: (isBoosted ? cs.primary : cs.onSurface)
                        .withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    Widget buildButtonsRow() {
      return LayoutBuilder(
        key: const ValueKey('playback_buttons_row'),
        builder: (context, constraints) => SingleChildScrollView(
          key: const ValueKey('playback_secondary_controls_horizontal_scroll'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: max(0.0, constraints.maxWidth - 16),
            ),
            child: Row(
              children: [
                _SessionLoopModeButton(
                  session: widget.session,
                  playback: widget.playback,
                ),
                _SecondaryControlButton(
                  key: const ValueKey('session_volume_button_anchor'),
                  icon: _getIconForVolume(widget.session.volume),
                  tooltip: i18n.tr('volume'),
                  onPressed: () {
                    setState(() => _volumeMode = true);
                  },
                ),
                if (widget.hasSubtitle)
                  _SecondaryControlButton(
                    icon: widget.subtitleEnabled
                        ? Icons.subtitles_rounded
                        : Icons.subtitles_off_rounded,
                    tooltip: widget.subtitleEnabled
                        ? i18n.tr('turn_off_subtitle')
                        : i18n.tr('turn_on_subtitle'),
                    active: widget.subtitleEnabled,
                    onPressed: widget.onToggleSubtitle,
                  ),
                if (widget.hasSubtitle)
                  _SecondaryControlButton(
                    icon: widget.subtitleGlobalEnabled
                        ? Icons.check_rounded
                        : Icons.layers_rounded,
                    tooltip: i18n.tr('subtitle_global_display'),
                    active: widget.subtitleGlobalEnabled,
                    onPressed: widget.onToggleGlobalSubtitle,
                  ),
                _SecondaryControlButton(
                  icon: Icons.tune_rounded,
                  tooltip: i18n.tr('audio_features'),
                  active: widget.segmentPanelExpanded,
                  onPressed: widget.onToggleSegments,
                ),
                _SecondaryControlButton(
                  icon: Icons.queue_music_rounded,
                  tooltip: i18n.tr('switch_audio'),
                  onPressed: widget.hasSiblings
                      ? () {
                          AppInteractionFeedback.trigger(
                            AppInteractionFeedbackType.selection,
                          );
                          widget.onShowTrackSwitcher();
                        }
                      : null,
                ),
                _SecondaryControlButton(
                  icon: Icons.info_outline_rounded,
                  tooltip: i18n.tr('audio_detail'),
                  onPressed: widget.onShowAudioDetail,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 4, right: 4),
      child: SizedBox(
        key: const ValueKey('playback_secondary_controls'),
        width: _kPlaybackSecondaryControlsWidth,
        height: 56,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(16),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _volumeMode ? buildVolumeBar() : buildButtonsRow(),
          ),
        ),
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
    final cs = Theme.of(context).colorScheme;
    final color = _sessionDetailForeground(
      cs,
      _SessionDetailForegroundLevel.medium,
    );
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
    super.key,
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
          foregroundColor: active
              ? cs.onPrimaryContainer
              : _sessionDetailForeground(
                  cs,
                  _SessionDetailForegroundLevel.muted,
                ),
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
