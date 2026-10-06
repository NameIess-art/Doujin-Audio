import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_settings_group_card.dart';
import '../../../core/widgets/unified_dropdown.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../app/state/subtitle_settings_provider.dart';

import 'subtitle_window_preview_card.dart';
import 'subtitle_rgb_controls.dart';

class SubtitleWindowSettingsSheet extends StatelessWidget {
  const SubtitleWindowSettingsSheet({super.key});

  static const _fontFamilies = <String>[
    '',
    'monospace',
    'serif',
    'sans-serif',
    'SimSun',
    'KaiTi',
    'SimHei',
  ];
  static const double _previewHeight = 176;
  static const double _previewTopInset = 8;
  static const double _previewSideInset = 24;
  static const double _previewBottomGap = 20;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final labelStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600);

    return Consumer(
      builder: (context, ref, child) {
        final settings = ref.watch(subtitleSettingsProvider);
        final notifier = ref.read(subtitleSettingsProvider.notifier);

        final currentFontColor = settings.fontColor;
        final currentBgColor = settings.backgroundColor;
        const contentTopPadding =
            _previewTopInset + _previewHeight + _previewBottomGap;

        final panel = SizedBox(
          width: double.infinity,
          child: Stack(
            children: [
              Positioned.fill(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    24,
                    contentTopPadding,
                    24,
                    32,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppSettingsGroupCard(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  i18n.tr('font_setting'),
                                  style: labelStyle,
                                ),
                                const SizedBox(height: 8),
                                InputDecorator(
                                  decoration: InputDecoration(
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                  ),
                                  child: UnifiedDropdownButton<String>(
                                    value: settings.fontFamily,
                                    isDense: true,
                                    isExpanded: true,
                                    multilineItems: true,
                                    alignment: AlignmentDirectional.centerStart,
                                    items: List.generate(_fontFamilies.length, (
                                      i,
                                    ) {
                                      final label = i == 0
                                          ? i18n.tr('system_default')
                                          : _fontFamilies[i];
                                      return DropdownMenuItem(
                                        value: _fontFamilies[i],
                                        child: Text(
                                          softWrap: true,
                                          overflow: TextOverflow.visible,
                                          label,
                                          textAlign: TextAlign.start,
                                          style: TextStyle(
                                            fontFamily: _fontFamilies[i].isEmpty
                                                ? null
                                                : _fontFamilies[i],
                                          ),
                                        ),
                                      );
                                    }),
                                    onChanged: (v) {
                                      if (v != null) notifier.setFontFamily(v);
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                            child: Column(
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
                                      settings.fontSize.toStringAsFixed(0),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: cs.onSurfaceVariant,
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                  ],
                                ),
                                Slider(
                                  value: settings.fontSize,
                                  min: 12,
                                  max: 32,
                                  divisions: 20,
                                  onChanged: (v) => notifier.setFontSize(v),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                            child: SubtitleRgbControls(
                              label: i18n.tr('font_color'),
                              resetTooltip: i18n.tr('reset_to_default'),
                              currentColor: currentFontColor,
                              defaultColor: const Color(0xFFFFFFFF),
                              cs: cs,
                              labelStyle: labelStyle,
                              onChanged: (c) => notifier.setFontColor(c),
                              onReset: () => notifier.setFontColor(null),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      AppSettingsGroupCard(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                            child: Column(
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
                                      '${((1.0 - settings.backgroundOpacity) * 100).toStringAsFixed(0)}%',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: cs.onSurfaceVariant,
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                  ],
                                ),
                                Slider(
                                  value: 1.0 - settings.backgroundOpacity,
                                  divisions: 100,
                                  onChanged: (v) =>
                                      notifier.setBackgroundOpacity(1.0 - v),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                            child: SubtitleRgbControls(
                              label: i18n.tr('background_color'),
                              resetTooltip: i18n.tr('reset_to_default'),
                              currentColor: currentBgColor,
                              defaultColor: const Color(0xFF000000),
                              cs: cs,
                              labelStyle: labelStyle,
                              onChanged: (c) => notifier.setBackgroundColor(c),
                              onReset: () => notifier.setBackgroundColor(null),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                            child: Column(
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
                                      (settings.borderDepth * 100)
                                          .toStringAsFixed(0),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: cs.onSurfaceVariant,
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                  ],
                                ),
                                Slider(
                                  value: settings.borderDepth,
                                  divisions: 100,
                                  onChanged: (v) => notifier.setBorderDepth(v),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: _previewTopInset,
                left: _previewSideInset,
                right: _previewSideInset,
                child: IgnorePointer(
                  child: SubtitleWindowPreviewCard(
                    height: _previewHeight,
                    settings: settings,
                    title: i18n.tr('subtitle_window_preview'),
                    sampleText: i18n.tr('subtitle_preview_sample'),
                  ),
                ),
              ),
            ],
          ),
        );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: AppBottomSheet.contentPadding,
                child: AppBottomSheetHeader(
                  icon: Icons.subtitles_outlined,
                  title: i18n.tr('subtitle_window_settings'),
                ),
              ),
              Flexible(child: panel),
            ],
          ),
        );
      },
    );
  }
}
