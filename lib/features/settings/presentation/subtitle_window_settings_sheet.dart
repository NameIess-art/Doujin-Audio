import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_settings_group_card.dart';
import '../../../core/widgets/unified_dropdown.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../../app/state/subtitle_settings_provider.dart';

import 'subtitle_window_preview_card.dart';
import 'subtitle_rgb_controls.dart';

class SubtitleWindowSettingsSheet extends ConsumerStatefulWidget {
  const SubtitleWindowSettingsSheet({super.key});

  @override
  ConsumerState<SubtitleWindowSettingsSheet> createState() =>
      _SubtitleWindowSettingsSheetState();
}

class _SubtitleWindowSettingsSheetState
    extends ConsumerState<SubtitleWindowSettingsSheet>
    with WidgetsBindingObserver {
  late final SubtitleSettingsNotifier _notifier;

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(subtitleSettingsProvider.notifier);
    WidgetsBinding.instance.addObserver(this);
  }

  void _endAppearanceEdit() => unawaited(_notifier.endAppearanceEdit());

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _endAppearanceEdit();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _endAppearanceEdit();
    super.dispose();
  }

  static const _fontFamilies = <String>[
    '',
    'monospace',
    'serif',
    'sans-serif',
    'SimSun',
    'KaiTi',
    'SimHei',
  ];
  static const double _previewHeight = 136;
  static const double _previewTopInset = 8;
  static const double _previewSideInset = 24;
  static const double _previewBottomGap = 20;

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final cs = Theme.of(context).colorScheme;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final labelStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600);

    final notifier = _notifier;
    final previewCard = Consumer(
      builder: (context, ref, _) => SubtitleWindowPreviewCard(
        height: _previewHeight,
        settings: ref.watch(subtitleSettingsProvider),
        title: i18n.tr('subtitle_window_preview'),
        sampleText: i18n.tr('subtitle_preview_sample'),
      ),
    );
    final controls = <Widget>[
      Consumer(
        builder: (context, ref, _) {
          final saveFailed = ref.watch(
            subtitleSettingsProvider.select((s) => s.appearanceSaveFailed),
          );
          if (!saveFailed) return const SizedBox.shrink();
          return ListTile(
            leading: Icon(Icons.error_outline_rounded, color: cs.error),
            title: Text(i18n.tr('operation_failed_retry')),
            trailing: TextButton(
              onPressed: () =>
                  unawaited(notifier.flushAppearancePersistence()),
              child: Text(i18n.tr('retry')),
            ),
          );
        },
      ),
      AppSettingsGroupCard(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Consumer(
              builder: (context, ref, _) {
                final fontFamily = ref.watch(
                  subtitleSettingsProvider.select((s) => s.fontFamily),
                );
                return UnifiedDropdownButtonFormField<String>(
                  initialValue: fontFamily,
                  expandWidth: true,
                  decoration: InputDecoration(
                    labelText: i18n.tr('font_setting'),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  items: [
                    for (final family in _fontFamilies)
                      DropdownMenuItem(
                        value: family,
                        child: Text(
                          family.isEmpty
                              ? i18n.tr('system_default')
                              : family,
                          style: TextStyle(
                            fontFamily: family.isEmpty ? null : family,
                          ),
                        ),
                      ),
                  ],
                  onChanged: (family) {
                    if (family != null) {
                      notifier.setFontFamily(family);
                    }
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Consumer(
              builder: (context, ref, _) {
                final fontSize = ref.watch(
                  subtitleSettingsProvider.select((s) => s.fontSize),
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            i18n.tr('font_size'),
                            style: labelStyle,
                          ),
                        ),
                        Text(
                          fontSize.toStringAsFixed(0),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: cs.onSurfaceVariant,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ),
                    Slider(
                      value: fontSize,
                      min: 12,
                      max: 32,
                      divisions: 20,
                      onChangeStart: (_) => notifier.beginAppearanceEdit(),
                      onChanged: (v) => notifier.setFontSize(v),
                      onChangeEnd: (_) => _endAppearanceEdit(),
                    ),
                  ],
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Consumer(
              builder: (context, ref, _) {
                final currentFontColor = ref.watch(
                  subtitleSettingsProvider.select((s) => s.fontColor),
                );
                return SubtitleRgbControls(
                  label: i18n.tr('font_color'),
                  resetTooltip: i18n.tr('reset_to_default'),
                  currentColor: currentFontColor,
                  defaultColor: const Color(0xFFFFFFFF),
                  cs: cs,
                  labelStyle: labelStyle,
                  onChanged: (c) => notifier.setFontColor(c),
                  onChangeStart: notifier.beginAppearanceEdit,
                  onChangeEnd: _endAppearanceEdit,
                  onReset: () => notifier.setFontColor(null),
                );
              },
            ),
          ),
        ],
      ),
      const SizedBox(height: 24),
      AppSettingsGroupCard(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Consumer(
              builder: (context, ref, _) {
                final backgroundOpacity = ref.watch(
                  subtitleSettingsProvider.select((s) => s.backgroundOpacity),
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            i18n.tr('background_transparency'),
                            style: labelStyle,
                          ),
                        ),
                        Text(
                          '${((1.0 - backgroundOpacity) * 100).toStringAsFixed(0)}%',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: cs.onSurfaceVariant,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ),
                    Slider(
                      value: 1.0 - backgroundOpacity,
                      divisions: 100,
                      onChangeStart: (_) => notifier.beginAppearanceEdit(),
                      onChanged: (v) =>
                          notifier.setBackgroundOpacity(1.0 - v),
                      onChangeEnd: (_) => _endAppearanceEdit(),
                    ),
                  ],
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Consumer(
              builder: (context, ref, _) {
                final currentBgColor = ref.watch(
                  subtitleSettingsProvider.select((s) => s.backgroundColor),
                );
                return SubtitleRgbControls(
                  label: i18n.tr('background_color'),
                  resetTooltip: i18n.tr('reset_to_default'),
                  currentColor: currentBgColor,
                  defaultColor: const Color(0xFF000000),
                  cs: cs,
                  labelStyle: labelStyle,
                  onChanged: (c) => notifier.setBackgroundColor(c),
                  onChangeStart: notifier.beginAppearanceEdit,
                  onChangeEnd: _endAppearanceEdit,
                  onReset: () => notifier.setBackgroundColor(null),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Consumer(
              builder: (context, ref, _) {
                final borderDepth = ref.watch(
                  subtitleSettingsProvider.select((s) => s.borderDepth),
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            i18n.tr('border_depth'),
                            style: labelStyle,
                          ),
                        ),
                        Text(
                          (borderDepth * 100).toStringAsFixed(0),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: cs.onSurfaceVariant,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ),
                    Slider(
                      value: borderDepth,
                      divisions: 100,
                      onChangeStart: (_) => notifier.beginAppearanceEdit(),
                      onChanged: (v) => notifier.setBorderDepth(v),
                      onChangeEnd: (_) => _endAppearanceEdit(),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ];
    final panel = LayoutBuilder(
      builder: (context, constraints) {
        final pinPreview =
            !constraints.hasBoundedHeight || constraints.maxHeight >= 420;
        if (!pinPreview) {
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                previewCard,
                const SizedBox(height: _previewBottomGap),
                ...controls,
              ],
            ),
          ).withWindowsSmoothScroll();
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                _previewSideInset,
                _previewTopInset,
                _previewSideInset,
                16,
              ),
              child: previewCard,
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: controls,
                ),
              ).withWindowsSmoothScroll(),
            ),
          ],
        );
      },
    );
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: AppBottomSheet.contentPadding,
            child: AppBottomSheetHeader(
              icon: Icons.subtitles_rounded,
              title: i18n.tr('subtitle_window_settings'),
            ),
          ),
          Flexible(child: panel),
        ],
      ),
    );
  }
}
