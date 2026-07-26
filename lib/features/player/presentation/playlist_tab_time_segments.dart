part of 'playlist_tab.dart';

class _TimeSegmentPanel extends StatefulWidget {
  const _TimeSegmentPanel({
    super.key,
    required this.session,
    required this.playback,
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
    this.onClose,
  });

  final PlaybackSession session;
  final PlaybackFacade playback;
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
  final VoidCallback? onClose;

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
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() => _pageIndex = index);
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
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

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 4),
          const SizedBox(height: 8),
          Stack(
            alignment: Alignment.center,
            children: [
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
              if (widget.onClose != null)
                Positioned(
                  right: 0,
                  child: IconButton(
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    iconSize: 20,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: widget.onClose,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ScrollActivityGate(
              maxNotificationDepth: 1,
              child: PageView(
                controller: _pageController,
                onPageChanged: _handlePageChanged,
                children: [
                  _EqualizerPage(
                    session: widget.session,
                    playback: widget.playback,
                  ),
                  _AudioFeaturesPage(
                    session: widget.session,
                    playback: widget.playback,
                  ),
                  _SpeedWheelPage(
                    key: ValueKey<String>('speed_${widget.session.id}'),
                    session: widget.session,
                    playback: widget.playback,
                  ),
                  _buildSegmentPage(
                    context,
                    selected: selected,
                    activeColor: activeColor,
                    loopActive: loopActive,
                  ),
                  _VolumeBalancePage(
                    session: widget.session,
                    playback: widget.playback,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return SizedBox(height: targetHeight, child: content);
  }

  Widget _buildSegmentPage(
    BuildContext context, {
    required TimeSegmentLabel? selected,
    required Color activeColor,
    required bool loopActive,
  }) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
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
                        borderRadius: BorderRadius.circular(16),
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
                        borderRadius: BorderRadius.circular(16),
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
                    borderRadius: BorderRadius.circular(16),
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
  final i18n = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appLanguageProviderInstanceProvider);
  final controller = TextEditingController(
    text: initial == null ? '' : _formatSegmentTime(initial),
  );
  return showAppDialog<Duration>(
    context: context,
    builder: (dialogContext) => AppDialog(
      title: i18n.tr('segment_time_input_title'),
      icon: Icons.schedule_rounded,
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.datetime,
        decoration: InputDecoration(
          hintText: 'MM:SS / HH:MM:SS',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        ),
        onSubmitted: (value) {
          final parsed = _parseSegmentTime(value);
          if (parsed != null) Navigator.of(dialogContext).pop(parsed);
        },
      ),
      actions: AppDialogActions(
        children: [
          AppSecondaryButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            label: i18n.tr('cancel'),
          ),
          AppPrimaryButton(
            onPressed: () {
              final parsed = _parseSegmentTime(controller.text);
              if (parsed != null) Navigator.of(dialogContext).pop(parsed);
            },
            label: i18n.tr('confirm'),
          ),
        ],
      ),
    ),
  ).whenComplete(controller.dispose);
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
