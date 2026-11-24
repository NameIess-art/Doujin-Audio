import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_design_tokens.dart';
import '../../../../core/media/time_text_formatters.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_edit_panel.dart';
import '../../../../core/widgets/app_entry_ink_well.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/app_glass_surface.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/scroll_activity_gate.dart';
import '../../../../core/widgets/top_page_header.dart';
import '../../../../core/widgets/unified_popup_menu.dart';
import '../../../../core/widgets/windows_horizontal_wheel_scroll.dart';
import '../../../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../application/playback_facade.dart';
import '../../application/playback_session_snapshot.dart';
import '../../domain/time_segment_label.dart';
import 'playlist_audio_features.dart';
import 'playlist_shared_helpers.dart';
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
  final String? loopSegmentId;
  final ValueChanged<TimeSegmentLabel> onSelect;
  final VoidCallback onAdd;
  final VoidCallback onSetStart;
  final VoidCallback onSetEnd;
  final VoidCallback onEditStart;
  final VoidCallback onEditEnd;
  final ValueChanged<TimeSegmentLabel> onDelete;
  final ValueChanged<TimeSegmentLabel> onToggleLoop;
  final VoidCallback onClose;

  @override
  State<TimeSegmentPanel> createState() => _TimeSegmentPanelState();
}

class _TimeSegmentPanelState extends State<TimeSegmentPanel> {
  final _pageIndex = ValueNotifier<int>(2);
  int _trackRevision = 0;

  @override
  void didUpdateWidget(covariant TimeSegmentPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldSession = oldWidget.session;
    final session = widget.session;
    if (oldSession.id != session.id ||
        oldSession.currentTrackPath != session.currentTrackPath ||
        oldSession.currentQueueIndex != session.currentQueueIndex) {
      _trackRevision++;
    }
  }

  @override
  void dispose() {
    _pageIndex.dispose();
    super.dispose();
  }

  void _animateToPanelPage(int index) {
    if (index < 0 || index >= 5 || _pageIndex.value == index) return;
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    _pageIndex.value = index;
  }

