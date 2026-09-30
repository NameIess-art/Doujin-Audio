import 'package:flutter/material.dart';

import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/subtitle_window_visual.dart';
import '../../../app/state/subtitle_settings_provider.dart';

class SubtitleWindowPreviewCard extends StatelessWidget {
  const SubtitleWindowPreviewCard({
    super.key,
    required this.settings,
    required this.height,
    required this.title,
    required this.sampleText,
  });

  final SubtitleSettingsState settings;
  final double height;
  final String title;
  final String sampleText;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardRadius = BorderRadius.circular(
      AppDesignTokens.of(context).radiusOverlay,
    );

    return SizedBox(
      key: const ValueKey<String>('subtitle_window_preview_card'),
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: cardRadius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              isDark ? const Color(0xFF131A29) : const Color(0xFFF6F8FC),
              isDark ? const Color(0xFF0B0F18) : const Color(0xFFE9EEF7),
            ],
          ),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: isDark ? 0.28 : 0.5),
          ),
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withValues(alpha: isDark ? 0.26 : 0.12),
              blurRadius: 26,
              spreadRadius: -10,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: cardRadius,
          child: Stack(
            children: [
              Positioned(
                left: -18,
                top: -24,
                child: _PreviewOrb(
                  size: 132,
                  color: cs.primary.withValues(alpha: isDark ? 0.24 : 0.14),
                ),
              ),
              Positioned(
                right: -22,
                bottom: -34,
                child: _PreviewOrb(
                  size: 148,
                  color: cs.secondary.withValues(alpha: isDark ? 0.18 : 0.12),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Center(
                        child: SubtitleWindowVisual(
                          settings: settings,
                          text: sampleText,
                          maxTextWidth: 260,
                          fallbackBackgroundColor: Colors.black,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewOrb extends StatelessWidget {
  const _PreviewOrb({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color,
              color.withValues(alpha: color.a * 0.25),
              color.withValues(alpha: 0),
            ],
            stops: const [0, 0.42, 1],
          ),
        ),
      ),
    );
  }
}
