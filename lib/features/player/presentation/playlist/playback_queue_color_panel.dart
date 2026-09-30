import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_design_tokens.dart';

const List<Color> _queuePresetColors = [
  Color(0xFF2E9C8B), // Default Mint Teal
  Color(0xFF00ACC1), // Cyan
  Color(0xFF1E88E5), // Blue
  Color(0xFF5E35B1), // Deep Purple
  Color(0xFF8E24AA), // Purple
  Color(0xFFD81B60), // Rose Pink
  Color(0xFFE53935), // Red
  Color(0xFFFB8C00), // Orange
  Color(0xFFFFB300), // Amber
  Color(0xFF43A047), // Green
];

class PlaybackQueueColorPanel extends StatelessWidget {
  const PlaybackQueueColorPanel({
    super.key,
    required this.colorValue,
    required this.onColorChanged,
    required this.height,
    required this.onBack,
  });

  final int? colorValue;
  final ValueChanged<int?> onColorChanged;
  final double height;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final value = colorValue;
    final color = value == null
        ? Theme.of(context).colorScheme.primary
        : Color(value);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final hexCode =
        '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

    return SizedBox(
      height: height,
      child: Material(
        key: const ValueKey('playback_queue_color_panel'),
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(tokens.radiusSmall),
                      ),
                      child: Icon(
                        Icons.palette_outlined,
                        color: color,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            i18n.tr('edit_queue_color'),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            hexCode,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('playback_queue_color_back'),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: onBack,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Preset color palette: two rows of five
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        for (int i = 0; i < 5; i++)
                          Expanded(
                            child: Center(
                              child: _buildPresetColorButton(
                                cs: cs,
                                presetColor: _queuePresetColors[i],
                                currentColor: color,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (int i = 5; i < 10; i++)
                          Expanded(
                            child: Center(
                              child: _buildPresetColorButton(
                                cs: cs,
                                presetColor: _queuePresetColors[i],
                                currentColor: color,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                for (final channel in <(String, int)>[
                  ('R', (color.r * 255).round()),
                  ('G', (color.g * 255).round()),
                  ('B', (color.b * 255).round()),
                ])
                  _QueueColorSlider(
                    label: channel.$1,
                    value: channel.$2,
                    color: color,
                    onChanged: (next) {
                      final r = channel.$1 == 'R'
                          ? next
                          : (color.r * 255).round();
                      final g = channel.$1 == 'G'
                          ? next
                          : (color.g * 255).round();
                      final b = channel.$1 == 'B'
                          ? next
                          : (color.b * 255).round();
                      onColorChanged(Color.fromARGB(255, r, g, b).toARGB32());
                    },
                  ),
                const SizedBox(height: 2),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => onColorChanged(null),
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    label: Text(i18n.tr('reset_to_default')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPresetColorButton({
    required ColorScheme cs,
    required Color presetColor,
    required Color currentColor,
  }) {
    final isSelected =
        (currentColor.toARGB32() & 0xFFFFFF) ==
        (presetColor.toARGB32() & 0xFFFFFF);
    return Semantics(
      button: true,
      selected: isSelected,
      child: InkWell(
        onTap: () => onColorChanged(presetColor.toARGB32()),
        customBorder: const CircleBorder(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: presetColor,
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected
                  ? cs.onSurface
                  : cs.outlineVariant.withValues(alpha: 0.4),
              width: isSelected ? 2.5 : 1,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: presetColor.withValues(alpha: 0.45),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: isSelected
              ? Icon(
                  Icons.check_rounded,
                  size: 18,
                  color:
                      ThemeData.estimateBrightnessForColor(presetColor) ==
                          Brightness.dark
                      ? Colors.white
                      : Colors.black87,
                )
              : null,
        ),
      ),
    );
  }
}

class _QueueColorSlider extends StatelessWidget {
  const _QueueColorSlider({
    required this.label,
    required this.value,
    required this.color,
    required this.onChanged,
  });

  final String label;
  final int value;
  final Color color;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final channelColor = switch (label) {
      'R' => Colors.redAccent,
      'G' => Colors.green,
      'B' => Colors.blueAccent,
      _ => color,
    };
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: channelColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w900,
                color: channelColor,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: color,
                thumbColor: color,
              ),
              child: Slider(
                max: 255,
                value: value.toDouble(),
                onChanged: (next) => onChanged(next.round()),
              ),
            ),
          ),
          SizedBox(
            width: 32,
            child: Text(
              value.toString(),
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