  List<UnifiedMenuEntry<VoidCallback>> _segmentMenuEntries(
    BuildContext context,
    TimeSegmentLabel label,
  ) {
    final revision = _trackRevision;
    final session = widget.session;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final loopActive = label.id == widget.loopSegmentId;

    void run(ValueChanged<TimeSegmentLabel> action) {
      if (!mounted || revision != _trackRevision) return;
      final runtime = widget.playback.sessionById(session.id);
      if (runtime == null ||
          runtime.currentTrackPath != session.currentTrackPath ||
          runtime.currentQueueIndex != session.currentQueueIndex) {
        return;
      }
      final target = widget.labels
          .where(
            (candidate) =>
                candidate.id == label.id &&
                candidate.trackKey == label.trackKey,
          )
          .firstOrNull;
      if (target != null) action(target);
    }

    return [
      UnifiedMenuEntry.action(
        value: () => run(widget.onSelect),
        icon: Icons.edit_outlined,
        label: i18n.tr('segment_edit'),
      ),
      UnifiedMenuEntry.action(
        value: () => run(widget.onToggleLoop),
        icon: loopActive ? Icons.repeat_one_rounded : Icons.repeat_rounded,
        label: i18n.tr(loopActive ? 'segment_stop_loop' : 'segment_menu_loop'),
      ),
      UnifiedMenuEntry.action(
        value: () => run(widget.onDelete),
        icon: Icons.delete_outline_rounded,
        label: i18n.tr('remove'),
        destructive: true,
      ),
    ];
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
    final loopActive = selected != null && selected.id == widget.loopSegmentId;
    final mediaHeight = MediaQuery.sizeOf(context).height;
    final isPortrait =
        defaultTargetPlatform != TargetPlatform.windows &&
        MediaQuery.orientationOf(context) == Orientation.portrait;
    final targetHeight = isPortrait
        ? max(420.0, min(560.0, mediaHeight * 0.54))
        : max(360.0, mediaHeight * 0.5 - 130.0);
    const pageTopInset = 12.0;
    const panelRadius = BorderRadius.only(
      topLeft: Radius.circular(19),
      topRight: Radius.circular(19),
      bottomLeft: Radius.circular(16),
      bottomRight: Radius.circular(16),
    );

    final content = Column(
      children: [
        ValueListenableBuilder<int>(
          valueListenable: _pageIndex,
          builder: (context, pageIndex, _) => SegmentPanelPageHeader(
            pageIndex: pageIndex,
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
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: ScrollActivityGate(
              maxNotificationDepth: 1,
              child: AppFadeThroughIndexedStack.lazy(
                key: const ValueKey('playback_console_page_stack'),
                indexListenable: _pageIndex,
                itemCount: 5,
                contentRevision: (
                  widget.session.id,
                  widget.session.currentTrackPath,
                  Object.hashAll(widget.labels),
                  widget.selectedId,
                  widget.showEditor,
                  widget.loading,
                  widget.draftStart,
                  widget.draftEnd,
                  widget.loopSegmentId,
                  pageTopInset,
                ),
                itemBuilder: (context, index) => switch (index) {
                  0 => EqualizerPage(
                    session: widget.session,
                    playback: widget.playback,
                    topInset: pageTopInset,
                  ),
                  1 => AudioFeaturesPage(
                    session: widget.session,
                    playback: widget.playback,
                    topInset: pageTopInset,
                  ),
                  2 => Padding(
                    padding: const EdgeInsets.only(top: pageTopInset),
                    child: SpeedWheelPage(
                      key: ValueKey<String>('speed_${widget.session.id}'),
                      session: widget.session,
                      playback: widget.playback,
                    ),
                  ),
                  3 => _buildSegmentPage(
                    context,
                    selected: selected,
                    loopActive: loopActive,
                    topInset: pageTopInset,
                  ),
                  _ => Padding(
                    padding: const EdgeInsets.only(top: pageTopInset),
                    child: VolumeBalancePage(
                      key: ValueKey<String>('balance_${widget.session.id}'),
                      session: widget.session,
                      playback: widget.playback,
                    ),
                  ),
                },
              ),
            ),
          ),
        ),
      ],
    );
    final panel = SizedBox(
      key: const ValueKey<String>('playback_expanded_control_panel'),
      height: targetHeight,
      child: AppGlassSurface(
        enabled: AppDesignTokens.of(context).barGlassEnabled,
        backgroundColor: cs.surfaceContainerHigh.withValues(alpha: 0.9),
        borderRadius: panelRadius,
        child: DecoratedBox(
          key: const ValueKey<String>(
            'playback_expanded_control_panel_surface',
          ),
          decoration: BoxDecoration(
            borderRadius: panelRadius,
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.55),
            ),
          ),
          child: content,
        ),
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
    required bool loopActive,
    required double topInset,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final labelSize = theme.chipTheme.labelStyle?.fontSize ?? 14.0;
    final chipRowHeight = max(
      42.0,
      MediaQuery.textScalerOf(context).scale(labelSize) + 24,
    );

    return ListView(
      padding: EdgeInsets.only(top: topInset + 2),
      children: [
        SizedBox(
          height: chipRowHeight,
          child: Row(
            children: [
              Expanded(
                child: widget.loading
                    ? Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: cs.primary,
                          ),
                        ),
                      )
                    : WindowsHorizontalWheelScroll(
                        builder: (controller) => ListView.separated(
                          controller: controller,
                          scrollDirection: Axis.horizontal,
                          physics: const ClampingScrollPhysics(),
                          itemCount: widget.labels.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (context, index) {
                            final label = widget.labels[index];
                            return Center(
                              key: ValueKey(label.id),
                              child: UnifiedContextMenuRegion(
                                shape: const StadiumBorder(),
                                skipTraversal: true,
                                openOnAndroidLongPress: true,
                                buildEntries: () =>
                                    _segmentMenuEntries(context, label),
                                child: TimeSegmentChip(
                                  label: label,
                                  selected: label.id == widget.selectedId,
                                  onTap: () => widget.onSelect(label),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              IconButton.filledTonal(
                style: appIconButtonStyle(
                  IconButton.styleFrom(
                    fixedSize: const Size.square(40),
                    padding: EdgeInsets.zero,
                    backgroundColor: cs.primary.withValues(alpha: 0.12),
                    foregroundColor: cs.primary,
                  ),
                ),
                onPressed: widget.onAdd,
                icon: const Icon(Icons.add_rounded),
                tooltip: i18n.tr('segment_add'),
              ),
            ],
          ),
        ),
        AnimatedSectionReveal(
          visible: widget.showEditor,
          builder: (context) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              TextField(
                contextMenuBuilder: buildAppEditableTextMenu,
                controller: widget.nameController,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: i18n.tr('segment_name'),
                  hintText: i18n.tr('segment_name_hint'),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  const gap = 10.0;
                  final width = constraints.maxWidth;
                  final textScale =
                      MediaQuery.textScalerOf(context).scale(14) / 14;
                  final endpointWidth = width >= 320 * textScale
                      ? (width - gap) / 2
                      : width;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      SizedBox(
                        width: endpointWidth,
                        child: SegmentTimeRow(
                          label: i18n.tr('segment_start'),
                          value: widget.draftStart,
                          onSet: widget.onSetStart,
                          onEdit: widget.onEditStart,
                        ),
                      ),
                      SizedBox(
                        width: endpointWidth,
                        child: SegmentTimeRow(
                          label: i18n.tr('segment_end'),
                          value: widget.draftEnd,
                          onSet: widget.onSetEnd,
                          onEdit: widget.onEditEnd,
                        ),
                      ),
                    ],
                  );
                },
              ),
              AnimatedSectionReveal(
                visible: selected != null,
                builder: (context) {
                  final activeSegment = selected!;
                  return Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: FilledButton.tonal(
                            style: sessionDetailResetButtonStyle(
                              context,
                              accent: loopActive
                                  ? cs.primary
                                  : cs.onSurfaceVariant,
                            ),
                            onPressed: () => widget.onToggleLoop(activeSegment),
                            child: Text(
                              i18n.tr(
                                loopActive
                                    ? 'segment_stop_loop'
                                    : 'segment_loop',
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.tonal(
                            style: sessionDetailResetButtonStyle(
                              context,
                              accent: cs.error,
                            ),
                            onPressed: () => widget.onDelete(activeSegment),
                            child: Text(
                              i18n.tr('remove'),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    ).withWindowsSmoothScroll();
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
    return SizedBox(
      height: 38,
      child: Material(
        type: MaterialType.transparency,
        child: Row(
          children: [
            Expanded(
              // Scrolled tabs end in a semicircle instead of a flat cut.
              child: ClipRRect(
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(19),
                ),
                child: SegmentedCategoryPillStrip<int>(
                  items: List<int>.generate(labels.length, (index) => index),
                  selected: pageIndex,
                  onSelected: onSelected,
                  labelBuilder: (index) => labels[index],
                  indicatorKey: const ValueKey('console_tab_indicator'),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey<String>('close_console_panel'),
              tooltip: closeTooltip,
              onPressed: onClose,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: EdgeInsets.zero,
              style: appIconButtonStyle(
                IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
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
    return appNoPointerInkTheme(
      context: context,
      androidPressHighlight: true,
      child: ActionChip(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        mouseCursor: WidgetStateMouseCursor.clickable,
        onPressed: onTap,
        side: BorderSide(
          color: selected ? cs.onSurface.withValues(alpha: 0.74) : color,
          width: selected ? 1.4 : 1,
        ),
        color: appChipColor(
          colorScheme: cs,
          platform: Theme.of(context).platform,
          background: color.withValues(alpha: selected ? 0.34 : 0.2),
        ),
        label: Text(label.name),
        shape: const StadiumBorder(),
      ),
    );
  }
}

class SegmentTimeRow extends StatelessWidget {
  const SegmentTimeRow({
    super.key,
    required this.label,
    required this.value,
    required this.onSet,
    required this.onEdit,
  });

  final String label;
  final Duration? value;
  final VoidCallback onSet;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8),
            child: FilledButton.tonal(
              style: sessionDetailResetButtonStyle(context).copyWith(
                minimumSize: const WidgetStatePropertyAll(Size(48, 36)),
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
              ),
              onPressed: onSet,
              child: Text(label),
            ),
          ),
          Expanded(
            child: AppEntryInkWell(
              onTap: onEdit,
              child: Container(
                constraints: const BoxConstraints(minHeight: 52),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                alignment: Alignment.center,
                child: Text(
                  value == null ? '--:--' : formatDurationCompact(value!),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: value == null ? cs.onSurfaceVariant : cs.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<Duration?> showSegmentTimeInputDialog(
  BuildContext context, {
  Duration? initial,
}) {
  final i18n = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appLanguageProviderInstanceProvider);
  return showAppTextInputPanel<Duration>(
    context: context,
    header: AppEditPanelHeader(
      title: i18n.tr('segment_time_input_title'),
      icon: Icons.schedule_rounded,
    ),
    initialValue: initial == null ? '' : formatDurationCompact(initial),
    keyboardType: TextInputType.datetime,
    decoration: const InputDecoration(hintText: 'MM:SS / HH:MM:SS'),
    cancelLabel: i18n.tr('cancel'),
    submitLabel: i18n.tr('confirm'),
    parse: parseDurationCompact,
  );
}
