import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_design_tokens.dart';
import '../../../../core/media/time_text_formatters.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_dialog.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/scroll_activity_gate.dart';
import '../../../../core/widgets/top_page_header.dart';
import '../../../../core/widgets/windows_horizontal_wheel_scroll.dart';
import '../../application/playback_facade.dart';
import '../../application/playback_session_snapshot.dart';
import '../../domain/time_segment_label.dart';
import 'playlist_audio_features.dart';
import 'playlist_speed_controls.dart';

class TimeSegmentPanel extends StatefulWidget {
  const TimeSegmentPanel({
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
    required this.onClose,
  });

  final PlaybackSessionSnapshot session;
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
  final VoidCallback onClose;

  @override
  State<TimeSegmentPanel> createState() => _TimeSegmentPanelState();
}

class _TimeSegmentPanelState extends State<TimeSegmentPanel> {
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
    final cs = Theme.of(context).colorScheme;
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
    final isPortrait =
        defaultTargetPlatform != TargetPlatform.windows &&
        MediaQuery.orientationOf(context) == Orientation.portrait;
    final targetHeight = isPortrait
        ? max(420.0, min(560.0, mediaHeight * 0.54))
        : max(360.0, mediaHeight * 0.5 - 130.0);
    const headerHeight = 38.0;
    const headerGap = 12.0;
    const pageTopInset = headerHeight + headerGap;
    const panelRadius = BorderRadius.only(
      topLeft: Radius.circular(19),
      topRight: Radius.circular(19),
      bottomLeft: Radius.circular(16),
      bottomRight: Radius.circular(16),
    );

    final content = Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: ScrollActivityGate(
              maxNotificationDepth: 1,
              child: Listener(
                onPointerSignal: (signal) {
                  if (defaultTargetPlatform != TargetPlatform.windows ||
                      signal is! PointerScrollEvent ||
                      signal.scrollDelta.dy == 0) {
                    return;
                  }
                  final target =
                      _pageIndex + (signal.scrollDelta.dy > 0 ? 1 : -1);
                  if (target < 0 || target >= 5) return;
                  GestureBinding.instance.pointerSignalResolver.register(
                    signal,
                    (_) => _animateToPanelPage(target),
                  );
                },
                child: PageView(
                  controller: _pageController,
                  onPageChanged: _handlePageChanged,
                  children: [
                    EqualizerPage(
                      session: widget.session,
                      playback: widget.playback,
                      topInset: pageTopInset,
                    ),
                    AudioFeaturesPage(
                      session: widget.session,
                      playback: widget.playback,
                      topInset: pageTopInset,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: pageTopInset),
                      child: SpeedWheelPage(
                        key: ValueKey<String>('speed_${widget.session.id}'),
                        session: widget.session,
                        playback: widget.playback,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: pageTopInset),
                      child: _buildSegmentPage(
                        context,
                        selected: selected,
                        activeColor: activeColor,
                        loopActive: loopActive,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: pageTopInset),
                      child: VolumeBalancePage(
                        session: widget.session,
                        playback: widget.playback,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: headerHeight,
          child: SegmentPanelPageHeader(
            pageIndex: _pageIndex,
            onSelected: _animateToPanelPage,
            onClose: widget.onClose,
            closeTooltip: i18n.tr('close'),
            labels: [
              i18n.tr('equalizer'),
              i18n.tr('audio_features'),
              i18n.tr('playback_speed'),
              i18n.tr('audio_detail_tags'),
              i18n.tr('volume_balance'),
            ],
          ),
        ),
      ],
    );
    final panel = isPortrait
        ? SizedBox(
            key: const ValueKey<String>('playback_expanded_control_panel'),
            height: targetHeight,
            child: ClipRRect(
              borderRadius: panelRadius,
              child: DecoratedBox(
                key: const ValueKey<String>(
                  'playback_expanded_control_panel_surface',
                ),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh.withValues(alpha: 0.9),
                  borderRadius: panelRadius,
                  border: Border.all(
                    color: cs.outlineVariant.withValues(alpha: 0.55),
                  ),
                ),
                child: content,
              ),
            ),
          )
        : SizedBox(
            height: targetHeight,
            child: ColoredBox(
              key: const ValueKey<String>(
                'playback_expanded_control_panel_landscape_surface',
              ),
              color: cs.surface,
              child: content,
            ),
          );
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: panel,
    );
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
                    : WindowsHorizontalWheelScroll(
                        builder: (scrollController) => ListView.separated(
                          controller: scrollController,
                          scrollDirection: Axis.horizontal,
                          itemCount: widget.labels.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (context, index) {
                            final label = widget.labels[index];
                            return TimeSegmentChip(
                              label: label,
                              selected: label.id == widget.selectedId,
                              onTap: () => widget.onSelect(label),
                            );
                          },
                        ),
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
              SegmentTimeRow(
                label: i18n.tr('segment_start'),
                value: widget.draftStart,
                color: activeColor,
                onSet: widget.onSetStart,
                onEdit: widget.onEditStart,
              ),
              const SizedBox(width: 12),
              SegmentTimeRow(
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
                      shape: const StadiumBorder(),
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
                      shape: const StadiumBorder(),
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

class SegmentPanelPageHeader extends StatelessWidget {
  const SegmentPanelPageHeader({
    super.key,
    required this.pageIndex,
    required this.onSelected,
    required this.onClose,
    required this.closeTooltip,
    required this.labels,
  });

  final int pageIndex;
  final ValueChanged<int> onSelected;
  final VoidCallback onClose;
  final String closeTooltip;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final tokens = AppDesignTokens.of(context);
    return HeaderFloatingSurface(
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(19),
        child: Row(
          children: [
            IconButton(
              key: const ValueKey<String>('close_console_panel'),
              tooltip: closeTooltip,
              onPressed: onClose,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
            ),
            Expanded(
              child: ClipRRect(
                key: const ValueKey<String>('console_tab_scroll_clip'),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(19),
                  bottomLeft: Radius.circular(19),
                ),
                child: WindowsHorizontalWheelScroll(
                  builder: (scrollController) => ListView.separated(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 3,
                    ),
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    itemCount: labels.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 2),
                    itemBuilder: (context, index) {
                      final selected = index == pageIndex;
                      return Semantics(
                        button: true,
                        selected: selected,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(15),
                          onTap: () => onSelected(index),
                          child: AnimatedContainer(
                            duration: tokens.motionFast,
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: selected
                                  ? cs.primary.withValues(alpha: 0.19)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(15),
                            ),
                            child: Text(
                              labels[index],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: selected
                                    ? cs.primary
                                    : cs.onSurfaceVariant,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
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

class TimeSegmentChip extends StatelessWidget {
  const TimeSegmentChip({
    super.key,
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

class SegmentTimeRow extends StatelessWidget {
  const SegmentTimeRow({
    super.key,
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
                  shape: const StadiumBorder(),
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
                    value == null ? '--:--' : formatDurationCompact(value!),
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

Future<Duration?> showSegmentTimeInputDialog(
  BuildContext context, {
  Duration? initial,
}) async {
  final i18n = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appLanguageProviderInstanceProvider);
  final controller = TextEditingController(
    text: initial == null ? '' : formatDurationCompact(initial),
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
          final parsed = parseDurationCompact(value);
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
              final parsed = parseDurationCompact(controller.text);
              if (parsed != null) Navigator.of(dialogContext).pop(parsed);
            },
            label: i18n.tr('confirm'),
          ),
        ],
      ),
    ),
  ).whenComplete(controller.dispose);
}
