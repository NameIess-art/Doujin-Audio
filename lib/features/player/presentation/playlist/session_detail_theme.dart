import 'package:flutter/material.dart';
import '../../../../app/theme/app_design_tokens.dart';

SliderThemeData sessionDetailProgressSliderTheme(
  BuildContext context,
  Color primaryColor,
) => SliderTheme.of(context).copyWith(
  trackHeight: 3,
  thumbShape: const RoundSliderThumbShape(
    enabledThumbRadius: 6,
    elevation: 2,
    pressedElevation: 5,
  ),
  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
  activeTrackColor: primaryColor,
  inactiveTrackColor: primaryColor.withValues(alpha: 0.22),
  thumbColor: primaryColor,
  overlayColor: primaryColor.withValues(alpha: 0.15),
);

SliderThemeData sessionDetailVolumeSliderTheme(
  BuildContext context, {
  required bool isBoosted,
}) => SliderTheme.of(context).copyWith(
  trackHeight: 6,
  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
  activeTrackColor: isBoosted ? Theme.of(context).colorScheme.primary : null,
);

BoxDecoration sessionDetailPlayButtonDecoration(
  BuildContext context,
  Color primaryColor, {
  required bool enabled,
}) {
  final theme = Theme.of(context);
  return BoxDecoration(
    shape: BoxShape.circle,
    color: enabled ? primaryColor : theme.colorScheme.surfaceContainerHighest,
    boxShadow: enabled
        ? [
            BoxShadow(
              color: primaryColor.withValues(
                alpha: theme.brightness == Brightness.dark ? 0.38 : 0.24,
              ),
              blurRadius: 18,
              offset: const Offset(0, 4),
            ),
          ]
        : null,
  );
}

ThemeData createAsmrSessionDetailTheme(ThemeData base, AppDesignTokens tokens) {
  final scheme = base.colorScheme.copyWith(
    primary: tokens.asmrAccent,
    onPrimary: tokens.onAsmrAccent,
    primaryContainer: tokens.asmrContainer,
    onPrimaryContainer: tokens.onAsmrContainer,
    secondary: tokens.asmrAccent,
    onSecondary: tokens.onAsmrAccent,
    secondaryContainer: tokens.asmrContainer,
    onSecondaryContainer: tokens.onAsmrContainer,
  );
  return base.copyWith(
    colorScheme: scheme,
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: tokens.asmrAccent,
      thumbColor: tokens.asmrAccent,
      overlayColor: tokens.asmrAccent.withValues(alpha: 0.15),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: tokens.asmrAccent),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: tokens.asmrAccent,
        foregroundColor: tokens.onAsmrAccent,
      ),
    ),
  );
}

ThemeData createPlaybackQueueSessionDetailTheme(
  ThemeData base,
  Color queueColor,
) {
  final generated = ColorScheme.fromSeed(
    seedColor: queueColor,
    brightness: base.brightness,
  );
  final onQueueColor =
      ThemeData.estimateBrightnessForColor(queueColor) == Brightness.dark
      ? Colors.white
      : const Color(0xFF1B1B1F);
  final scheme = base.colorScheme.copyWith(
    primary: queueColor,
    onPrimary: onQueueColor,
    primaryContainer: generated.primaryContainer,
    onPrimaryContainer: generated.onPrimaryContainer,
    secondary: queueColor,
    onSecondary: onQueueColor,
    secondaryContainer: generated.primaryContainer,
    onSecondaryContainer: generated.onPrimaryContainer,
    surfaceTint: queueColor,
  );
  return base.copyWith(
    colorScheme: scheme,
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: queueColor,
      thumbColor: queueColor,
      overlayColor: queueColor.withValues(alpha: 0.15),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: queueColor),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: queueColor,
        foregroundColor: onQueueColor,
      ),
    ),
  );
}
