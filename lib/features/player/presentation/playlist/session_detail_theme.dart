import 'package:flutter/material.dart';
import '../../../../app/theme/app_design_tokens.dart';

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
