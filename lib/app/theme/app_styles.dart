import 'package:flutter/material.dart';

import 'app_design_tokens.dart';

Color landscapeNavigationBackground(ColorScheme colors) {
  if (colors.brightness == Brightness.dark) {
    // Pure black keeps a true-black chrome rather than inverting lighter than
    // the canvas; non-black dark themes step one level deeper than content.
    return colors.surfaceContainerLowest;
  }
  return colors.surfaceContainerLow;
}

/// Elevated surface color shared by floating chrome and overlays (header pills,
/// dock, menus, snackbars, dialogs). Dark mode lifts above the canvas via
/// [ColorScheme.surfaceBright]; light mode uses [ColorScheme.surfaceContainerLowest]
/// so floating chrome stays crisp and luminous above the tinted page background.
Color appFloatingSurfaceColor(ColorScheme colors) {
  if (colors.brightness == Brightness.dark) {
    return colors.surfaceBright;
  }
  return colors.surfaceContainerLowest;
}

/// Unified border color for cards, shells, and floating overlays.
Color appOverlayBorderColor(
  ColorScheme colors,
  AppDesignTokens tokens, {
  bool elevated = false,
}) {
  if (colors.brightness == Brightness.dark) {
    final base = elevated
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.08),
            colors.outlineVariant,
          )
        : colors.outlineVariant;
    final alpha = tokens.highContrast
        ? tokens.standardBorderAlpha
        : elevated
        ? (tokens.pureBlack ? 0.36 : 0.30)
        : tokens.standardBorderAlpha;
    return base.withValues(alpha: alpha);
  }
  final alpha = tokens.highContrast
      ? tokens.standardBorderAlpha
      : elevated
      ? 0.34
      : tokens.standardBorderAlpha;
  return colors.outlineVariant.withValues(alpha: alpha);
}

class AppSpacing {
  AppSpacing._();

  static const double xxs = 4.0;
  static const double xs = 8.0;
  static const double sm = 12.0;
  static const double md = 16.0;
  static const double lg = 20.0;
  static const double xl = 24.0;

  static const EdgeInsets edgeInsetsAllMd = EdgeInsets.all(md);
}

class AppRadius {
  AppRadius._();

  static const double small = 6.0;
  static const double medium = 10.0;
  static const double card = 12.0;
  static const double section = 16.0;
  static const double dialog = 20.0;
  static const double pill = 999.0;

  static const BorderRadius borderMedium = BorderRadius.all(
    Radius.circular(medium),
  );
  static const BorderRadius borderDialog = BorderRadius.all(
    Radius.circular(dialog),
  );
}

abstract final class AppPageHeaderMetrics {
  static const double buttonSize = 38;
  static const double titleIconSize = 22;
  static const double contentHeight = buttonSize;
  static const double rowSpacing = 6;
  static const double secondRowOffset = contentHeight + rowSpacing;
  static const double expandedContentHeight = secondRowOffset + contentHeight;
  static const EdgeInsets padding = EdgeInsets.fromLTRB(
    AppSpacing.md,
    6,
    AppSpacing.md,
    0,
  );
  static const EdgeInsets mainTabPadding = EdgeInsets.fromLTRB(
    AppSpacing.md,
    6,
    AppSpacing.md,
    0,
  );
  static const double firstContentSpacing = AppSpacing.xs;
  static const double toolbarHeight = 62;
  static const double expandedToolbarHeight = 88;

  static double headerHeight(
    BuildContext context, {
    double? contentHeight,
    double additionalHeight = 0,
  }) =>
      MediaQuery.paddingOf(context).top +
      padding.vertical +
      (contentHeight ?? AppPageHeaderMetrics.contentHeight) +
      additionalHeight;

  static double contentTopInset(
    BuildContext context, {
    double? contentHeight,
    double additionalHeight = 0,
  }) =>
      headerHeight(
        context,
        contentHeight: contentHeight,
        additionalHeight: additionalHeight,
      ) +
      firstContentSpacing;
}
