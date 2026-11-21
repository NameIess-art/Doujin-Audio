import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/widgets/app_edit_panel.dart';
import '../../../../core/widgets/app_entry_ink_well.dart';

const List<Color> _queuePresetColors = [
  Color(0xFF2E9C8B), // Default Mint Teal
  Color(0xFF1E88E5), // Blue
  Color(0xFF8E24AA), // Purple
  Color(0xFFE53935), // Red
  Color(0xFFFB8C00), // Orange
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
    final hexCode =
        '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

    return SizedBox(
      key: const ValueKey('playback_queue_color_panel'),
      width: double.infinity,
      height: height,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: AppEditPanelHeader(
                    icon: Icons.palette_outlined,
                    iconKey: const ValueKey('playback_queue_color_header_icon'),
                    title: i18n.tr('edit_queue_color'),
                    accentColor: color,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  hexCode,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: const ValueKey('playback_queue_color_back'),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: onBack,
                ),
              ],
            ),
            const SizedBox(height: 28),
            // Preset color palette: one row of five
            Row(
              children: [
                for (int i = 0; i < _queuePresetColors.length; i++)
                  Expanded(
                    child: Center(
                      child: _buildPresetColorButton(
                        context: context,
                        cs: cs,
                        presetColor: _queuePresetColors[i],
                        currentColor: color,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            for (final channel in <(String, int)>[
              ('R', (color.r * 255).round()),
              ('G', (color.g * 255).round()),
              ('B', (color.b * 255).round()),
            ]) ...[
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
              if (channel.$1 != 'B') const SizedBox(height: 16),
            ],
            const Spacer(),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                style: appEditPanelActionStyle(),
                onPressed: () => onColorChanged(null),
                child: Text(i18n.tr('reset_to_default')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPresetColorButton({
    required BuildContext context,
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
      child: AppEntryInkWell(
        onTap: () => onColorChanged(presetColor.toARGB32()),
        customBorder: const CircleBorder(),
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
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
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w900,
                color: cs.primary,
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
              ),
            ),
          ),
        ],
      ),
    );
  }
}
