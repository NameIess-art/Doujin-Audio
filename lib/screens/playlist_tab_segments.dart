part of 'playlist_tab.dart';

class _PlaybackControlPanel extends StatelessWidget {
  const _PlaybackControlPanel({
    super.key,
    required this.session,
    required this.provider,
    required this.playPauseController,
    required this.isPlaying,
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
  final AudioProvider provider;
  final AnimationController playPauseController;
  final bool isPlaying;
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
          provider: provider,
          playPauseController: playPauseController,
          isPlaying: isPlaying,
        ),
        _PlaybackSecondaryControls(
          session: session,
          provider: provider,
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
    required this.provider,
    required this.playPauseController,
    required this.isPlaying,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final AnimationController playPauseController;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = context.read<AppLanguageProvider>();
    final enabled = !session.isLoading;

    return SizedBox(
      height: 92,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 400;
          final skipIconSize = compact ? 48.0 : 54.0;
          final playIconSize = compact ? 76.0 : 86.0;
          final loadingSize = compact ? 38.0 : 44.0;
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
                enabled: enabled,
                icon: Icons.skip_previous_rounded,
                iconSize: skipIconSize,
                onPressed: () {
                  HapticFeedback.selectionClick();
                  provider.seekSessionToPrev(session.id);
                },
              ),
              _PrimaryTransportButton(
                constraints: sideBox,
                enabled: enabled,
                icon: Icons.replay_5_rounded,
                iconSize: skipIconSize * 0.8,
                onPressed: () {
                  HapticFeedback.selectionClick();
                  final newPos = session.position - const Duration(seconds: 5);
                  provider.seekSession(
                    session.id,
                    newPos < Duration.zero ? Duration.zero : newPos,
                  );
                },
              ),
              IconButton(
                tooltip: isPlaying ? i18n.tr('pause') : i18n.tr('play'),
                constraints: BoxConstraints.tightFor(
                  width: compact ? 80 : 92,
                  height: compact ? 80 : 92,
                ),
                padding: EdgeInsets.zero,
                onPressed: enabled
                    ? () {
                        HapticFeedback.mediumImpact();
                        provider.toggleSessionPlayPause(session.id);
                      }
                    : null,
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
                            color: cs.onSurface.withValues(alpha: 0.8),
                          ),
                        )
                      : AnimatedIcon(
                          icon: AnimatedIcons.play_pause,
                          progress: playPauseController,
                          key: const ValueKey('play_pause_anim'),
                          size: playIconSize,
                          color: enabled
                              ? cs.onSurface
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
                  HapticFeedback.selectionClick();
                  provider.seekSession(
                    session.id,
                    session.position + const Duration(seconds: 5),
                  );
                },
              ),
              _PrimaryTransportButton(
                tooltip: i18n.tr('next_track'),
                constraints: sideBox,
                enabled: enabled,
                icon: Icons.skip_next_rounded,
                iconSize: skipIconSize,
                onPressed: () {
                  HapticFeedback.selectionClick();
                  provider.seekSessionToNext(session.id);
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
    required this.provider,
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
  final AudioProvider provider;
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
    final i18n = context.read<AppLanguageProvider>();

    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 4, right: 4, bottom: 2),
      child: SizedBox(
        height: 82,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.42),
            ),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                _ExpandableLoopOptions(session: session, provider: provider),
                _SessionVolumeButton(session: session, provider: provider),
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
                          HapticFeedback.selectionClick();
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
        constraints: const BoxConstraints.tightFor(width: 48, height: 48),
        padding: EdgeInsets.zero,
        tooltip: tooltip,
        style: IconButton.styleFrom(
          backgroundColor: active
              ? cs.primaryContainer.withValues(alpha: 0.65)
              : Colors.transparent,
          foregroundColor: active ? cs.onPrimaryContainer : cs.onSurface,
          disabledForegroundColor: cs.onSurface.withValues(alpha: 0.35),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 22, color: enabled ? null : null),
      ),
    );
  }
}

