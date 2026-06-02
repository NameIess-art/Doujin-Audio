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

class _TimeSegmentPanel extends StatelessWidget {
  const _TimeSegmentPanel({
    super.key,
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
  Widget build(BuildContext context) {
    final i18n = context.read<AppLanguageProvider>();
    final selected = labels
        .where((label) => label.id == selectedId)
        .firstOrNull;
    final activeColor = Color(
      selected?.colorValue ?? draftColorValue ?? kTimeSegmentLabelPalette.first,
    );
    final loopActive = selected != null && selected.id == loopSegmentId;

    return Container(
      constraints: const BoxConstraints(minHeight: 156),
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 42,
            child: Row(
              children: [
                Expanded(
                  child: loading
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
                          itemCount: labels.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (context, index) {
                            final label = labels[index];
                            return _TimeSegmentChip(
                              label: label,
                              selected: label.id == selectedId,
                              onTap: () => onSelect(label),
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
                  onPressed: onAdd,
                  icon: const Icon(Icons.add_rounded),
                  tooltip: i18n.tr('segment_add'),
                ),
              ],
            ),
          ),
          if (showEditor) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                _SegmentTimeRow(
                  label: i18n.tr('segment_start'),
                  value: draftStart,
                  color: activeColor,
                  onSet: onSetStart,
                  onEdit: onEditStart,
                ),
                const SizedBox(width: 8),
                _SegmentTimeRow(
                  label: i18n.tr('segment_end'),
                  value: draftEnd,
                  color: activeColor,
                  onSet: onSetEnd,
                  onEdit: onEditEnd,
                ),
                if (selected != null) ...[
                  const Spacer(),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: loopActive
                          ? activeColor
                          : Theme.of(context).colorScheme.onSurface,
                      backgroundColor: loopActive
                          ? activeColor.withValues(alpha: 0.18)
                          : Theme.of(context).colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.28),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(74, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      textStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: onToggleLoop,
                    child: Text(i18n.tr('segment_loop')),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: nameController,
                    textInputAction: TextInputAction.done,
                    style: Theme.of(context).textTheme.labelMedium,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: i18n.tr('segment_name'),
                      hintText: i18n.tr('segment_name_hint'),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                if (selected != null) ...[
                  const SizedBox(width: 12),
                  FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                      backgroundColor: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.5),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(60, 38),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: onDelete,
                    child: Text(i18n.tr('remove')),
                  ),
                ],
              ],
            ),
          ],
        ],
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 34,
          child: FilledButton.tonal(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 7),
              minimumSize: const Size(44, 34),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              textStyle: Theme.of(context).textTheme.labelSmall,
            ),
            onPressed: onSet,
            child: Text(label),
          ),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 42,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onEdit,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                value == null ? '--:--' : _formatSegmentTime(value!),
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: value == null ? cs.onSurfaceVariant : cs.onSurface,
                  fontWeight: FontWeight.w800,
                  decoration: TextDecoration.underline,
                  decorationColor: cs.onSurface.withValues(alpha: 0.24),
                ),
              ),
            ),
          ),
        ),
      ],
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
