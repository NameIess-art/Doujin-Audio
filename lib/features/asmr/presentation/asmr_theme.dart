import 'package:flutter/material.dart';

import '../../../app/theme/app_design_tokens.dart';

ThemeData asmrThemeData(BuildContext context) {
  final base = Theme.of(context);
  final tokens = AppDesignTokens.of(context);
  final accent = tokens.asmrAccent;
  final scheme = base.colorScheme.copyWith(
    primary: accent,
    onPrimary: tokens.onAsmrAccent,
    primaryContainer: tokens.asmrContainer,
    onPrimaryContainer: tokens.onAsmrContainer,
    secondary: accent,
    onSecondary: tokens.onAsmrAccent,
    secondaryContainer: tokens.asmrContainer,
    onSecondaryContainer: tokens.onAsmrContainer,
  );
  return base.copyWith(
    colorScheme: scheme,
  );
}