class _TimeSegmentPanel extends StatefulWidget {
  const _TimeSegmentPanel({
    super.key,
    required this.session,
    required this.provider,
    required this.labels,
    required this.selectedId,
    required this.showEditor,
    required this.loading,
    required this.nameController,
    required this.draftStart,
    required this.draftEnd,
    required this.draftColorValue,
    required this.loopSegmentId,
    required this.onSelect,
    required this.onAdd,
    required this.onSetStart,
    required this.onSetEnd,
    required this.onEditStart,
    required this.onEditEnd,
    required this.onDelete,
    required this.onToggleLoop,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final List<TimeSegmentLabel> labels;
  final String? selectedId;
  final bool showEditor;
  final bool loading;
  final TextEditingController nameController;
  final Duration? draftStart;
  final Duration? draftEnd;
  final int? draftColorValue;
  final String? loopSegmentId;
  final ValueChanged<TimeSegmentLabel> onSelect;
  final VoidCallback onAdd;
  final VoidCallback onSetStart;
  final VoidCallback onSetEnd;
  final VoidCallback onEditStart;
  final VoidCallback onEditEnd;
  final VoidCallback onDelete;
  final VoidCallback onToggleLoop;

  @override
  State<_TimeSegmentPanel> createState() => _TimeSegmentPanelState();
}

class _TimeSegmentPanelState extends State<_TimeSegmentPanel> {
  late final PageController _pageController;
  int _pageIndex = 2;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _pageIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _handlePageChanged(int index) {
    if (_pageIndex == index) return;
    setState(() => _pageIndex = index);
  }

  void _animateToPanelPage(int index) {
    if (_pageIndex == index) return;
    HapticFeedback.selectionClick();
    setState(() => _pageIndex = index);
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.read<AppLanguageProvider>();
    final selected = widget.labels
        .where((label) => label.id == widget.selectedId)
        .firstOrNull;
    final activeColor = Color(
      selected?.colorValue ??
          widget.draftColorValue ??
          kTimeSegmentLabelPalette.first,
    );
    final loopActive = selected != null && selected.id == widget.loopSegmentId;
    final mediaHeight = MediaQuery.sizeOf(context).height;
    final targetHeight = max(360.0, mediaHeight * 0.5 - 130.0);

    return Container(
      height: targetHeight,
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.5),
            height: 1,
          ),
          const SizedBox(height: 8),
          _SegmentPanelPageHeader(
            pageIndex: _pageIndex,
            onSelected: _animateToPanelPage,
            labels: [
              i18n.tr('equalizer'),
              i18n.tr('audio_features'),
              i18n.tr('playback_speed'),
              i18n.tr('audio_detail_tags'),
              i18n.tr('volume_balance'),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: _handlePageChanged,
              children: [
                _EqualizerPage(
                  session: widget.session,
                  provider: widget.provider,
                ),
                _AudioFeaturesPage(
                  session: widget.session,
                  provider: widget.provider,
                ),
                _SpeedWheelPage(
                  key: ValueKey<String>('speed_${widget.session.id}'),
                  session: widget.session,
                  provider: widget.provider,
                ),
                _buildSegmentPage(
                  context,
                  selected: selected,
                  activeColor: activeColor,
                  loopActive: loopActive,
                ),
                _VolumeBalancePage(
                  session: widget.session,
                  provider: widget.provider,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentPage(
    BuildContext context, {
    required TimeSegmentLabel? selected,
    required Color activeColor,
    required bool loopActive,
  }) {
    final i18n = context.read<AppLanguageProvider>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 42,
          child: Row(
            children: [
              Expanded(
                child: widget.loading
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      )
                    : ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: widget.labels.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final label = widget.labels[index];
                          return _TimeSegmentChip(
                            label: label,
                            selected: label.id == widget.selectedId,
                            onTap: () => widget.onSelect(label),
                          );
                        },
                      ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                constraints: const BoxConstraints.tightFor(
                  width: 40,
                  height: 40,
                ),
                padding: EdgeInsets.zero,
                onPressed: widget.onAdd,
                icon: const Icon(Icons.add_rounded),
                tooltip: i18n.tr('segment_add'),
              ),
            ],
          ),
        ),
        if (widget.showEditor) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              _SegmentTimeRow(
                label: i18n.tr('segment_start'),
                value: widget.draftStart,
                color: activeColor,
                onSet: widget.onSetStart,
                onEdit: widget.onEditStart,
              ),
              const SizedBox(width: 12),
              _SegmentTimeRow(
                label: i18n.tr('segment_end'),
                value: widget.draftEnd,
                color: activeColor,
                onSet: widget.onSetEnd,
                onEdit: widget.onEditEnd,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: widget.nameController,
                  textInputAction: TextInputAction.done,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: InputDecoration(
                    labelText: i18n.tr('segment_name'),
                    hintText: i18n.tr('segment_name_hint'),
                    filled: true,
                    fillColor: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.2),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 16,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(
                        color: activeColor.withValues(alpha: 0.3),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(
                        color: activeColor.withValues(alpha: 0.3),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: activeColor, width: 2),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (selected != null) ...[
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      foregroundColor: loopActive
                          ? activeColor
                          : Theme.of(context).colorScheme.onSurface,
                      backgroundColor: loopActive
                          ? activeColor.withValues(alpha: 0.18)
                          : Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest
                                .withValues(alpha: 0.28),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: widget.onToggleLoop,
                    icon: Icon(
                      loopActive
                          ? Icons.repeat_one_rounded
                          : Icons.repeat_rounded,
                    ),
                    label: Text(
                      i18n.tr('segment_loop'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.errorContainer.withValues(alpha: 0.5),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: widget.onDelete,
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: Text(
                      i18n.tr('remove'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }
}

class _SegmentPanelPageHeader extends StatelessWidget {
  const _SegmentPanelPageHeader({
    required this.pageIndex,
    required this.onSelected,
    required this.labels,
  });

  final int pageIndex;
  final ValueChanged<int> onSelected;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(labels.length, (index) {
          final selected = index == pageIndex;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => onSelected(index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  color: selected
                      ? cs.primary.withValues(alpha: 0.16)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  labels[index],
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: selected ? cs.primary : cs.onSurfaceVariant,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _AudioFeaturesPage extends StatelessWidget {
  const _AudioFeaturesPage({required this.session, required this.provider});

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  Widget build(BuildContext context) {
    final i18n = context.read<AppLanguageProvider>();
    final liveProvider = context.watch<AudioProvider>();
    final liveSession = liveProvider.sessionById(session.id) ?? session;
    final effects = liveSession.audioEffects;
    return ListView(
      padding: const EdgeInsets.only(top: 6),
      children: [
        _FeatureSwitchTile(
          title: i18n.tr('skip_silence'),
          subtitle: i18n.tr('skip_silence_desc'),
          icon: Icons.fast_forward_rounded,
          value: effects.skipSilenceEnabled,
          onChanged: (value) {
            HapticFeedback.selectionClick();
            unawaited(
              liveProvider.setSessionSkipSilence(liveSession.id, value),
            );
          },
        ),
        const SizedBox(height: 10),
        _FeatureSwitchTile(
          title: i18n.tr('noise_reduction'),
          subtitle: i18n.tr('noise_reduction_desc'),
          icon: Icons.graphic_eq_rounded,
          value: effects.noiseReductionEnabled,
          onChanged: (value) {
            HapticFeedback.selectionClick();
            unawaited(
              liveProvider.setSessionNoiseReduction(liveSession.id, value),
            );
          },
        ),
        const SizedBox(height: 10),
        _FeatureSwitchTile(
          title: i18n.tr('volume_normalization'),
          subtitle: i18n.tr('volume_normalization_desc'),
          icon: Icons.compress_rounded,
          value: effects.volumeNormalizationEnabled,
          onChanged: (value) {
            HapticFeedback.selectionClick();
            unawaited(
              liveProvider.setSessionVolumeNormalization(liveSession.id, value),
            );
          },
        ),
        const SizedBox(height: 10),
        _FeatureSwitchTile(
          title: i18n.tr('channel_swap'),
          subtitle: i18n.tr('channel_swap_desc'),
          icon: Icons.swap_horiz_rounded,
          value: liveSession.channelSwapEnabled,
          onChanged: (value) {
            HapticFeedback.selectionClick();
            unawaited(
              liveProvider.setSessionChannelSwap(liveSession.id, value),
            );
          },
        ),
      ],
    );
  }
}

class _FeatureSwitchTile extends StatelessWidget {
  const _FeatureSwitchTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        value: value,
        onChanged: onChanged,
        secondary: Icon(
          icon,
          color: value ? cs.primary : cs.onSurfaceVariant,
          size: 22,
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurfaceVariant,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}

class _VolumeBalancePage extends StatelessWidget {
  const _VolumeBalancePage({required this.session, required this.provider});

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  Widget build(BuildContext context) {
    final liveProvider = context.watch<AudioProvider>();
    final liveSession = liveProvider.sessionById(session.id) ?? session;
    final panning = liveSession.audioEffects.panning;
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(
                  Icons.headphones_outlined,
                  color: colorScheme.onSurfaceVariant,
                ),
                Icon(
                  Icons.headphones_outlined,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  'L',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: panning,
                    min: -1.0,
                    divisions: 20,
                    label: panning == 0 ? '0' : panning.toStringAsFixed(1),
                    onChanged: (value) {
                      HapticFeedback.selectionClick();
                      unawaited(
                        liveProvider.setSessionPanning(liveSession.id, value),
                      );
                    },
                    onChangeEnd: (value) {
                      if (value.abs() < 0.1) {
                        unawaited(
                          liveProvider.setSessionPanning(liveSession.id, 0.0),
                        );
                      }
                    },
                  ),
                ),
                Text(
                  'R',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EqualizerPage extends StatelessWidget {
  const _EqualizerPage({required this.session, required this.provider});

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  Widget build(BuildContext context) {
    final i18n = context.read<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final liveProvider = context.watch<AudioProvider>();
    final liveSession = liveProvider.sessionById(session.id) ?? session;
    final effects = liveSession.audioEffects;
    final capabilities = liveSession.eqCapabilities;
    final presets = [
      ...AudioProvider.builtInEqPresets,
      ...liveProvider.customEqPresets,
    ];
    final selectedPreset =
        presets.any((preset) => preset.id == effects.eqPresetId)
        ? effects.eqPresetId
        : 'flat';

    return ListView(
      padding: const EdgeInsets.only(top: 2),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            i18n.tr('equalizer'),
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          subtitle: Text(
            capabilities.supported
                ? i18n.tr('equalizer_supported')
                : i18n.tr('equalizer_enable_hint'),
          ),
          value: effects.eqEnabled,
          onChanged: (value) {
            HapticFeedback.selectionClick();
            unawaited(liveProvider.setSessionEqEnabled(liveSession.id, value));
          },
        ),
        DropdownButtonFormField<String>(
          initialValue: selectedPreset,
          decoration: InputDecoration(
            labelText: i18n.tr('eq_preset'),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
          items: presets
              .map(
                (preset) => DropdownMenuItem<String>(
                  value: preset.id,
                  child: Text(_presetLabel(i18n, preset)),
                ),
              )
              .toList(growable: false),
          onChanged: (value) {
            final preset = presets
                .where((item) => item.id == value)
                .firstOrNull;
            if (preset == null) return;
            HapticFeedback.selectionClick();
            unawaited(
              liveProvider.applySessionEqPreset(liveSession.id, preset),
            );
          },
        ),
        const SizedBox(height: 12),
        if (!capabilities.supported)
          Text(
            i18n.tr('equalizer_unavailable'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          )
        else
          ...capabilities.bands.map((band) {
            final value = effects.eqBandLevels[band.frequencyHz] ?? 0.0;
            return _EqBandSlider(
              label: _formatFrequency(band.frequencyHz),
              value: value.clamp(
                capabilities.minGainDb,
                capabilities.maxGainDb,
              ),
              min: capabilities.minGainDb,
              max: capabilities.maxGainDb,
              onChanged: effects.eqEnabled
                  ? (nextValue) {
                      unawaited(
                        liveProvider.setSessionEqBandLevel(
                          liveSession.id,
                          band.frequencyHz,
                          nextValue,
                        ),
                      );
                    }
                  : null,
            );
          }),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.tonal(
                onPressed: () {
                  final flat = AudioProvider.builtInEqPresets.first;
                  unawaited(
                    liveProvider.applySessionEqPreset(liveSession.id, flat),
                  );
                },
                child: Text(i18n.tr('eq_reset')),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.tonal(
                onPressed: effects.eqBandLevels.isEmpty
                    ? null
                    : () => _showSavePresetDialog(
                        context,
                        provider: liveProvider,
                        session: liveSession,
                      ),
                child: Text(i18n.tr('eq_save_preset')),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _showSavePresetDialog(
    BuildContext context, {
    required AudioProvider provider,
    required PlaybackSession session,
  }) async {
    final i18n = context.read<AppLanguageProvider>();
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(i18n.tr('eq_save_preset')),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(labelText: i18n.tr('eq_preset_name')),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: Text(MaterialLocalizations.of(context).okButtonLabel),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    unawaited(provider.saveCustomEqPreset(name, session));
  }
}

class _EqBandSlider extends StatelessWidget {
  const _EqBandSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    final divisions = ((max - min) * 2).round().clamp(1, 80).toInt();
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: '${value.toStringAsFixed(1)} dB',
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 54,
          child: Text(
            '${value.toStringAsFixed(1)} dB',
            textAlign: TextAlign.end,
            style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _SpeedWheelPage extends StatefulWidget {
  const _SpeedWheelPage({
    super.key,
    required this.session,
    required this.provider,
  });

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  State<_SpeedWheelPage> createState() => _SpeedWheelPageState();
}

@visibleForTesting
int playbackSpeedWheelIndexAfterDesktopScroll({
  required int currentIndex,
  required double scrollDeltaY,
  required int itemCount,
}) {
  if (itemCount <= 0 || scrollDeltaY.abs() < 0.01) return currentIndex;
  final direction = scrollDeltaY > 0 ? 1 : -1;
  return (currentIndex + direction).clamp(0, itemCount - 1).toInt();
}

class _SpeedWheelPageState extends State<_SpeedWheelPage> {
  late FixedExtentScrollController _controller;
  late int _selectedIndex;
  int? _pendingDesktopWheelIndex;
  DateTime? _desktopWheelLockUntil;
  bool _desktopWheelAppliedManually = false;

  List<double> get _speeds => AudioProvider.playbackSpeedOptions;

  @override
  void initState() {
    super.initState();
    _selectedIndex = _nearestSpeedIndex(widget.session.speed);
    _controller = FixedExtentScrollController(initialItem: _selectedIndex);
  }

  @override
  void didUpdateWidget(covariant _SpeedWheelPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextIndex = _nearestSpeedIndex(widget.session.speed);
    if (oldWidget.session.id != widget.session.id ||
        nextIndex != _selectedIndex) {
      _selectedIndex = nextIndex;
      _controller.dispose();
      _controller = FixedExtentScrollController(initialItem: _selectedIndex);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int _nearestSpeedIndex(double speed) {
    var bestIndex = 0;
    var bestDistance = double.infinity;
    for (var index = 0; index < _speeds.length; index++) {
      final distance = (_speeds[index] - speed).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = index;
      }
    }
    return bestIndex;
  }

  void _setSpeedIndex(int index, {required bool persist}) {
    final nextIndex = index.clamp(0, _speeds.length - 1);
    final nextSpeed = _speeds[nextIndex];
    if (_selectedIndex != nextIndex) {
      HapticFeedback.selectionClick();
      setState(() => _selectedIndex = nextIndex);
    }
    unawaited(
      widget.provider.setSessionSpeed(
        widget.session.id,
        nextSpeed,
        persist: persist,
      ),
    );
  }

  void _handleDesktopPointerSignal(PointerSignalEvent event) {
    if (!Platform.isWindows || event is! PointerScrollEvent) return;
    final baseIndex = _pendingDesktopWheelIndex ?? _selectedIndex;
    final nextIndex = playbackSpeedWheelIndexAfterDesktopScroll(
      currentIndex: baseIndex,
      scrollDeltaY: event.scrollDelta.dy,
      itemCount: _speeds.length,
    );
    if (nextIndex == baseIndex) return;
    _pendingDesktopWheelIndex = nextIndex;
    _desktopWheelAppliedManually = false;
    _desktopWheelLockUntil = DateTime.now().add(
      const Duration(milliseconds: 220),
    );
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _desktopWheelAppliedManually = true;
      _controller.animateToItem(
        nextIndex,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
      );
      _setSpeedIndex(nextIndex, persist: true);
    });
  }

  bool get _isDesktopWheelLocked {
    final lockUntil = _desktopWheelLockUntil;
    if (lockUntil == null) return false;
    final locked = DateTime.now().isBefore(lockUntil);
    if (!locked) _desktopWheelLockUntil = null;
    return locked;
  }

  void _resetSpeed() {
    final index = _nearestSpeedIndex(1.0);
    _controller.animateToItem(
      index,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
    _setSpeedIndex(index, persist: true);
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.read<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final selectedSpeed = _speeds[_selectedIndex];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Center(
          child: Text(
            _formatSpeedValue(selectedSpeed),
            key: ValueKey<double>(selectedSpeed),
            style: Theme.of(context).textTheme.displaySmall?.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w900,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Listener(
            onPointerSignal: _handleDesktopPointerSignal,
            child: NotificationListener<ScrollEndNotification>(
              onNotification: (_) {
                if (_isDesktopWheelLocked) return false;
                _pendingDesktopWheelIndex = null;
                _setSpeedIndex(_selectedIndex, persist: true);
                return false;
              },
              child: ListWheelScrollView.useDelegate(
                key: const ValueKey('playback_speed_wheel'),
                controller: _controller,
                itemExtent: 44,
                diameterRatio: 1.35,
                physics: const FixedExtentScrollPhysics(),
                onSelectedItemChanged: (index) {
                  final pendingIndex = _pendingDesktopWheelIndex;
                  final wheelLocked = _isDesktopWheelLocked;
                  if (pendingIndex != null) {
                    if (index != pendingIndex) return;
                    final appliedManually = _desktopWheelAppliedManually;
                    _pendingDesktopWheelIndex = null;
                    _desktopWheelAppliedManually = false;
                    if (appliedManually) return;
                    _setSpeedIndex(index, persist: true);
                    return;
                  }
                  if (wheelLocked) return;
                  _setSpeedIndex(index, persist: false);
                },
                childDelegate: ListWheelChildBuilderDelegate(
                  childCount: _speeds.length,
                  builder: (context, index) {
                    if (index < 0 || index >= _speeds.length) return null;
                    final speed = _speeds[index];
                    final selected = index == _selectedIndex;
                    return GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        _controller.animateToItem(
                          index,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOutCubic,
                        );
                      },
                      child: Center(
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 120),
                          curve: Curves.easeOutCubic,
                          style: Theme.of(context).textTheme.titleLarge!
                              .copyWith(
                                color: selected
                                    ? cs.primary
                                    : cs.onSurfaceVariant,
                                fontWeight: selected
                                    ? FontWeight.w900
                                    : FontWeight.w700,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                          child: Text(_formatSpeedValue(speed)),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: FilledButton.tonal(
            onPressed: (selectedSpeed - 1.0).abs() < 0.001 ? null : _resetSpeed,
            child: Text(i18n.tr('speed_reset')),
          ),
        ),
      ],
    );
  }
}

class _TimeSegmentChip extends StatelessWidget {
  const _TimeSegmentChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final TimeSegmentLabel label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Color(label.colorValue);
    final cs = Theme.of(context).colorScheme;
    return ActionChip(
      onPressed: onTap,
      side: BorderSide(
        color: selected ? cs.onSurface.withValues(alpha: 0.74) : color,
        width: selected ? 1.4 : 1,
      ),
      backgroundColor: color.withValues(alpha: selected ? 0.34 : 0.2),
      label: Text(
        label.name,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: cs.onSurface,
          fontWeight: FontWeight.w800,
        ),
      ),
      shape: const StadiumBorder(),
    );
  }
}

class _SegmentTimeRow extends StatelessWidget {
  const _SegmentTimeRow({
    required this.label,
    required this.value,
    required this.color,
    required this.onSet,
    required this.onEdit,
  });

  final String label;
  final Duration? value;
  final Color color;
  final VoidCallback onSet;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(
                  backgroundColor: color.withValues(alpha: 0.15),
                  foregroundColor: color,
                  minimumSize: const Size(48, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: onSet,
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
            Expanded(
              child: InkWell(
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(16),
                ),
                onTap: onEdit,
                child: Center(
                  child: Text(
                    value == null ? '--:--' : _formatSegmentTime(value!),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: value == null ? cs.onSurfaceVariant : cs.onSurface,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
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

Future<Duration?> _showSegmentTimeInputDialog(
  BuildContext context, {
  Duration? initial,
}) async {
  final i18n = context.read<AppLanguageProvider>();
  final controller = TextEditingController(
    text: initial == null ? '' : _formatSegmentTime(initial),
  );
  return showDialog<Duration>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(i18n.tr('segment_time_input_title')),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.datetime,
        decoration: InputDecoration(
          hintText: 'MM:SS / HH:MM:SS',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onSubmitted: (value) {
          final parsed = _parseSegmentTime(value);
          if (parsed != null) Navigator.of(ctx).pop(parsed);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(i18n.tr('cancel')),
        ),
        FilledButton(
          onPressed: () {
            final parsed = _parseSegmentTime(controller.text);
            if (parsed != null) Navigator.of(ctx).pop(parsed);
          },
          child: Text(i18n.tr('confirm')),
        ),
      ],
    ),
  );
}

Duration? _parseSegmentTime(String raw) {
  final parts = raw
      .trim()
      .split(':')
      .map((part) => int.tryParse(part.trim()))
      .toList(growable: false);
  if (parts.length != 2 && parts.length != 3) return null;
  if (parts.any((part) => part == null || part < 0)) return null;
  final hours = parts.length == 3 ? parts[0]! : 0;
  final minutes = parts.length == 3 ? parts[1]! : parts[0]!;
  final seconds = parts.length == 3 ? parts[2]! : parts[1]!;
  if (minutes >= 60 || seconds >= 60) return null;
  return Duration(hours: hours, minutes: minutes, seconds: seconds);
}

String _formatSegmentTime(Duration value) {
  final totalSeconds = value.inSeconds < 0 ? 0 : value.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds ~/ 60).remainder(60).toString().padLeft(2, '0');
  final seconds = totalSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
  return '$minutes:$seconds';
}

String _formatSpeedValue(double value) {
  if ((value - value.roundToDouble()).abs() < 0.001) {
    return '${value.toStringAsFixed(1)}x';
  }
  return '${value.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '')}x';
}

String _formatFrequency(int frequencyHz) {
  if (frequencyHz >= 1000) {
    final khz = frequencyHz / 1000;
    return '${khz.toStringAsFixed(khz >= 10 ? 0 : 1)}k';
  }
  return '${frequencyHz}Hz';
}

String _presetLabel(AppLanguageProvider i18n, EqPreset preset) {
  return preset.isCustom ? preset.labelKey : i18n.tr(preset.labelKey);
}
