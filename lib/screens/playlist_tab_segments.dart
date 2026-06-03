part of 'playlist_tab.dart';

class _PlaybackControlPanel extends StatelessWidget {
  const _PlaybackControlPanel({
    super.key,
    required this.session,
    required this.provider,
    required this.playPauseController,
    required this.isPlaying,
    required this.hasSiblings,
    required this.onShowTrackSwitcher,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final AnimationController playPauseController;
  final bool isPlaying;
  final bool hasSiblings;
  final VoidCallback onShowTrackSwitcher;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = context.read<AppLanguageProvider>();
    return Column(
      children: [
        SizedBox(
          height: 92,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 400;
              final skipIconSize = compact ? 48.0 : 54.0;
              final playIconSize = compact ? 76.0 : 86.0;
              final loadingSize = compact ? 38.0 : 44.0;

              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    tooltip: i18n.tr('previous_track'),
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
                    tooltip: isPlaying ? i18n.tr('pause') : i18n.tr('play'),
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
                          : AnimatedIcon(
                              icon: AnimatedIcons.play_pause,
                              progress: playPauseController,
                              key: const ValueKey('play_pause_anim'),
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
                    tooltip: i18n.tr('next_track'),
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
        Container(
          margin: const EdgeInsets.only(top: 8),
          decoration: _controlPanelDecoration(cs),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: SizedBox(
            height: 52,
            child: Row(
              children: [
                _ExpandableLoopOptions(session: session, provider: provider),
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
                          onShowTrackSwitcher();
                        }
                      : null,
                  tooltip: i18n.tr('switch_audio'),
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
  int _pageIndex = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
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
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
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
            segmentLabel: '时间段标记',
            speedLabel: i18n.tr('playback_speed'),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: _handlePageChanged,
              children: [
                _buildSegmentPage(
                  context,
                  selected: selected,
                  activeColor: activeColor,
                  loopActive: loopActive,
                ),
                _SpeedWheelPage(
                  key: ValueKey<String>('speed_${widget.session.id}'),
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
    required this.segmentLabel,
    required this.speedLabel,
  });

  final int pageIndex;
  final String segmentLabel;
  final String speedLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labels = <String>[segmentLabel, speedLabel];
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(labels.length, (index) {
        final selected = index == pageIndex;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
        );
      }),
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

class _SpeedWheelPageState extends State<_SpeedWheelPage> {
  late FixedExtentScrollController _controller;
  late int _selectedIndex;

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
          child: NotificationListener<ScrollEndNotification>(
            onNotification: (_) {
              _setSpeedIndex(_selectedIndex, persist: true);
              return false;
            },
            child: ListWheelScrollView.useDelegate(
              key: const ValueKey('playback_speed_wheel'),
              controller: _controller,
              itemExtent: 44,
              diameterRatio: 1.35,
              physics: const FixedExtentScrollPhysics(),
              onSelectedItemChanged: (index) =>
                  _setSpeedIndex(index, persist: false),
              childDelegate: ListWheelChildBuilderDelegate(
                childCount: _speeds.length,
                builder: (context, index) {
                  if (index < 0 || index >= _speeds.length) return null;
                  final speed = _speeds[index];
                  final selected = index == _selectedIndex;
                  return Center(
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOutCubic,
                      style: Theme.of(context).textTheme.titleLarge!.copyWith(
                        color: selected ? cs.primary : cs.onSurfaceVariant,
                        fontWeight: selected
                            ? FontWeight.w900
                            : FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      child: Text(_formatSpeedValue(speed)),
                    ),
                  );
                },
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

BoxDecoration _controlPanelDecoration(ColorScheme cs) {
  return BoxDecoration(
    color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
    borderRadius: BorderRadius.circular(24),
    border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.15)),
    boxShadow: [
      BoxShadow(
        color: Colors.white.withValues(alpha: 0.12),
        offset: const Offset(0, 1),
      ),
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
      colors: [Colors.black.withValues(alpha: 0.06), Colors.transparent],
      stops: const [0.0, 0.15],
    ),
  );
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
